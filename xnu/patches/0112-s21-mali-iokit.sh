#!/bin/bash
# S21 Mali IOKit service + user client (registered by 0120-s21-mali-iokit.patch).
# dxb runs patches/*.sh from the XNU source root before applying *.patch.
set -euo pipefail

[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0
[[ -f iokit/conf/files.arm64 ]] || exit 1

cat > iokit/Kernel/arm/SweetMali.cpp <<'EOF_SWEET_SRC'
/*
 * S21 Mali-G78 IOKit layer: service "SweetMali" (matched through IOResources) and its
 * user client "SweetMaliUserClient". Thin: all hardware work is in bsd/dev/sweet_mali.c.
 *
 * User-client selectors (IOConnectCallMethod):
 *   0 GET_INFO     out struct: u32 gpu_id, shader_present, tiler_present, l2_present, as_present, js_present
 *   1 CREATE_BO    in scalar: size (bytes)                 out scalars: handle, phys of first page
 *   2 MAP_BO       in scalars: handle, gpu_va              maps the whole BO into this client's GPU address space
 *   3 SUBMIT       in scalars: slot, jc_va, timeout_ms     out scalar: status (0 = done)
 *   4 DESTROY_BO   in scalar: handle
 * IOConnectMapMemory64(type = handle) maps a BO into the caller (write-combined, GPU not coherent).
 * Enabled by boot-arg mali=1 (see sweet_mali.c).
 */
#include <pexpert/arm64/board_config.h>

#if defined(ARM64_BOARD_CONFIG_SWEET)

#include <IOKit/IOService.h>
#include <IOKit/IOUserClient.h>
#include <IOKit/IOKitKeys.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOLocks.h>
#include <IOKit/IOMemoryDescriptor.h>
#include <IOKit/IOBufferMemoryDescriptor.h>
#include <libkern/c++/OSString.h>
#include <pexpert/pexpert.h>
#include <kern/clock.h>
#include <libkern/libkern.h>
#include <kern/thread_call.h>
#include <kern/clock.h>

extern "C" {
void sweet_mali_boot(void);
int sweet_mali_up(void);
void sweet_mali_get_info(uint32_t out[6]);
int sweet_mali_ctx_create(void);
void sweet_mali_ctx_destroy(int id);
int sweet_mali_ctx_map(int id, uint64_t va, uint64_t pa);
void sweet_mali_ctx_unmap(int id, uint64_t va);
uint32_t sweet_mali_submit(int id, uint32_t slot, uint64_t jc_va, uint32_t timeout_ms);
void sweet_mali_set_asflush(int on);
void sweet_mali_log_str(const char *s);
}

#define SM_MAX_BO        256
#define SM_MAX_BO_BYTES  (15ULL << 20)     /* BOs >= 16 MiB stalled the system (2026-11 notes) */
#define SM_MAX_TOTAL     (512ULL << 20)    /* wired kernel memory (the kernel sees 2 GiB) */

enum {
	kSMGetInfo = 0,
	kSMCreateBO = 1,
	kSMMapBO = 2,
	kSMSubmit = 3,
	kSMDestroyBO = 4,
	kSMLog = 5,
	kSMMapFB = 6,
	kSMRebootRecovery = 7,
	kSMImportUser = 8,
	kSMKeep = 9,            /* keep a key diagnostic line in kernel memory, replayed into pmsg right before a recovery reboot */
	kSMTouch = 10,          /* synthetic touch (finger, down, x, y panel px) for automated unlock tests */
	kSMSubmitList = 11,     /* submit, cache-flushing only the BOs holding the listed GPU addresses (and all small BOs) */
	kSMSubmitRange = 12,    /* submit, cache-flushing listed (va, len, pre/post) ranges only; returns flush/job times */
	kSMFlushRange = 13,     /* clean+invalidate listed (va, len) ranges now (before a CPU read of GPU-written memory) */
	kSMFence = 14,          /* GPU fence tickets of this task for the present gate: op 0 issue -> ticket, 1 done(ticket), 2 query,
	                         * 3 tag [ticket, IOSurface ids...] (surface gate) */
	kSMFBStats = 15,        /* framebuffer pacing counters (SweetFramebuffer.cpp sweet_fb_stats), 16 scalars */
};

/*
 * GPU fences for the framebuffer present gate (patch 0137). A process that commits GPU work asynchronously takes a
 * ticket at commit (op 0) and completes it when the work is done (op 1, in order). AppleCLCD::swap() snapshots the
 * swapping task's last issued ticket and shows the frame once done >= that ticket. Never under sm_lock: lock-free for
 * the submitter, one IOSimpleLock for the table. A task's slot is invalidated (gen bump) when its last client closes,
 * so a dead renderer never holds the panel.
 */
#define SM_FENCE_SLOTS 32
static struct { task_t task; uint32_t gen, refs; uint64_t issued, done; } sm_fence[SM_FENCE_SLOTS];
static IOSimpleLock *sm_fence_lk;
static uint32_t sm_fence_gen;
extern "C" void sweet_fb_gpu_kick(void);
extern "C" void sweet_fb_stats(uint64_t out[16]);
extern "C" int sweet_gpu_fence_snapshot(task_t t, uint32_t *slot, uint32_t *gen, uint64_t *ticket);
extern "C" int sweet_gpu_fence_ready(uint32_t slot, uint32_t gen, uint64_t ticket);
extern "C" int sweet_gpu_fence_surfaces(const uint32_t *ids, int n, uint32_t *slot, uint32_t *gen, uint64_t *ticket);
/* Surface tags (op 3): SweetMetal names, at commit, the IOSurfaces a command buffer renders into; the framebuffer's
 * surface gate (0137, sweetfb_surf=1) then waits for exactly that work instead of the swapping task's latest ticket. */
#define SM_SURF_TAGS 64
static struct { uint32_t id, slot, gen; uint64_t ticket; } sm_surf[SM_SURF_TAGS];
static uint32_t sm_surf_next;

/* 2 = a tag of these surfaces whose work is still running (that one returned), 1 = tagged and all done, 0 = untagged */
extern "C" int
sweet_gpu_fence_surfaces(const uint32_t *ids, int n, uint32_t *slot, uint32_t *gen, uint64_t *ticket)
{
	int found = 0;
	if (sm_fence_lk == NULL || ids == NULL) {
		return 0;
	}
	IOSimpleLockLock(sm_fence_lk);
	for (int k = 0; k < n && found < 2; k++) {
		if (ids[k] == 0) {
			continue;
		}
		for (uint32_t i = 0; i < SM_SURF_TAGS; i++) {
			if (sm_surf[i].id != ids[k]) {
				continue;
			}
			uint32_t s = sm_surf[i].slot;
			bool running = s < SM_FENCE_SLOTS && sm_fence[s].task != NULL && sm_fence[s].gen == sm_surf[i].gen &&
			    sm_fence[s].done < sm_surf[i].ticket;
			if (found == 0 || running) {
				*slot = s;
				*gen = sm_surf[i].gen;
				*ticket = sm_surf[i].ticket;
				found = running ? 2 : 1;
			}
			break;
		}
	}
	IOSimpleLockUnlock(sm_fence_lk);
	return found;
}

extern "C" int
sweet_gpu_fence_snapshot(task_t t, uint32_t *slot, uint32_t *gen, uint64_t *ticket)
{
	int r = -1;
	if (sm_fence_lk == NULL || t == NULL) {
		return -1;
	}
	IOSimpleLockLock(sm_fence_lk);
	for (uint32_t i = 0; i < SM_FENCE_SLOTS; i++) {
		if (sm_fence[i].task == t) {
			*slot = i;
			*gen = sm_fence[i].gen;
			*ticket = sm_fence[i].issued;
			r = 0;
			break;
		}
	}
	IOSimpleLockUnlock(sm_fence_lk);
	return r;
}

extern "C" int
sweet_gpu_fence_ready(uint32_t slot, uint32_t gen, uint64_t ticket)
{
	int r = 1;
	if (sm_fence_lk == NULL || slot >= SM_FENCE_SLOTS) {
		return 1;
	}
	IOSimpleLockLock(sm_fence_lk);
	if (sm_fence[slot].task != NULL && sm_fence[slot].gen == gen && sm_fence[slot].done < ticket) {
		r = 0;
	}
	IOSimpleLockUnlock(sm_fence_lk);
	return r;
}
extern "C" void sweet_hid_touch(int finger, int down, int x, int y);
extern "C" void sweet_gov_touch(void);   /* 0111 load governor touch booster */
static int sm_flush_ro = 1;     /* boot-arg sweetflushro=0 turns the read-only import flush off */

extern "C" void sweet_mali_keep_dump(void);
static char sm_keep_buf[40960];
static uint32_t sm_keep_len;

static IOLock *sm_lock;                 /* serializes all hardware / context calls */
static uint64_t smb_last_submit;        /* mach time of the last client job (present-copy flush policy) */
static uint64_t sm_total;               /* bytes of BOs alive */

static void
sm_log(const char *fmt, uint64_t a, uint64_t b, uint64_t c)
{
	char line[160];
	snprintf(line, sizeof(line), fmt, a, b, c);
	sweet_mali_log_str(line);
}

extern "C" void flush_dcache64(addr64_t addr, unsigned count, int phys);
extern "C" vm_offset_t gPhysBase, gPhysSize;     /* osfmk/arm64/arm_vm_init.c: the physmap */
extern "C" vm_offset_t gVirtBase, static_memory_end;   /* ... and the end of the kernel static region (KVA) */

/* flush_dcache64(phys) goes through phystokv(), which panics for pages outside the physmap (IOSurface/carve-out
 * pages at 0x93fd00000 killed backboardd's kernel in run46): those are skipped */
static void
sm_flush_pa(uint64_t pa, unsigned len)
{
	if (pa >= gPhysBase && pa + len <= gPhysBase + gPhysSize) {
		/* pages of the kernel static region (ramdisk/overlay file pages mapped into a client) fault on cache
		 * maintenance (run68/run78 panics): the CPU never writes them, skip */
		if (pa - gPhysBase + gVirtBase < static_memory_end) {
			return;
		}
		flush_dcache64(pa, len, TRUE);
	}
}

/* The GPU is not cache coherent: clean+invalidate a buffer's pages by physical address.
 * One getPhysicalSegment per contiguous segment (not per page); the pages inside are flushed one by one as before. */
static void
sm_flush_md(IOMemoryDescriptor *md, uint32_t pages)
{
	for (uint32_t k = 0; k < pages;) {
		IOByteCount len = 0;
		addr64_t pa = md->getPhysicalSegment((IOByteCount)k << 12, &len, kIOMemoryMapperNone);
		uint32_t n = (uint32_t)((len + 4095) >> 12);
		if (pa == 0 || n == 0) {
			k++;
			continue;
		}
		if (n > pages - k) {
			n = pages - k;
		}
		for (uint32_t j = 0; j < n; j++) {
			sm_flush_pa(pa + ((uint64_t)j << 12), (unsigned)page_size);
		}
		k += n;
	}
	__asm__ volatile ("dsb sy" ::: "memory");
}

extern "C" vm_map_address_t phystokv(uint64_t pa);
/* DC CIVAC over one page through the physmap, no barrier (flush_dcache64 per page ended each call with a DSB:
 * thousands of DSBs per frame, run110); same physmap/static-region guards as sm_flush_pa */
static inline void
sm_civac_page(uint64_t pa)
{
	if (pa < gPhysBase || pa + 4096 > gPhysBase + gPhysSize || pa - gPhysBase + gVirtBase < static_memory_end) {
		return;
	}
	uintptr_t va = (uintptr_t)phystokv(pa);
	for (uintptr_t o = 0; o < 4096; o += 256) {
		__asm__ volatile ("dc civac, %0" :: "r"(va + o) : "memory");
		__asm__ volatile ("dc civac, %0" :: "r"(va + o + 64) : "memory");
		__asm__ volatile ("dc civac, %0" :: "r"(va + o + 128) : "memory");
		__asm__ volatile ("dc civac, %0" :: "r"(va + o + 192) : "memory");
	}
}
static int sm_fastflush = 1;    /* boot-arg sweetfastflush=0: per-page flush_dcache64 as before */

extern "C" int sweet_mali_coherent(void);   /* 0111: 2 = GPU snoops the CPU caches, no maintenance needed */
/* clean+invalidate pages [p0, p1) of a buffer */
static void
sm_flush_md_range(IOMemoryDescriptor *md, uint32_t p0, uint32_t p1)
{
	if (sweet_mali_coherent() >= 2) {
		return;
	}
	for (uint32_t k = p0; k < p1;) {
		IOByteCount len = 0;
		addr64_t pa = md->getPhysicalSegment((IOByteCount)k << 12, &len, kIOMemoryMapperNone);
		uint32_t n = (uint32_t)((len + 4095) >> 12);
		if (pa == 0 || n == 0) {
			k++;
			continue;
		}
		if (n > p1 - k) {
			n = p1 - k;
		}
		for (uint32_t j = 0; j < n; j++) {
			if (sm_fastflush) {
				sm_civac_page(pa + ((uint64_t)j << 12));
			} else {
				sm_flush_pa(pa + ((uint64_t)j << 12), (unsigned)page_size);
			}
		}
		k += n;
	}
	__asm__ volatile ("dsb sy" ::: "memory");
}

/*
 * Reboot into the recovery (TWRP) the way the SM-G991N kernel does (sec_reboot.ko + exynos-reboot.ko):
 * PMU_ALIVE 0x15860000: magic-inform 0x808 byte2 = 0x4e (normal reboot), panic-inform 0x80c =
 * 0x12345604 (reset reason "recovery"), reboot-cmd 0x810 = 0xff, then SWRESET 0x3c00 = 2.
 * Lets a test run end itself in the recovery without anyone holding keys.
 */
extern "C" vm_offset_t ml_io_map(vm_offset_t phys_addr, vm_size_t size);

static volatile uint32_t *sm_pmu;       /* mapped when autorec is armed: mapping at fire time can block under memory pressure */

static void
sm_reboot_recovery(const char *why)
{
	char line[96];
	snprintf(line, sizeof(line), "reboot to recovery (%s)", why);
	sweet_mali_log_str(line);
	/* replay the kept lines (all processes) last, so the pmsg ring ends with them */
	sweet_mali_keep_dump();
	if (sm_keep_len) {
		char ln[176];
		uint32_t i = 0;
		sweet_mali_log_str("KEPT LINES:");
		while (i < sm_keep_len) {
			uint32_t n = 0;
			while (i < sm_keep_len && sm_keep_buf[i] != '\n' && n < sizeof(ln) - 1) {
				ln[n++] = sm_keep_buf[i++];
			}
			ln[n] = 0;
			i++;
			if (n) {
				sweet_mali_log_str(ln);
			}
		}
	}
	volatile uint32_t *r = sm_pmu != NULL ? sm_pmu : (volatile uint32_t *)ml_io_map(0x15860000U, 0x4000);
	r[0x808 / 4] = (r[0x808 / 4] & ~0x00FF0000U) | 0x004E0000U;
	r[0x80c / 4] = 0x12345604U;
	r[0x810 / 4] = 0xFFU;
	__asm__ volatile ("dsb sy" ::: "memory");
	r[0x3c00 / 4] = 0x2U;
	__asm__ volatile ("dsb sy" ::: "memory");
	for (;;) {
		IOSleep(1000);
	}
}

extern "C" void sweet_reboot_recovery_ext(const char *why);
extern "C" void
sweet_reboot_recovery_ext(const char *why)
{
	sm_reboot_recovery(why);
}
extern "C" void sweet_hard_reset_at(uint32_t secs);   /* 0111: interrupt-context reset, no locks */

static void
sm_autorec_fire(__unused thread_call_param_t p0, __unused thread_call_param_t p1)
{
	sm_reboot_recovery("sweetautorec timer");
}

/*
 * Hardware watchdog fallback (boot-arg sweetwdt=<seconds>, about 60): a kernel hang stops the autorec thread
 * call too (run30/run40 needed a manual reboot). The reset reason is set to "recovery" up front, then
 * watchdog_cl0 (0x10050000, S3C2410-style: WTCON 0, WTDAT 4, WTCNT 8) is armed with reset enabled and kicked
 * every 2 s from a thread call; if the kernel stops, the counter runs out and the SoC warm-resets into TWRP
 * (pstore survives). sweetwdttest=<seconds> stops kicking after that long, to prove the reset path.
 * The count assumes the 26 MHz oscillator (prescaler 256, divider 128: ~793 Hz).
 */
static volatile uint32_t *sm_wdt;
static uint32_t sm_wdt_count, sm_wdt_stop_ticks, sm_wdt_ticks;
static thread_call_t sm_wdt_tc;

static void
sm_wdt_kick(__unused thread_call_param_t p0, __unused thread_call_param_t p1)
{
	sm_wdt_ticks++;
	if (sm_wdt_stop_ticks && sm_wdt_ticks >= sm_wdt_stop_ticks) {
		if (sm_wdt_ticks == sm_wdt_stop_ticks) {
			sm_log("service: sweetwdttest: no more kicks (WTCNT %llu)", sm_wdt[2], 0, 0);
		}
		return;
	}
	sm_wdt[2] = sm_wdt_count;
	if (sm_wdt_ticks == 2 || sm_wdt_ticks == 3) {
		sm_log("service: wdt tick %llu WTCON %llx WTCNT %llu", sm_wdt_ticks, sm_wdt[0], sm_wdt[2]);
	}
	uint64_t deadline = 0;
	clock_interval_to_deadline(2, NSEC_PER_SEC, &deadline);
	thread_call_enter_delayed(sm_wdt_tc, deadline);
}

static void
sm_wdt_arm(uint32_t secs, uint32_t test_secs)
{
	volatile uint32_t *pmu = (volatile uint32_t *)ml_io_map(0x15860000U, 0x4000);
	pmu[0x808 / 4] = (pmu[0x808 / 4] & ~0x00FF0000U) | 0x004E0000U;
	pmu[0x80c / 4] = 0x12345604U;
	pmu[0x810 / 4] = 0xFFU;
	__asm__ volatile ("dsb sy" ::: "memory");
	sm_wdt = (volatile uint32_t *)ml_io_map(0x10050000U, 0x1000);
	if (sm_wdt == NULL) {
		return;
	}
	if (secs < 10) {
		secs = 10;
	}
	sm_wdt_count = secs * 793U;
	if (sm_wdt_count > 0xFFFFU) {
		sm_wdt_count = 0xFFFFU;
	}
	uint32_t old = sm_wdt[0];
	sm_wdt[0] = 0;
	sm_wdt[1] = sm_wdt_count;
	sm_wdt[2] = sm_wdt_count;
	sm_wdt[3] = 1;                                   /* WTCLRINT */
	sm_wdt[0] = (0xFFU << 8) | (1U << 5) | (3U << 3) | 1U;
	__asm__ volatile ("dsb sy" ::: "memory");
	sm_wdt_stop_ticks = test_secs / 2;
	sm_wdt_tc = thread_call_allocate(sm_wdt_kick, NULL);
	sm_log("service: sweetwdt armed %llu s (count %llu, old WTCON %llx)", secs, sm_wdt_count, old);
	if (sm_wdt_tc != NULL) {
		sm_wdt_kick(NULL, NULL);
	}
}

/* ---------------------------------------------------------------- service */

class SweetMali : public IOService {
	OSDeclareDefaultStructors(SweetMali);

public:
	bool start(IOService *provider) APPLE_KEXT_OVERRIDE;
};

OSDefineMetaClassAndStructors(SweetMali, IOService);

/*
 * Metal (Metal.framework) enumerates IOServiceMatching("IOAcceleratorES") and loads
 * /System/Library/Extensions/<MetalPluginName>.bundle, class <MetalPluginClassName>,
 * -initWithAcceleratorPort:. boot-arg sweetmetal=1 publishes one for the SweetMetal plugin.
 */
class IOAcceleratorES : public IOService {
	OSDeclareDefaultStructors(IOAcceleratorES);
};
OSDefineMetaClassAndStructors(IOAcceleratorES, IOService);


/* bring-up check through the same paths the user client uses: BO -> physical pages -> GPU map -> job */
static void
sweet_mali_service_selftest_one(int flushvariant)
{
	const uint64_t VA_JOB = 0x30000000ULL, VA_OUT = 0x30001000ULL;
	const uint32_t MAGIC = 0xC0FFEE03U + (uint32_t)flushvariant;
	int ctx = sweet_mali_ctx_create();
	IOBufferMemoryDescriptor *md = IOBufferMemoryDescriptor::inTaskWithOptions(kernel_task,
	    kIODirectionInOut, 2 * page_size, page_size);
	if (ctx < 0 || md == NULL) {
		sm_log("service selftest: no ctx/bo (ctx=%llx md=%llx)", (uint64_t)(int64_t)ctx, (uint64_t)(uintptr_t)md, 0);
		OSSafeReleaseNULL(md);
		return;
	}
	volatile uint32_t *p = (volatile uint32_t *)md->getBytesNoCopy();
	for (uint32_t i = 0; i < (2 * page_size) / 4; i++) {
		p[i] = 0;
	}
	IOByteCount l0 = 0, l1 = 0;
	addr64_t pa0 = md->getPhysicalSegment(0, &l0, kIOMemoryMapperNone);
	addr64_t pa1 = md->getPhysicalSegment(page_size, &l1, kIOMemoryMapperNone);
	if (pa0 == 0 || pa1 == 0 || sweet_mali_ctx_map(ctx, VA_JOB, pa0) || sweet_mali_ctx_map(ctx, VA_OUT, pa1)) {
		sm_log("service selftest: map failed (pa0=%llx pa1=%llx)", pa0, pa1, 0);
		md->release();
		sweet_mali_ctx_destroy(ctx);
		return;
	}
	volatile uint32_t *j = p;
	volatile uint32_t *o = p + page_size / 4;
	j[4] = (2U << 1) | 1U;
	j[8] = (uint32_t)VA_OUT;
	j[9] = (uint32_t)(VA_OUT >> 32);
	j[10] = 6U;
	j[12] = MAGIC;
	o[0] = 0xDEADBEEFU;
	o[1] = 0x11111111U;
	sm_log("service selftest v%llx: pa0=%llx pa1=%llx", (uint64_t)flushvariant, pa0, pa1);
	sm_flush_md(md, 2);
	sweet_mali_set_asflush(flushvariant);
	uint32_t r = sweet_mali_submit(ctx, 1, VA_JOB, 100);
	sm_flush_md(md, 2);
	sm_log("service selftest v%llx: status=%llx out=%llx", (uint64_t)flushvariant, r, o[0]);
	sm_log("service selftest v%llx: exc=%llx out1=%llx j12=%llx", (uint64_t)flushvariant, ((uint64_t)j[0] << 32) | o[1], j[12]);
	if (o[0] == MAGIC) {
		sm_log("service selftest v%llx: OK THE GPU WROTE A USER-CLIENT STYLE BO", (uint64_t)flushvariant, 0, 0);
	}
	md->release();
	sweet_mali_ctx_destroy(ctx);
}

static void
sweet_mali_service_selftest(void)
{
	sweet_mali_service_selftest_one(0);
	sweet_mali_service_selftest_one(1);
	sweet_mali_set_asflush(1);
}

bool
SweetMali::start(IOService *provider)
{
	int on = 0;
	sweet_mali_log_str("service: start() entered");
	if (!PE_parse_boot_argn("mali", &on, sizeof(on)) || !on) {
		return false;
	}
	if (!IOService::start(provider)) {
		return false;
	}
	sm_lock = IOLockAlloc();
	if (sm_fence_lk == NULL) {
		sm_fence_lk = IOSimpleLockAlloc();
	}
	sweet_mali_boot();
	if (sm_lock == NULL || !sweet_mali_up()) {
		sweet_mali_log_str("service: GPU core is not up, not registering");
		return false;
	}
	setProperty(kIOUserClientClassKey, "SweetMaliUserClient");
	IOLockLock(sm_lock);
	sweet_mali_service_selftest();
	IOLockUnlock(sm_lock);
	registerService();
	{
		uint32_t ws = 0, wt = 0;
		if (PE_parse_boot_argn("sweetwdt", &ws, sizeof(ws)) && ws != 0) {
			PE_parse_boot_argn("sweetwdttest", &wt, sizeof(wt));
			sm_wdt_arm(ws, wt);
		}
	}
	{
		/* boot-arg sweetautorec=<seconds>: unconditional reboot into the recovery after that long */
		uint32_t secs = 0;
		if (PE_parse_boot_argn("sweetautorec", &secs, sizeof(secs)) && secs != 0) {
			sm_pmu = (volatile uint32_t *)ml_io_map(0x15860000U, 0x4000);
			thread_call_t tc = thread_call_allocate(sm_autorec_fire, NULL);
			uint64_t deadline = 0;
			clock_interval_to_deadline(secs, NSEC_PER_SEC, &deadline);
			if (tc != NULL) {
				thread_call_enter_delayed(tc, deadline);
				sm_log("service: sweetautorec armed %llu s", secs, 0, 0);
				sweet_hard_reset_at(secs + 90);   /* if the logged reset never runs (run181), reset anyway */
			}
		}
	}
	PE_parse_boot_argn("sweetflushro", &sm_flush_ro, sizeof(sm_flush_ro));
	PE_parse_boot_argn("sweetfastflush", &sm_fastflush, sizeof(sm_fastflush));
	{
		int metal = 0;
		if (PE_parse_boot_argn("sweetmetal", &metal, sizeof(metal)) && metal != 0) {
			IOAcceleratorES *acc = OSTypeAlloc(IOAcceleratorES);
			if (acc != NULL && acc->init()) {
				acc->setProperty("MetalPluginName", "SweetMetal");
				acc->setProperty("MetalPluginClassName", "SweetMTLDevice");
				acc->setProperty(kIOUserClientClassKey, "SweetMaliUserClient");
				if (acc->attach(this)) {
					acc->registerService();
					sweet_mali_log_str("service: IOAcceleratorES (SweetMetal) published");
				}
			}
			OSSafeReleaseNULL(acc);
		}
	}
	sweet_mali_log_str("service: SweetMali registered");
	return true;
}

/* ------------------------------------------------------------ user client */

struct SMBo {
	IOMemoryDescriptor *md;
	uint64_t va;
	uint32_t pages;
	bool     mapped;
	bool     ext;   /* external physical range (display fb): outside the physmap, never flush by phystokv */
	bool     wired; /* imported user memory, prepare()d: complete() on free */
	bool     ro;    /* imported read-only (file/ramdisk pages, possibly in the kernel static region): never flushed (run68 panic) */
};

class SweetMaliUserClient : public IOUserClient {
	OSDeclareDefaultStructors(SweetMaliUserClient);

	task_t fTask;
	int    fCtx;
	int    fFence;      /* sm_fence slot of fTask, -1 = none yet */
	SMBo   fBo[SM_MAX_BO];

	void   freeBo(uint32_t i);

public:
	bool initWithTask(task_t owningTask, void *securityID, UInt32 type) APPLE_KEXT_OVERRIDE;
	IOReturn clientClose(void) APPLE_KEXT_OVERRIDE;
	IOReturn clientMemoryForType(UInt32 type, IOOptionBits *options, IOMemoryDescriptor **memory) APPLE_KEXT_OVERRIDE;
	IOReturn externalMethod(uint32_t selector, IOExternalMethodArguments *args,
	    IOExternalMethodDispatch *dispatch, OSObject *target,
	    void *reference) APPLE_KEXT_OVERRIDE;
};

OSDefineMetaClassAndStructors(SweetMaliUserClient, IOUserClient);

bool
SweetMaliUserClient::initWithTask(task_t owningTask, void *securityID, UInt32 type)
{
	if (!IOUserClient::initWithTask(owningTask, securityID, type)) {
		return false;
	}
	fTask = owningTask;
	fCtx = -1;
	fFence = -1;
	bzero(fBo, sizeof(fBo));
	return true;
}

/* lock held */
void
SweetMaliUserClient::freeBo(uint32_t i)
{
	SMBo *b = &fBo[i];
	if (b->md == NULL) {
		return;
	}
	if (b->mapped) {
		for (uint32_t k = 0; k < b->pages; k++) {
			sweet_mali_ctx_unmap(fCtx, b->va + ((uint64_t)k << 12));
		}
	}
	sm_total -= (uint64_t)b->pages << 12;
	if (b->wired) {
		b->md->complete();
	}
	b->md->release();
	bzero(b, sizeof(*b));
}

IOReturn
SweetMaliUserClient::clientClose(void)
{
	if (fFence >= 0 && sm_fence_lk != NULL) {
		IOSimpleLockLock(sm_fence_lk);
		if (sm_fence[fFence].refs > 0 && --sm_fence[fFence].refs == 0) {
			sm_fence[fFence].task = NULL;
			sm_fence[fFence].gen = ++sm_fence_gen;
			sm_fence[fFence].issued = sm_fence[fFence].done = 0;
		}
		IOSimpleLockUnlock(sm_fence_lk);
		fFence = -1;
		sweet_fb_gpu_kick();   /* a frame gated on this task is free to show */
	}
	IOLockLock(sm_lock);
	for (uint32_t i = 0; i < SM_MAX_BO; i++) {
		freeBo(i);
	}
	if (fCtx >= 0) {
		sweet_mali_ctx_destroy(fCtx);
		fCtx = -1;
	}
	IOLockUnlock(sm_lock);
	terminate();
	return kIOReturnSuccess;
}

IOReturn
SweetMaliUserClient::clientMemoryForType(UInt32 type, IOOptionBits *options, IOMemoryDescriptor **memory)
{
	IOReturn ret = kIOReturnBadArgument;
	IOLockLock(sm_lock);
	if (type >= 1 && type <= SM_MAX_BO && fBo[type - 1].md != NULL) {
		*options = 0;
		fBo[type - 1].md->retain();
		*memory = fBo[type - 1].md;
		ret = kIOReturnSuccess;
	}
	IOLockUnlock(sm_lock);
	return ret;
}

IOReturn
SweetMaliUserClient::externalMethod(uint32_t selector, IOExternalMethodArguments *args,
    __unused IOExternalMethodDispatch *dispatch, __unused OSObject *target, __unused void *reference)
{
	IOReturn ret = kIOReturnUnsupported;
	uint32_t ins = args->scalarInputCount, outs = args->scalarOutputCount;

	/* touches never wait for the GPU lock: a submit holds it for its cache flushes and the job, which stretched the
	 * unlock swipe into a long press (lock screen gallery opened instead of the home screen, run100) */
	if (selector == kSMTouch) {
		if (ins < 4) {
			return kIOReturnBadArgument;
		}
		sweet_hid_touch((int)args->scalarInput[0], (int)args->scalarInput[1],
		    (int)args->scalarInput[2], (int)args->scalarInput[3]);
		if (args->scalarInput[1]) {
			sweet_gov_touch();   /* synthetic touches boost like real ones */
		}
		return kIOReturnSuccess;
	}
	if (selector == kSMFence) {
		if (ins < 1 || sm_fence_lk == NULL) {
			return kIOReturnBadArgument;
		}
		uint64_t op = args->scalarInput[0], o0 = 0, o1 = 0;
		bool kick = false;
		IOSimpleLockLock(sm_fence_lk);
		if (fFence < 0 || sm_fence[fFence].task != fTask) {
			int fr = -1;
			fFence = -1;
			for (int i = 0; i < SM_FENCE_SLOTS; i++) {
				if (sm_fence[i].task == fTask) {
					fFence = i;
					break;
				}
				if (fr < 0 && sm_fence[i].task == NULL) {
					fr = i;
				}
			}
			if (fFence >= 0) {
				sm_fence[fFence].refs++;
			} else if (fr >= 0) {
				fFence = fr;
				sm_fence[fr].task = fTask;
				sm_fence[fr].gen = ++sm_fence_gen;
				sm_fence[fr].refs = 1;
				sm_fence[fr].issued = sm_fence[fr].done = 0;
			}
		}
		if (fFence >= 0) {
			if (op == 0) {
				o0 = ++sm_fence[fFence].issued;
			} else if (op == 3 && ins >= 3) {
				/* tag: input [3, ticket, surface id...]: these IOSurfaces are rendered by this task's ticket */
				uint64_t t = args->scalarInput[1];
				for (uint32_t k = 2; k < ins && t != 0 && t <= sm_fence[fFence].issued; k++) {
					uint32_t id = (uint32_t)args->scalarInput[k], j = SM_SURF_TAGS;
					if (id == 0) {
						continue;
					}
					for (uint32_t i = 0; i < SM_SURF_TAGS; i++) {
						if (sm_surf[i].id == id) {
							j = i;
							break;
						}
					}
					if (j == SM_SURF_TAGS) {
						j = sm_surf_next++ % SM_SURF_TAGS;
					}
					sm_surf[j].id = id;
					sm_surf[j].slot = (uint32_t)fFence;
					sm_surf[j].gen = sm_fence[fFence].gen;
					sm_surf[j].ticket = t;
				}
			} else if (op == 1 && ins >= 2) {
				uint64_t t = args->scalarInput[1];
				if (t > sm_fence[fFence].done && t <= sm_fence[fFence].issued) {
					sm_fence[fFence].done = t;
					kick = true;
				}
			}
			o0 = op == 2 ? sm_fence[fFence].issued : o0;
			o1 = sm_fence[fFence].done;
		}
		IOSimpleLockUnlock(sm_fence_lk);
		if (kick) {
			sweet_fb_gpu_kick();
		}
		if (fFence < 0) {
			return kIOReturnNoResources;
		}
		if (outs >= 1) {
			args->scalarOutput[0] = o0;
		}
		if (outs >= 2) {
			args->scalarOutput[1] = o1;
		}
		args->scalarOutputCount = outs < 2 ? outs : 2;
		return kIOReturnSuccess;
	}
	if (selector == kSMFBStats) {
		uint64_t st[16];
		sweet_fb_stats(st);
		for (uint32_t i = 0; i < outs && i < 16; i++) {
			args->scalarOutput[i] = st[i];
		}
		args->scalarOutputCount = outs < 16 ? outs : 16;
		return kIOReturnSuccess;
	}
	uint64_t lk0 = mach_absolute_time();
	IOLockLock(sm_lock);
	uint64_t lk1 = mach_absolute_time();   /* lock wait (vsync panel copies hold the lock), returned by kSMSubmitRange */
	switch (selector) {
	case kSMGetInfo: {
		uint32_t info[6];
		if (args->structureOutput == NULL || args->structureOutputSize < sizeof(info)) {
			ret = kIOReturnNoSpace;
			break;
		}
		sweet_mali_get_info(info);
		memcpy(args->structureOutput, info, sizeof(info));
		args->structureOutputSize = sizeof(info);
		ret = kIOReturnSuccess;
		break;
	}
	case kSMCreateBO: {
		if (ins < 1 || outs < 2) {
			ret = kIOReturnBadArgument;
			break;
		}
		uint64_t size = (args->scalarInput[0] + page_size - 1) & ~((uint64_t)page_size - 1);
		if (size == 0 || size > SM_MAX_BO_BYTES || sm_total + size > SM_MAX_TOTAL) {
			ret = kIOReturnNoSpace;
			break;
		}
		uint32_t slot = SM_MAX_BO;
		for (uint32_t i = 0; i < SM_MAX_BO; i++) {
			if (fBo[i].md == NULL) {
				slot = i;
				break;
			}
		}
		if (slot == SM_MAX_BO) {
			ret = kIOReturnNoResources;
			break;
		}
		IOBufferMemoryDescriptor *md = IOBufferMemoryDescriptor::inTaskWithOptions(kernel_task,
		    kIODirectionInOut, (vm_size_t)size, page_size);
		if (md == NULL) {
			ret = kIOReturnNoMemory;
			break;
		}
		bzero(md->getBytesNoCopy(), (size_t)size);
		IOByteCount len = 0;
		addr64_t pa = md->getPhysicalSegment(0, &len, kIOMemoryMapperNone);
		fBo[slot].md = md;
		fBo[slot].pages = (uint32_t)(size >> 12);
		fBo[slot].mapped = false;
		sm_total += size;
		args->scalarOutput[0] = slot + 1;
		args->scalarOutput[1] = pa;
		args->scalarOutputCount = 2;
		ret = kIOReturnSuccess;
		break;
	}
	case kSMMapBO: {
		if (ins < 2) {
			ret = kIOReturnBadArgument;
			break;
		}
		uint64_t h = args->scalarInput[0], va = args->scalarInput[1];
		if (h < 1 || h > SM_MAX_BO || fBo[h - 1].md == NULL || fBo[h - 1].mapped || (va & 0xFFF) ||
		    va >= (1ULL << 47)) {
			ret = kIOReturnBadArgument;
			break;
		}
		SMBo *b = &fBo[h - 1];
		if (fCtx < 0) {
			fCtx = sweet_mali_ctx_create();
			if (fCtx < 0) {
				ret = kIOReturnNoResources;
				break;
			}
		}
		ret = kIOReturnSuccess;
		for (uint32_t k = 0; k < b->pages; k++) {
			IOByteCount len = 0;
			addr64_t pa = b->md->getPhysicalSegment((IOByteCount)k << 12, &len, kIOMemoryMapperNone);
			if (pa == 0 || sweet_mali_ctx_map(fCtx, va + ((uint64_t)k << 12), pa)) {
				ret = kIOReturnNoMemory;
				break;
			}
		}
		if (ret == kIOReturnSuccess) {
			b->va = va;
			b->mapped = true;
			/* the bzero at create went through the kernel's cached mapping: write it back once, so a client that maps
			 * the BO write-combined (and so never flushes it) cannot have zero lines evicted over GPU data later */
			sm_flush_md(b->md, b->pages);
		}
		break;
	}
	case kSMSubmit: {
		if (ins < 3 || outs < 1 || fCtx < 0) {
			ret = kIOReturnBadArgument;
			break;
		}
		uint32_t tmo = (uint32_t)args->scalarInput[2];
		if (tmo > 5000) {
			tmo = 5000;
		}
		/* read-only imports too: other processes write those IOSurfaces (wallpaper, snapshots) through their CPU
		 * caches and the GPU read stale, black memory (run97); static-region pages are skipped in sm_flush_pa */
		for (uint32_t i = 0; i < SM_MAX_BO; i++) {
			if (fBo[i].md != NULL && fBo[i].mapped && !fBo[i].ext && (!fBo[i].ro || sm_flush_ro)) {
				sm_flush_md(fBo[i].md, fBo[i].pages);
			}
		}
		args->scalarOutput[0] = sweet_mali_submit(fCtx, (uint32_t)args->scalarInput[0], args->scalarInput[1], tmo);
		for (uint32_t i = 0; i < SM_MAX_BO; i++) {
			if (fBo[i].md != NULL && fBo[i].mapped && !fBo[i].ext && !fBo[i].ro) {
				sm_flush_md(fBo[i].md, fBo[i].pages);
			}
		}
		args->scalarOutputCount = 1;
		ret = kIOReturnSuccess;
		break;
	}
	case kSMSubmitList: {
		/* scalars: slot, job chain, timeout ms, nread; structure: GPU addresses, the first nread read by the job
		 * (flushed before it), the rest also written by it (cleaned+invalidated after it, the CPU reads them).
		 * BOs of <= 16 pages are always flushed: descriptors, small buffers. */
		const uint64_t *L = (const uint64_t *)args->structureInput;
		uint32_t n = (uint32_t)(args->structureInputSize / 8);
		if (ins < 4 || outs < 1 || fCtx < 0 || (n != 0 && L == NULL)) {
			ret = kIOReturnBadArgument;
			break;
		}
		uint32_t tmo = (uint32_t)args->scalarInput[2], nr = (uint32_t)args->scalarInput[3];
		if (tmo > 5000) {
			tmo = 5000;
		}
		if (n > 512) {
			n = 512;
		}
		if (nr > n) {
			nr = n;
		}
		for (uint32_t i = 0; i < SM_MAX_BO; i++) {
			if (fBo[i].md == NULL || !fBo[i].mapped || fBo[i].ext || (fBo[i].ro && !sm_flush_ro)) {
				continue;
			}
			bool hit = fBo[i].pages <= 16;
			for (uint32_t k = 0; k < n && !hit; k++) {
				hit = L[k] >= fBo[i].va && L[k] < fBo[i].va + ((uint64_t)fBo[i].pages << 12);
			}
			if (hit) {
				sm_flush_md(fBo[i].md, fBo[i].pages);
			}
		}
		args->scalarOutput[0] = sweet_mali_submit(fCtx, (uint32_t)args->scalarInput[0], args->scalarInput[1], tmo);
		for (uint32_t i = 0; i < SM_MAX_BO; i++) {
			if (fBo[i].md == NULL || !fBo[i].mapped || fBo[i].ext || fBo[i].ro) {
				continue;
			}
			bool hit = fBo[i].pages <= 16;
			for (uint32_t k = nr; k < n && !hit; k++) {
				hit = L[k] >= fBo[i].va && L[k] < fBo[i].va + ((uint64_t)fBo[i].pages << 12);
			}
			if (hit) {
				sm_flush_md(fBo[i].md, fBo[i].pages);
			}
		}
		args->scalarOutputCount = 1;
		ret = kIOReturnSuccess;
		break;
	}
	case kSMSubmitRange:
	case kSMFlushRange: {
		/* structure: pairs { va, len | flags } with len in bits 0..39 (0 = to the end of the BO), bit 62 = flush
		 * before the job, bit 63 = flush after it. kSMFlushRange: flush every range now. Read-only imports only when
		 * sweetflushro allows, external (display) ranges never. scalarInput[3] bit 0: also every BO of <= 16 pages. */
		const uint64_t *L = (const uint64_t *)args->structureInput;
		uint32_t n = (uint32_t)(args->structureInputSize / 16);
		bool sub = selector == kSMSubmitRange;
		if ((sub && (ins < 4 || outs < 1 || fCtx < 0)) || (n != 0 && L == NULL)) {
			ret = kIOReturnBadArgument;
			break;
		}
		if (n > 256) {
			n = 256;
		}
		uint64_t t0 = mach_absolute_time(), t1 = t0, t2 = t0;
		uint32_t second = 0xFFFFFFFFU;
		for (int pass = 0; pass < (sub ? 2 : 1); pass++) {
			uint64_t want = sub ? (pass == 0 ? (1ULL << 62) : (1ULL << 63)) : ~0ULL;
			if (pass == 1) {
				t1 = mach_absolute_time();
				smb_last_submit = t1;
				uint32_t tmo = (uint32_t)args->scalarInput[2] > 5000 ? 5000 : (uint32_t)args->scalarInput[2];
				args->scalarOutput[0] = sweet_mali_submit(fCtx, (uint32_t)args->scalarInput[0], args->scalarInput[1], tmo);
				/* scalarInput[4]: a fragment job chain run on slot 0 right after a clean vertex/tiler chain (one call per
				 * pass instead of two); its status comes back in scalarOutput[5] (0xFFFE = not run) */
				if (ins > 4 && args->scalarInput[4]) {
					second = args->scalarOutput[0] == 0 ? sweet_mali_submit(fCtx, 0, args->scalarInput[4], tmo) : 0xFFFEU;
				}
				t2 = mach_absolute_time();
			}
			for (uint32_t i = 0; i < SM_MAX_BO; i++) {
				SMBo *b = &fBo[i];
				if (b->md == NULL || !b->mapped || b->ext || (b->ro && (pass == 1 || !sm_flush_ro))) {
					continue;
				}
				uint64_t lo = b->va, hi = b->va + ((uint64_t)b->pages << 12);
				if (sub && (args->scalarInput[3] & 2) && !b->wired) {
					continue;   /* the client maps its own BOs write-combined: nothing cached to flush */
				}
				if (sub && (args->scalarInput[3] & 1) && b->pages <= 16) {
					sm_flush_md_range(b->md, 0, b->pages);
					continue;
				}
				/* union of the listed ranges inside this BO, as one page span (lists are short) */
				uint64_t s0 = ~0ULL, s1 = 0;
				for (uint32_t k = 0; k < n; k++) {
					uint64_t va = L[2 * k], f = L[2 * k + 1], len = f & 0xFFFFFFFFFFULL;
					if (!(f & want) || va < lo || va >= hi) {
						continue;
					}
					uint64_t e = len ? va + len : hi;
					if (e > hi) {
						e = hi;
					}
					if (va < s0) {
						s0 = va;
					}
					if (e > s1) {
						s1 = e;
					}
				}
				if (s1 > s0) {
					sm_flush_md_range(b->md, (uint32_t)((s0 - lo) >> 12), (uint32_t)((s1 - lo + 4095) >> 12));
				}
			}
		}
		if (sub) {
			uint64_t t3 = mach_absolute_time(), ns;
			uint32_t oc = outs;
			if (oc > 1) { absolutetime_to_nanoseconds(t1 - t0, &ns); args->scalarOutput[1] = ns; }
			if (oc > 2) { absolutetime_to_nanoseconds(t2 - t1, &ns); args->scalarOutput[2] = ns; }
			if (oc > 3) { absolutetime_to_nanoseconds(t3 - t2, &ns); args->scalarOutput[3] = ns; }
			if (oc > 4) { absolutetime_to_nanoseconds(lk1 - lk0, &ns); args->scalarOutput[4] = ns; }
			if (oc > 5) { args->scalarOutput[5] = second; }
			args->scalarOutputCount = oc > 6 ? 6 : oc;
		}
		ret = kIOReturnSuccess;
		break;
	}
	case kSMDestroyBO: {
		uint64_t h = ins > 0 ? args->scalarInput[0] : 0;
		if (h < 1 || h > SM_MAX_BO || fBo[h - 1].md == NULL) {
			ret = kIOReturnBadArgument;
			break;
		}
		freeBo((uint32_t)(h - 1));
		ret = kIOReturnSuccess;
		break;
	}
	case kSMMapFB: {
		/* wrap the boot/display framebuffer (physical RAM scanned out by the panel) as a BO */
		if (outs < 4) {
			ret = kIOReturnBadArgument;
			break;
		}
		PE_Video video;
		PE_current_console(&video);
		uint64_t fpa = video.v_baseAddr, rb = video.v_rowBytes, fh = video.v_height, fw = video.v_width;
		uint64_t fsize = (rb * fh + page_size - 1) & ~((uint64_t)page_size - 1);
		if (fpa == 0 || fsize == 0 || fsize > SM_MAX_BO_BYTES) {
			ret = kIOReturnNoDevice;
			break;
		}
		uint32_t slot = SM_MAX_BO;
		for (uint32_t i = 0; i < SM_MAX_BO; i++) {
			if (fBo[i].md == NULL) {
				slot = i;
				break;
			}
		}
		if (slot == SM_MAX_BO) {
			ret = kIOReturnNoResources;
			break;
		}
		IOMemoryDescriptor *fmd = IOMemoryDescriptor::withPhysicalAddress((IOPhysicalAddress)fpa,
		    (IOByteCount)fsize, kIODirectionInOut);
		if (fmd == NULL) {
			ret = kIOReturnNoMemory;
			break;
		}
		fBo[slot].md = fmd;
		fBo[slot].pages = (uint32_t)(fsize >> 12);
		fBo[slot].mapped = false;
		fBo[slot].ext = true;
		sm_total += fsize;
		args->scalarOutput[0] = slot + 1;
		args->scalarOutput[1] = fpa;
		args->scalarOutput[2] = rb;
		args->scalarOutput[3] = (fw << 16) | fh;
		args->scalarOutputCount = 4;
		ret = kIOReturnSuccess;
		break;
	}
	case kSMImportUser: {
		/* wire [uva, uva+len) of the calling task (an IOSurface) and map it at GPU va */
		if (ins < 3 || outs < 1) {
			ret = kIOReturnBadArgument;
			break;
		}
		uint64_t uva = args->scalarInput[0], len = args->scalarInput[1], va = args->scalarInput[2];
		if ((uva & 0xFFF) || (len & 0xFFF) || len == 0 || len > SM_MAX_BO_BYTES || (va & 0xFFF) || va >= (1ULL << 47) ||
		    sm_total + len > SM_MAX_TOTAL) {
			static int nl;
			if (nl++ < 8) {
				sm_log("import refused: len %llx va %llx total %llu MB", len, va, sm_total >> 20);
			}
			ret = kIOReturnBadArgument;
			break;
		}
		uint32_t slot = SM_MAX_BO;
		for (uint32_t i = 0; i < SM_MAX_BO; i++) {
			if (fBo[i].md == NULL) {
				slot = i;
				break;
			}
		}
		if (slot == SM_MAX_BO) {
			ret = kIOReturnNoResources;
			break;
		}
		if (fCtx < 0) {
			fCtx = sweet_mali_ctx_create();
			if (fCtx < 0) {
				ret = kIOReturnNoResources;
				break;
			}
		}
		bool ro = false;
		IOMemoryDescriptor *md = IOMemoryDescriptor::withAddressRange((mach_vm_address_t)uva, (mach_vm_size_t)len,
		    kIODirectionInOut, current_task());
		if (md == NULL) {
			ret = kIOReturnNoMemory;
			break;
		}
		if (md->prepare() != kIOReturnSuccess) {
			/* read-only client memory (decoded images, file mappings) cannot be wired for writing:
			 * the GPU only samples it, so wire it for device reads */
			md->release();
			md = IOMemoryDescriptor::withAddressRange((mach_vm_address_t)uva, (mach_vm_size_t)len, kIODirectionOut, current_task());
			ro = true;
			if (md == NULL || md->prepare() != kIOReturnSuccess) {
				if (md != NULL) {
					md->release();
				}
				static int nl;
				if (nl++ < 8) {
					sm_log("import prepare failed: uva %llx len %llx", uva, len, 0);
				}
				ret = kIOReturnVMError;
				break;
			}
		}
		uint32_t pages = (uint32_t)(len >> 12), k;
		ret = kIOReturnSuccess;
		for (k = 0; k < pages; k++) {
			IOByteCount l = 0;
			addr64_t pa = md->getPhysicalSegment((IOByteCount)k << 12, &l, kIOMemoryMapperNone);
			if (pa == 0 || sweet_mali_ctx_map(fCtx, va + ((uint64_t)k << 12), pa)) {
				ret = kIOReturnNoMemory;
				break;
			}
		}
		if (ret != kIOReturnSuccess) {
			for (uint32_t u = 0; u < k; u++) {
				sweet_mali_ctx_unmap(fCtx, va + ((uint64_t)u << 12));
			}
			md->complete();
			md->release();
			break;
		}
		fBo[slot].md = md;
		fBo[slot].pages = pages;
		fBo[slot].va = va;
		fBo[slot].mapped = true;
		fBo[slot].ext = false;
		fBo[slot].wired = true;
		fBo[slot].ro = ro;
		sm_total += len;
		args->scalarOutput[0] = slot + 1;
		args->scalarOutputCount = 1;
		break;
	}
	case kSMRebootRecovery: {
		IOLockUnlock(sm_lock);
		sm_reboot_recovery("user client");
		return kIOReturnSuccess;
	}
	case kSMKeep: {
		if (args->structureInput != NULL && args->structureInputSize != 0) {
			uint32_t n = args->structureInputSize < 160 ? (uint32_t)args->structureInputSize : 160;
			if (sm_keep_len + n + 2 < sizeof(sm_keep_buf)) {
				memcpy(sm_keep_buf + sm_keep_len, args->structureInput, n);
				sm_keep_len += n;
				sm_keep_buf[sm_keep_len++] = '\n';
			}
		}
		ret = kIOReturnSuccess;
		break;
	}
	case kSMTouch: {
		if (args->scalarInputCount < 4) {
			ret = kIOReturnBadArgument;
			break;
		}
		IOLockUnlock(sm_lock);
		sweet_hid_touch((int)args->scalarInput[0], (int)args->scalarInput[1],
		    (int)args->scalarInput[2], (int)args->scalarInput[3]);
		return kIOReturnSuccess;
	}
	case kSMLog: {
		char buf[160];
		if (args->structureInput == NULL || args->structureInputSize == 0) {
			ret = kIOReturnBadArgument;
			break;
		}
		size_t n = args->structureInputSize < sizeof(buf) - 8 ? args->structureInputSize : sizeof(buf) - 8;
		memcpy(buf, "user: ", 6);
		memcpy(buf + 6, args->structureInput, n);
		buf[6 + n] = 0;
		sweet_mali_log_str(buf);
		ret = kIOReturnSuccess;
		break;
	}
	default:
		break;
	}
	IOLockUnlock(sm_lock);
	return ret;
}


/* ------------------------------------------------------------ GPU compositor
 * sweet_mali_blit(): the panel copy of one CoreAnimation layer, done by a Mali compute job
 * (one 32-bit pixel per invocation, shader CS_COPY compiled by Mesa's Valhall compiler,
 * tools/shadergen). Called from AppleCLCD::present (SweetFramebuffer.cpp) when sweetgpucomp=1.
 * Returns 0 when the GPU copied the layer; anything else makes the caller do the CPU copy.
 */
static const uint8_t smb_cs_copy[] = {
0x3c,0x86,0xc0,0x80,0x04,0xc0,0xf0,0x00,0x40,0x12,0x00,0x00,0x30,0xc0,0x1f,0x50,
0x7c,0xc8,0xc0,0x19,0x01,0xc0,0xb4,0x00,0x3d,0x84,0x0a,0x00,0x00,0xc1,0xa0,0x00,
0x7d,0x85,0x0a,0x00,0x00,0xc2,0xa0,0x00,0x41,0x00,0x00,0x00,0x00,0xc1,0xa8,0x00,
0x42,0x40,0x00,0x00,0x00,0xc0,0xa8,0x00,0x80,0x41,0x00,0x00,0x00,0xc1,0xa8,0x00,
0x01,0x80,0xc0,0x00,0x04,0xc2,0xf0,0x00,0x42,0x81,0x00,0x00,0x00,0xc2,0xa8,0x00,
0x41,0x00,0x00,0x00,0x00,0xc4,0x91,0x00,0x42,0x00,0x00,0x00,0x00,0xc5,0x91,0x00,
0x44,0x00,0x00,0x18,0x82,0x81,0x60,0x00,0x82,0x40,0x00,0x00,0x00,0xc0,0xa8,0x00,
0x00,0x82,0xc0,0x00,0x04,0xc2,0xf0,0x00,0x42,0x83,0x00,0x00,0x00,0xc2,0xa8,0x00,
0x40,0x00,0x00,0x00,0x00,0xc4,0x91,0x00,0x42,0x00,0x00,0x00,0x00,0xc5,0x91,0x08,
0x44,0x00,0x00,0x58,0x02,0x41,0x61,0x00,0xc0,0x01,0x00,0x00,0x10,0xc0,0x1f,0x50,
0x00,0x00,0x00,0x00,0x00,0xc0,0x00,0x78,0x00,0x00,0x00,0x00,0x00,0xc0,0x00,0x78,
0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
};
/* CS_COPY4 (tools/shadergen): four pixels per invocation, LOAD.i128/STORE.i128; push [24] = width / 4. Used when the
 * source, destination and both strides are 16-byte aligned and the width is a multiple of 4 (boot-arg sweetblit4=0:
 * never). The 1-pixel copy took 3.1-4.0 ms a frame (run201), a quarter of the 60 Hz budget. */
static const uint8_t smb_cs_copy4[] = {
0x3c,0x86,0xc0,0x80,0x04,0xc0,0xf0,0x00,0x40,0x11,0x00,0x00,0x30,0xc0,0x1f,0x50,
0x7c,0xc9,0xc0,0x11,0x01,0xc0,0xb4,0x00,0x3d,0x84,0x0a,0x00,0x00,0xc1,0xa0,0x00,
0x41,0x00,0x00,0x00,0x00,0xc1,0xa8,0x00,0x7d,0x85,0x0a,0x00,0x00,0xc2,0xa0,0x00,
0x42,0x40,0x00,0x00,0x00,0xc0,0xa8,0x00,0x80,0x41,0x00,0x00,0x00,0xc1,0xa8,0x00,
0x01,0x80,0xc0,0x00,0x04,0xc2,0xf0,0x00,0x42,0x81,0x00,0x00,0x00,0xc2,0xa8,0x00,
0x82,0x40,0x00,0x00,0x00,0xc0,0xa8,0x00,0x00,0x82,0xc0,0x00,0x04,0xc3,0xf0,0x00,
0x43,0x83,0x00,0x00,0x00,0xc3,0xa8,0x00,0x41,0x00,0x00,0x00,0x00,0xc4,0x91,0x00,
0x42,0x00,0x00,0x00,0x00,0xc5,0x91,0x00,0x44,0x00,0x00,0x38,0xf8,0x84,0x60,0x00,
0x43,0x00,0x00,0x00,0x00,0xc1,0x91,0x08,0x40,0x00,0x00,0x78,0x08,0x44,0x61,0x00,
0xc0,0x01,0x00,0x00,0x10,0xc0,0x1f,0x50,0x00,0x00,0x00,0x00,0x00,0xc0,0x00,0x78,
0x00,0x00,0x00,0x00,0x00,0xc0,0x00,0x78,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
};
/* CS_COPY4U: CS_COPY4 for an 8-byte aligned source (the middle 1080 of the 1125-wide surface starts at byte 88):
 * two LOAD.i64, one STORE.i128 */
static const uint8_t smb_cs_copy4u[] = {
0x3c,0x86,0xc0,0x80,0x04,0xc0,0xf0,0x00,0x40,0x16,0x00,0x00,0x30,0xc0,0x1f,0x50,
0x7c,0xc9,0xc0,0x11,0x01,0xc0,0xb4,0x00,0x3d,0x84,0x0a,0x00,0x00,0xc1,0xa0,0x00,
0x7d,0x85,0x0a,0x00,0x00,0xc2,0xa0,0x00,0x41,0x00,0x00,0x00,0x00,0xc1,0xa8,0x00,
0x42,0x40,0x00,0x00,0x00,0xc0,0xa8,0x00,0x80,0x41,0x00,0x00,0x00,0xc1,0xa8,0x00,
0x01,0x80,0xc0,0x00,0x04,0xc2,0xf0,0x00,0x42,0x81,0x00,0x00,0x00,0xc2,0xa8,0x00,
0x01,0x08,0x00,0x00,0x00,0xc3,0x10,0x01,0x03,0x01,0xc0,0x00,0x04,0xc4,0xf0,0x00,
0x44,0x02,0x00,0x00,0x00,0xc4,0xa8,0x00,0x43,0x00,0x00,0x00,0x00,0xc6,0x91,0x00,
0x44,0x00,0x00,0x00,0x00,0xc7,0x91,0x00,0x46,0x00,0x00,0x28,0xf4,0x84,0x60,0x00,
0x41,0x00,0x00,0x00,0x00,0xc6,0x91,0x00,0x42,0x00,0x00,0x00,0x00,0xc7,0x91,0x08,
0x46,0x00,0x00,0x68,0xf4,0x82,0x60,0x00,0x82,0x40,0x00,0x00,0x00,0xc0,0xa8,0x00,
0x00,0x82,0xc0,0x00,0x04,0xc1,0xf0,0x00,0x41,0x83,0x00,0x00,0x00,0xc1,0xa8,0x10,
0x40,0x00,0x00,0xb8,0x08,0x42,0x61,0x00,0xc0,0x01,0x00,0x00,0x10,0xc0,0x1f,0x50,
0x00,0x00,0x00,0x00,0x00,0xc0,0x00,0x78,0x00,0x00,0x00,0x00,0x00,0xc0,0x00,0x78,
0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
};
#define SMB_CS_PRELOAD  0x3000u                 /* r60,r61 (preload >> 48) */
#define SMB_VA_DESC     0x10000000ULL
#define SMB_VA_FB       0x50000000ULL
#define SMB_VA_SRC      0x60000000ULL
#define SMB_SRC_SPAN    0x4000000ULL            /* 64 MiB per cached source */
#define SMB_SLOTS       4

struct SMBSrc {
	IOMemoryDescriptor *md;
	uint64_t len, pa0, palast, lru;
	uint32_t pages;
};

static int smb_ctx = -1;
static bool smb_dead;
static IOBufferMemoryDescriptor *smb_desc;
static uint64_t smb_fbpa, smb_fbsize, smb_tick, smb_ok, smb_fail;
static uint32_t smb_failrun;
static SMBSrc smb_src[SMB_SLOTS];

/* lock held */
static bool
smb_init(uint64_t fbpa, uint64_t fbsize)
{
	if (smb_ctx >= 0) {
		return smb_fbpa == fbpa && smb_fbsize == fbsize;
	}
	if (!sweet_mali_up()) {
		return false;
	}
	smb_desc = IOBufferMemoryDescriptor::inTaskWithOptions(kernel_task, kIODirectionInOut, 4096, 4096);
	if (smb_desc == NULL) {
		return false;
	}
	int ctx = sweet_mali_ctx_create();
	if (ctx < 0) {
		smb_desc->release();
		smb_desc = NULL;
		return false;
	}
	IOByteCount l = 0;
	addr64_t dpa = smb_desc->getPhysicalSegment(0, &l, kIOMemoryMapperNone);
	if (dpa == 0 || sweet_mali_ctx_map(ctx, SMB_VA_DESC, dpa)) {
		sweet_mali_ctx_destroy(ctx);
		smb_desc->release();
		smb_desc = NULL;
		return false;
	}
	for (uint64_t o = 0; o < fbsize; o += 4096) {
		if (sweet_mali_ctx_map(ctx, SMB_VA_FB + o, fbpa + o)) {
			sweet_mali_ctx_destroy(ctx);
			smb_desc->release();
			smb_desc = NULL;
			return false;
		}
	}
	uint8_t *d = (uint8_t *)smb_desc->getBytesNoCopy();
	bzero(d, 4096);
	uint32_t *j = (uint32_t *)d;
	j[4] = (4u << 1) | (1u << 16);                  /* COMPUTE, index 1 */
	j[8] = (64u - 1) | (1u << 31);                  /* workgroup 64x1x1, allow merging */
	j[9] = 1u | (2u << 14);                         /* task increment 1, axis Z */
	j[10] = 1; j[11] = 1; j[12] = 1;
	j[17] = 4;                                      /* FAU count (64-bit entries) */
	uint64_t sp = SMB_VA_DESC + 0x100, tls = SMB_VA_DESC + 0x140, fau = SMB_VA_DESC + 0x200;
	j[26] = (uint32_t)sp;  j[27] = (uint32_t)(sp >> 32);
	j[28] = (uint32_t)tls; j[29] = (uint32_t)(tls >> 32);
	j[30] = (uint32_t)fau; j[31] = (uint32_t)(fau >> 32);
	uint32_t *spd = (uint32_t *)(d + 0x100);
	uint64_t bin = SMB_VA_DESC + 0x400;
	spd[0] = 8u | (1u << 4) | (2u << 30);           /* shader, compute, 32 regs/thread */
	spd[1] = SMB_CS_PRELOAD;
	spd[2] = (uint32_t)bin; spd[3] = (uint32_t)(bin >> 32);
	uint32_t *ls = (uint32_t *)(d + 0x140);
	ls[1] = 31;                                     /* no workgroup memory */
	memcpy(d + 0x400, smb_cs_copy, sizeof(smb_cs_copy));
	/* second shader program (0x180): CS_COPY4 at 0x800, same registers and preload */
	{
		uint32_t *spd4 = (uint32_t *)(d + 0x180);
		uint64_t bin4 = SMB_VA_DESC + 0x800;
		spd4[0] = spd[0];
		spd4[1] = spd[1];
		spd4[2] = (uint32_t)bin4; spd4[3] = (uint32_t)(bin4 >> 32);
		memcpy(d + 0x800, smb_cs_copy4, sizeof(smb_cs_copy4));
		uint32_t *spd4u = (uint32_t *)(d + 0x1C0);
		uint64_t bin4u = SMB_VA_DESC + 0xA00;
		spd4u[0] = spd[0];
		spd4u[1] = spd[1];
		spd4u[2] = (uint32_t)bin4u; spd4u[3] = (uint32_t)(bin4u >> 32);
		memcpy(d + 0xA00, smb_cs_copy4u, sizeof(smb_cs_copy4u));
	}
	smb_fbpa = fbpa;
	smb_fbsize = fbsize;
	smb_ctx = ctx;
	sm_log("gpucomp: ready fb=%llx size=%llx ctx=%llu", fbpa, fbsize, (uint64_t)ctx);
	return true;
}

/* lock held: GPU VA of the cached mapping of srcmd, or 0 */
static uint64_t
smb_src_va(IOMemoryDescriptor *md)
{
	IOByteCount l = 0;
	uint64_t len = md->getLength();
	if (len == 0 || len > SMB_SRC_SPAN) {
		return 0;
	}
	uint64_t pa0 = md->getPhysicalSegment(0, &l, kIOMemoryMapperNone);
	uint64_t pal = md->getPhysicalSegment((len - 1) & ~0xFFFULL, &l, kIOMemoryMapperNone);
	if (pa0 == 0 || pal == 0) {
		return 0;
	}
	smb_tick++;
	uint32_t victim = 0;
	for (uint32_t i = 0; i < SMB_SLOTS; i++) {
		SMBSrc *e = &smb_src[i];
		if (e->md == md && e->len == len && e->pa0 == pa0 && e->palast == pal) {
			e->lru = smb_tick;
			return SMB_VA_SRC + i * SMB_SRC_SPAN;
		}
		if (e->lru < smb_src[victim].lru) {
			victim = i;
		}
	}
	SMBSrc *e = &smb_src[victim];
	uint64_t base = SMB_VA_SRC + victim * SMB_SRC_SPAN;
	for (uint32_t k = 0; k < e->pages; k++) {
		sweet_mali_ctx_unmap(smb_ctx, base + ((uint64_t)k << 12));
	}
	bzero(e, sizeof(*e));
	uint32_t pages = (uint32_t)((len + 4095) >> 12);
	for (uint32_t k = 0; k < pages; k++) {
		uint64_t pa = md->getPhysicalSegment((IOByteCount)k << 12, &l, kIOMemoryMapperNone);
		if (pa == 0 || sweet_mali_ctx_map(smb_ctx, base + ((uint64_t)k << 12), pa & ~0xFFFULL)) {
			for (uint32_t u = 0; u < k; u++) {
				sweet_mali_ctx_unmap(smb_ctx, base + ((uint64_t)u << 12));
			}
			return 0;
		}
	}
	e->md = md; e->len = len; e->pa0 = pa0; e->palast = pal; e->pages = pages; e->lru = smb_tick;
	return base;
}

static uintptr_t smb_seen_md[8];
static uint64_t smb_seen_pa[8], smb_seen_i, smb_fl_ns, smb_job_ns, smb_flushes, smb_n4, smb_job4_ns;
static int smb_v4 = -1;                         /* CS_COPY4 allowed: boot-arg sweetblit4 (default 1), 0 after a failure */
int sweet_mali_blit(IOMemoryDescriptor *srcmd, uint64_t srcoff, uint32_t srcbpr, uint64_t fbpa, uint32_t fbbpr,
    uint64_t fbsize, uint64_t dstoff, uint32_t w, uint32_t h);

int
sweet_mali_blit(IOMemoryDescriptor *srcmd, uint64_t srcoff, uint32_t srcbpr, uint64_t fbpa, uint32_t fbbpr,
    uint64_t fbsize, uint64_t dstoff, uint32_t w, uint32_t h)
{
	if (sm_lock == NULL || smb_dead || srcmd == NULL || w == 0 || h == 0) {
		return -1;
	}
	IOLockLock(sm_lock);
	int ret = -1;
	uint64_t bt0 = 0, bt1 = 0;
	uint64_t sva = 0, last = srcoff + (uint64_t)(h - 1) * srcbpr + (uint64_t)w * 4;
	if (!smb_init(fbpa, fbsize) || dstoff + (uint64_t)(h - 1) * fbbpr + (uint64_t)w * 4 > fbsize ||
	    last > srcmd->getLength() || (sva = smb_src_va(srcmd)) == 0) {
		goto out;
	}
	/* a CPU-drawn source sits in the CPU caches: clean it to memory first. A Mali-rendered source (backboardd's Metal
	 * plugin draws every layer with the GPU and never touches render targets with the CPU) only needs this once, for
	 * dirty lines left from before the GPU took it over: flushing the whole 11 MB surface on every vsync held sm_lock
	 * for milliseconds per frame (run163). A source is flushed again whenever no GPU job was submitted in the last
	 * 2 s (CPU fallback). Boot-arg sweetpresflush=1 = always flush. */
	bt0 = mach_absolute_time();
	{
		static int always = -1;
		if (always < 0) {
			always = 0;
			PE_parse_boot_argn("sweetpresflush", &always, sizeof(always));
		}
		IOByteCount l0 = 0;
		uint64_t pa0 = srcmd->getPhysicalSegment((IOByteCount)(srcoff & ~0xFFFULL), &l0, kIOMemoryMapperNone);
		uint64_t ns_since = ~0ULL;
		if (smb_last_submit) {
			absolutetime_to_nanoseconds(bt0 - smb_last_submit, &ns_since);
		}
		bool known = false;
		for (int i = 0; i < 8; i++) {
			if (smb_seen_md[i] == (uintptr_t)srcmd && smb_seen_pa[i] == pa0) {
				known = true;
			}
		}
		if (always || !known || ns_since > 2000000000ULL) {
			for (uint64_t o = srcoff & ~0xFFFULL; o < last; o += 4096) {
				IOByteCount l = 0;
				uint64_t pa = srcmd->getPhysicalSegment((IOByteCount)o, &l, kIOMemoryMapperNone);
				if (pa != 0) {
					sm_flush_pa(pa & ~0xFFFULL, 4096);
				}
			}
			smb_flushes++;
			if (!known) {
				smb_seen_md[smb_seen_i & 7] = (uintptr_t)srcmd;
				smb_seen_pa[smb_seen_i & 7] = pa0;
				smb_seen_i++;
			}
		}
	}
	bt1 = mach_absolute_time();
	{
		uint8_t *d = (uint8_t *)smb_desc->getBytesNoCopy();
		uint32_t *j = (uint32_t *)d;
		uint64_t *fau = (uint64_t *)(d + 0x200);
		if (smb_v4 < 0) {
			int v = 1;
			PE_parse_boot_argn("sweetblit4", &v, sizeof(v));
			smb_v4 = v != 0 ? 1 : 0;
		}
		/* sva is page aligned, so the source alignment is srcoff's */
		bool v4a = smb_v4 == 1 && ((srcoff | dstoff | srcbpr | fbbpr) & 15) == 0 && (w & 3) == 0;
		bool v4u = !v4a && smb_v4 == 1 && ((srcoff | srcbpr) & 7) == 0 && ((dstoff | fbbpr) & 15) == 0 && (w & 3) == 0;
		bool v4 = v4a || v4u;
		uint64_t spa = SMB_VA_DESC + (v4a ? 0x180 : v4u ? 0x1C0 : 0x100);
		uint32_t units = v4 ? w / 4 : w;
		j[26] = (uint32_t)spa; j[27] = (uint32_t)(spa >> 32);
		fau[0] = sva + srcoff;
		fau[1] = SMB_VA_FB + dstoff;
		fau[2] = (uint64_t)srcbpr | ((uint64_t)fbbpr << 32);
		fau[3] = units;
		j[0] = j[1] = j[2] = j[3] = 0;
		j[10] = (units + 63) / 64;
		j[11] = h;
		sm_flush_md(smb_desc, 1);
		uint32_t r = sweet_mali_submit(smb_ctx, 1, SMB_VA_DESC, 200);
		if (r == 0) {
			ret = 0;
			smb_ok++;
			smb_failrun = 0;
		} else if (v4) {
			/* never again with CS_COPY4; this frame falls back to the CPU copy */
			smb_v4 = 0;
			smb_fail++;
			sm_log("gpucomp: CS_COPY4 job status %llx: back to the 1-pixel copy (ok %llu fail %llu)", r, smb_ok, smb_fail);
		} else {
			smb_fail++;
			if (++smb_failrun >= 3) {
				smb_dead = true;
			}
			sm_log("gpucomp: job status %llx fails %llu (dead=%llu)", r, smb_fail, smb_dead);
		}
		{
			uint64_t bt2 = mach_absolute_time(), a, b;
			absolutetime_to_nanoseconds(bt1 - bt0, &a);
			absolutetime_to_nanoseconds(bt2 - bt1, &b);
			smb_fl_ns += a;
			smb_job_ns += b;
			if (v4 && r == 0) {
				smb_n4++;
				smb_job4_ns += b;
			}
		}
		if (smb_ok == 1 || (smb_ok % 300) == 0) {
			{ uint64_t ns; absolutetime_to_nanoseconds(mach_absolute_time(), &ns);
			  sm_log("gpucomp: ok=%llu fail=%llu at %llus", smb_ok, smb_fail, ns / 1000000000ULL); }
			sm_log("gpucomp: avg flush %llu us job %llu us, full flushes %llu", smb_fl_ns / 1000 / (smb_ok ? smb_ok : 1),
			    smb_job_ns / 1000 / (smb_ok ? smb_ok : 1), smb_flushes);
			sm_log("gpucomp: copy4 %llu jobs avg %llu us (last w %llu)", smb_n4, smb_job4_ns / 1000 / (smb_n4 ? smb_n4 : 1), (uint64_t)w);
		}
	}
out:
	IOLockUnlock(sm_lock);
	return ret;
}

#endif /* ARM64_BOARD_CONFIG_SWEET */
EOF_SWEET_SRC
