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

#define SM_MAX_BO        64
#define SM_MAX_BO_BYTES  (64ULL << 20)
#define SM_MAX_TOTAL     (256ULL << 20)

enum {
	kSMGetInfo = 0,
	kSMCreateBO = 1,
	kSMMapBO = 2,
	kSMSubmit = 3,
	kSMDestroyBO = 4,
	kSMLog = 5,
	kSMMapFB = 6,
	kSMRebootRecovery = 7,
};

static IOLock *sm_lock;                 /* serializes all hardware / context calls */
static uint64_t sm_total;               /* bytes of BOs alive */

static void
sm_log(const char *fmt, uint64_t a, uint64_t b, uint64_t c)
{
	char line[160];
	snprintf(line, sizeof(line), fmt, a, b, c);
	sweet_mali_log_str(line);
}

extern "C" void flush_dcache64(addr64_t addr, unsigned count, int phys);

/* The GPU is not cache coherent: clean+invalidate a buffer's pages by physical address. */
static void
sm_flush_md(IOMemoryDescriptor *md, uint32_t pages)
{
	for (uint32_t k = 0; k < pages; k++) {
		IOByteCount len = 0;
		addr64_t pa = md->getPhysicalSegment((IOByteCount)k << 12, &len, kIOMemoryMapperNone);
		if (pa != 0) {
			flush_dcache64(pa, page_size, TRUE);
		}
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

static void
sm_reboot_recovery(const char *why)
{
	char line[96];
	snprintf(line, sizeof(line), "reboot to recovery (%s)", why);
	sweet_mali_log_str(line);
	IOSleep(400);
	volatile uint32_t *r = (volatile uint32_t *)ml_io_map(0x15860000U, 0x4000);
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

static void
sm_autorec_fire(__unused thread_call_param_t p0, __unused thread_call_param_t p1)
{
	sm_reboot_recovery("sweetautorec timer");
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
		/* boot-arg sweetautorec=<seconds>: unconditional reboot into the recovery after that long */
		uint32_t secs = 0;
		if (PE_parse_boot_argn("sweetautorec", &secs, sizeof(secs)) && secs != 0) {
			thread_call_t tc = thread_call_allocate(sm_autorec_fire, NULL);
			uint64_t deadline = 0;
			clock_interval_to_deadline(secs, NSEC_PER_SEC, &deadline);
			if (tc != NULL) {
				thread_call_enter_delayed(tc, deadline);
				sm_log("service: sweetautorec armed %llu s", secs, 0, 0);
			}
		}
	}
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
};

class SweetMaliUserClient : public IOUserClient {
	OSDeclareDefaultStructors(SweetMaliUserClient);

	task_t fTask;
	int    fCtx;
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
	b->md->release();
	bzero(b, sizeof(*b));
}

IOReturn
SweetMaliUserClient::clientClose(void)
{
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

	IOLockLock(sm_lock);
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
		for (uint32_t i = 0; i < SM_MAX_BO; i++) {
			if (fBo[i].md != NULL && fBo[i].mapped && !fBo[i].ext) {
				sm_flush_md(fBo[i].md, fBo[i].pages);
			}
		}
		args->scalarOutput[0] = sweet_mali_submit(fCtx, (uint32_t)args->scalarInput[0], args->scalarInput[1], tmo);
		for (uint32_t i = 0; i < SM_MAX_BO; i++) {
			if (fBo[i].md != NULL && fBo[i].mapped && !fBo[i].ext) {
				sm_flush_md(fBo[i].md, fBo[i].pages);
			}
		}
		args->scalarOutputCount = 1;
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
	case kSMRebootRecovery: {
		IOLockUnlock(sm_lock);
		sm_reboot_recovery("user client");
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
	uint64_t sva = 0, last = srcoff + (uint64_t)(h - 1) * srcbpr + (uint64_t)w * 4;
	if (!smb_init(fbpa, fbsize) || dstoff + (uint64_t)(h - 1) * fbbpr + (uint64_t)w * 4 > fbsize ||
	    last > srcmd->getLength() || (sva = smb_src_va(srcmd)) == 0) {
		goto out;
	}
	/* CoreAnimation wrote the source through the CPU caches */
	for (uint64_t o = srcoff & ~0xFFFULL; o < last; o += 4096) {
		IOByteCount l = 0;
		uint64_t pa = srcmd->getPhysicalSegment((IOByteCount)o, &l, kIOMemoryMapperNone);
		if (pa != 0) {
			flush_dcache64(pa & ~0xFFFULL, 4096, TRUE);
		}
	}
	{
		uint8_t *d = (uint8_t *)smb_desc->getBytesNoCopy();
		uint32_t *j = (uint32_t *)d;
		uint64_t *fau = (uint64_t *)(d + 0x200);
		fau[0] = sva + srcoff;
		fau[1] = SMB_VA_FB + dstoff;
		fau[2] = (uint64_t)srcbpr | ((uint64_t)fbbpr << 32);
		fau[3] = w;
		j[0] = j[1] = j[2] = j[3] = 0;
		j[10] = (w + 63) / 64;
		j[11] = h;
		sm_flush_md(smb_desc, 1);
		uint32_t r = sweet_mali_submit(smb_ctx, 1, SMB_VA_DESC, 200);
		if (r == 0) {
			ret = 0;
			smb_ok++;
			smb_failrun = 0;
		} else {
			smb_fail++;
			if (++smb_failrun >= 3) {
				smb_dead = true;
			}
			sm_log("gpucomp: job status %llx fails %llu (dead=%llu)", r, smb_fail, smb_dead);
		}
		if (smb_ok == 1 || (smb_ok % 600) == 0) {
			sm_log("gpucomp: ok=%llu fail=%llu last %llux...", smb_ok, smb_fail, ((uint64_t)w << 32) | h);
		}
	}
out:
	IOLockUnlock(sm_lock);
	return ret;
}

#endif /* ARM64_BOARD_CONFIG_SWEET */
EOF_SWEET_SRC
