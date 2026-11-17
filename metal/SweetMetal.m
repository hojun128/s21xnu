#include <dlfcn.h>
#include <pthread.h>
#include <objc/message.h>
/*
 * SweetMetal.bundle: Metal driver plugin for the S21 Mali-G78 (phase 1 skeleton).
 * Loaded by Metal.framework through the kernel's IOAcceleratorES service
 * (MetalPluginName = SweetMetal, MetalPluginClassName = SweetMTLDevice).
 * Only hands out a device inside the test program (process "malitest") so that
 * CoreAnimation keeps its software renderer. Every selector Metal calls that is not
 * implemented yet is logged ("SweetMTL: unimplemented ...") and answered with 0/nil.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <mach/mach.h>
#include <stdarg.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <errno.h>

typedef mach_port_t io_object_t, io_service_t, io_connect_t;
extern const mach_port_t kIOMasterPortDefault;
extern io_service_t IOServiceGetMatchingService(mach_port_t, CFDictionaryRef);
extern CFMutableDictionaryRef IOServiceMatching(const char *);
extern kern_return_t IOServiceOpen(io_service_t, task_port_t, uint32_t, io_connect_t *);
extern kern_return_t IOConnectCallMethod(io_connect_t, uint32_t, const uint64_t *, uint32_t,
    const void *, size_t, uint64_t *, uint32_t *, void *, size_t *);

static io_connect_t sm_conn;
static id sm_dbg_tex[4];          /* textures to thumbnail at the end of the run (rgb332 ids 14..17) */
static volatile int sm_describe;   /* >0: describe the draws of the next passes (set after the unlock swipe) */

/* Lines worth keeping are also collected here and replayed at the end of a test run: the 128 KiB pmsg ring
 * otherwise loses them under the thumbnails (run53). */
static char sm_rep[12288]; static size_t sm_rep_len;
static const char *const sm_rep_keys[] = { " fd", "  t", "  fb ", "quarantined", "fails:", "buffer texture", "stub ", "skipped",
	"GPU off", "SIGNAL", "EXCEPTION", "unimplemented", "NOT in pack", "(missing)", "failed", "compute", "present", "in AegirPoster",
	"poster draw", "draw type", "nomatch", "fpass", "  rt", "near ", "lazy bytes", "late ", "hang bisect", "iosurface", "pass ", "layer ", "getBytes", "astc ", "blit ", "perf ", "step ", "fault replay", "collision", "astc bad", "clock set", "holds a ", "texture view", "poster tex", "astc stats", "blit buffer", "blit tex", "tstat", "upload ", "bisect2", "pass desc", "refused device", "empty opaque", "empty upload", "ebt ", "shadow writeback", "SB ", "heap ", "proto ", "texmem ", "sharer", "bootdiag", "tolerated", "sampler wrap" };
static void slog(const char *fmt, ...)
{
	char b[150];
	va_list ap; va_start(ap, fmt); vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
	fprintf(stderr, "%s\n", b);
	for (size_t i = 0; i < sizeof sm_rep_keys / sizeof *sm_rep_keys; i++) {
		if (!strstr(b, sm_rep_keys[i])) continue;
		size_t n = strlen(b);
		if (sm_rep_len + n + 2 < sizeof sm_rep) { memcpy(sm_rep + sm_rep_len, b, n); sm_rep_len += n; sm_rep[sm_rep_len++] = '\n'; sm_rep[sm_rep_len] = 0; }
		/* and into the kernel's keep buffer (all processes), replayed right before a recovery reboot */
		if (sm_conn) {
			static int nk; char kb[176];
			if (nk++ < 300) {
				const char *pn = getprogname();
				int L = snprintf(kb, sizeof kb, "K %.5s %s", pn ? pn : "?", strncmp(b, "SweetMTL: ", 10) ? b : b + 10);
				IOConnectCallMethod(sm_conn, 9, NULL, 0, kb, (size_t)(L < (int)sizeof kb ? L : (int)sizeof kb - 1), NULL, NULL, NULL, NULL);
			}
		}
		break;
	}
	if (!sm_conn) {
		io_service_t s = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("SweetMali"));
		if (s) IOServiceOpen(s, mach_task_self(), 0, &sm_conn);
	}
	if (sm_conn) IOConnectCallMethod(sm_conn, 5, NULL, 0, b, strlen(b), NULL, NULL, NULL, NULL);
}


/* ------------------------------------------------------------------ GPU core
 * Thin layer over the SweetMali user client: buffer objects mapped into this process and
 * into the GPU address space, and Mali job descriptors packed with Mesa's genxml (arch 9).
 */
extern kern_return_t IOConnectMapMemory64(io_connect_t, uint32_t, task_port_t, mach_vm_address_t *,
    mach_vm_size_t *, uint32_t);

#define PAN_ARCH 9
#include "genxml/gen_macros.h"

typedef struct { uint64_t handle, gpu; uint8_t *cpu; uint64_t size; uint32_t imported; uint64_t vbase, vsize; } sm_bo;
/* BGRA8 and the 32-bit BGR10 XR display formats CoreAnimation renders into: everything is stored as 8-bit BGRA here,
 * consistently for rendering, sampling and the kernel's copy to the panel */
static inline bool sm_is_bgra(NSUInteger f) { return f == 80 || f == 81 || (f >= 550 && f <= 555); }
static volatile uint32_t sm_commits;
/* performance window counters (reset by the watchdog at each test step): commit wall time, GPU submit time
 * (includes the kernel's cache flushes and the busy wait), commit-to-commit gaps */
#include <mach/mach_time.h>
static volatile uint64_t sm_pf_ns, sm_pf_gpu_ns, sm_pf_max_ns, sm_pf_last, sm_pf_win;
static volatile uint32_t sm_pf_n, sm_pf_jobs, sm_pf_draws, sm_pf_gap[4];
static uint64_t sm_ns(void)
{
	static mach_timebase_info_data_t tb;
	if (!tb.denom) mach_timebase_info(&tb);
	return mach_absolute_time() * tb.numer / tb.denom;
}
/* Cache maintenance list for the next job(s): the kernel (selector 11) flushes only the BOs holding these GPU
 * addresses (plus every BO of <= 16 pages) instead of all ~120 MB of BOs twice per job (selector 3).
 * sm_jl_begin() at the start of each job builder, sm_jl_add() for what the job reads, sm_jl_begin(target) marks
 * the written target; long-lived infrastructure BOs (descriptors, ring, heap, dummies) are always listed. */
static uint64_t sm_infra[16], sm_always[4]; static uint32_t sm_ninfra, sm_nalways;
/* after the first job of a builder only the descriptor BOs (rewritten per draw) and the written target are listed:
 * between the per-draw vertex jobs of a pass the CPU writes nothing else (ring/shadow writes happen at encode time) */
static bool sm_jlight;
static uint64_t sm_jr[480], sm_jw[24], sm_jrl[480], sm_jwl[24]; static uint32_t sm_njr, sm_njw; static bool sm_jover;
static uint64_t sm_infra_len[16];     /* bytes to flush from the BO start (0 = the whole BO) */
static uint64_t sm_desc_va, sm_desc_span = 0;   /* the pass descriptor BO: only the part the current pass wrote */
static volatile uint64_t sm_pf_pre_ns, sm_pf_job_ns, sm_pf_post_ns, sm_pf_lock_ns;
static void sm_ring_take(uint64_t *va, uint64_t *len);
static int sm_listmode = -1;   /* -1 unknown, 0 off (boot-arg sweetflushall or old kernel), 1 on */
static void sm_infra_add(const sm_bo *b) { if (b && b->gpu && sm_ninfra < 16) sm_infra[sm_ninfra++] = b->gpu; }
static void sm_always_add(const sm_bo *b) { sm_infra_add(b); if (b && b->gpu && sm_nalways < 4) sm_always[sm_nalways++] = b->gpu; }
/* len 0: from va to the end of its BO (buffers: the bound length is not known here) */
static void sm_jl_addl(uint64_t va, uint64_t len)
{
	if (!va) return;
	for (uint32_t i = 0; i < sm_njr; i++) if (sm_jr[i] == va) { if (!len || (sm_jrl[i] && len > sm_jrl[i])) sm_jrl[i] = len; return; }
	if (sm_njr < sizeof sm_jr / sizeof *sm_jr) { sm_jrl[sm_njr] = len; sm_jr[sm_njr++] = va; } else sm_jover = true;
}
static void sm_jl_writel(uint64_t va, uint64_t len)
{
	if (!va) return;
	for (uint32_t i = 0; i < sm_njw; i++) if (sm_jw[i] == va) { if (!len || (sm_jwl[i] && len > sm_jwl[i])) sm_jwl[i] = len; return; }
	if (sm_njw < sizeof sm_jw / sizeof *sm_jw) { sm_jwl[sm_njw] = len; sm_jw[sm_njw++] = va; } else sm_jover = true;
}
static void sm_jl_add(uint64_t va) { sm_jl_addl(va, 0); }
static void sm_jl_write(uint64_t va) { sm_jl_writel(va, 0); }
/* targets only the GPU touches (IOSurface render targets: displayed by the GPU compositor, never written or read by a
 * CPU except our own debug captures, which flush first): no cache maintenance, ~22 MB per screen pass saved */
static bool sm_target_noflush;
static void sm_jl_beginl(uint64_t target, uint64_t len) { sm_njr = sm_njw = 0; sm_jover = false; sm_jlight = false; if (!sm_target_noflush) sm_jl_writel(target, len); }
/* clean+invalidate a GPU range now (kernel selector 13), before a CPU read of GPU-only memory */
static void sm_flush_now(uint64_t va, uint64_t len)
{
	if (!va || !len) return;
	uint64_t R[2] = { va, (len & 0xFFFFFFFFFFULL) | (3ULL << 62) };
	IOConnectCallMethod(sm_conn, 13, NULL, 0, R, 16, NULL, NULL, NULL, NULL);
}
static void sm_jl_begin(uint64_t target) { sm_jl_beginl(target, 0); }
static int sm_wc = -1;
static uint64_t sm_next_va = 0x30000000ULL;
static uint64_t sm_va_take(uint64_t size);
static uint64_t sm_live_bytes; static uint32_t sm_live_n;

static bool sm_bo_alloc(sm_bo *bo, uint64_t size)
{
	if (!sm_conn) slog("SweetMTL: gpu connect");
	if (!sm_conn) return false;
	size = (size + 0xFFFF) & ~0xFFFFULL;
	uint64_t in[2] = { size }, out[2] = { 0 }; uint32_t oc = 2;
	if (IOConnectCallMethod(sm_conn, 1, in, 1, NULL, 0, out, &oc, NULL, NULL)) return false;
	mach_vm_address_t ua = 0; mach_vm_size_t us = 0;
	/* own BOs are mapped write-combined (as Mesa does on non-coherent Mali): CPU writes reach memory without cache
	 * maintenance, so the kernel skips flushing them (selector 12 flag 2); boot-arg sweetnowc keeps them cached */
	if (sm_wc < 0) { char ba[1024] = {0}; size_t bl = sizeof(ba) - 1; sm_wc = sysctlbyname("kern.bootargs", ba, &bl, NULL, 0) == 0 && strstr(ba, "sweetwc=1") ? 1 : 0; }   /* opt-in: WC mapping panicked in pmap (phystokv_range illegal PA, run111) */
	if (IOConnectMapMemory64(sm_conn, (uint32_t)out[0], mach_task_self(), &ua, &us, sm_wc ? (1 | 0x400) : 1)) return false;   /* kIOMapAnywhere | kIOMapWriteCombineCache */
	uint64_t vs = size + 0x10000, va = sm_va_take(vs);
	in[0] = out[0]; in[1] = va; oc = 0;
	if (IOConnectCallMethod(sm_conn, 2, in, 2, NULL, 0, NULL, &oc, NULL, NULL)) return false;
	bo->handle = out[0]; bo->gpu = va; bo->cpu = (uint8_t *)ua; bo->size = size;
	bo->vbase = va; bo->vsize = vs; sm_live_bytes += vs; sm_live_n++;
	return true;
}

extern kern_return_t IOConnectUnmapMemory64(io_connect_t, uint32_t, task_port_t, mach_vm_address_t);
/* live GPU memory (for the alive line) and recycled GPU VA ranges: the kernel never frees page-table pages,
 * so an ever-growing VA cursor slowly exhausts its 1 MiB table pool */
static struct { uint64_t va, size; } sm_vfree[4096]; static uint32_t sm_vfree_n;
static pthread_mutex_t sm_va_mx = PTHREAD_MUTEX_INITIALIZER;
/* sorted, coalescing free list of GPU VA ranges, best fit: the old unsorted 512-entry list fragmented, dropped ranges
 * when full and pushed the cursor up until the kernel's page-table pool ran dry (bo alloc failures, run155/156) */
static uint64_t sm_va_take(uint64_t size)
{
	pthread_mutex_lock(&sm_va_mx);
	int best = -1;
	for (uint32_t i = 0; i < sm_vfree_n; i++)
		if (sm_vfree[i].size >= size && (best < 0 || sm_vfree[i].size < sm_vfree[best].size)) { best = (int)i; if (sm_vfree[i].size == size) break; }
	uint64_t va;
	if (best >= 0) {
		va = sm_vfree[best].va; sm_vfree[best].va += size; sm_vfree[best].size -= size;
		if (!sm_vfree[best].size) { memmove(&sm_vfree[best], &sm_vfree[best + 1], (sm_vfree_n - best - 1) * sizeof sm_vfree[0]); sm_vfree_n--; }
	} else { va = sm_next_va; sm_next_va += size; }
	pthread_mutex_unlock(&sm_va_mx);
	return va;
}
static void sm_va_give(uint64_t va, uint64_t size)
{
	pthread_mutex_lock(&sm_va_mx);
	uint32_t i = 0; while (i < sm_vfree_n && sm_vfree[i].va < va) i++;
	bool prev = i > 0 && sm_vfree[i - 1].va + sm_vfree[i - 1].size == va, next = i < sm_vfree_n && va + size == sm_vfree[i].va;
	if (prev && next) { sm_vfree[i - 1].size += size + sm_vfree[i].size; memmove(&sm_vfree[i], &sm_vfree[i + 1], (sm_vfree_n - i - 1) * sizeof sm_vfree[0]); sm_vfree_n--; }
	else if (prev) sm_vfree[i - 1].size += size;
	else if (next) { sm_vfree[i].va = va; sm_vfree[i].size += size; }
	else if (sm_vfree_n < sizeof sm_vfree / sizeof sm_vfree[0]) { memmove(&sm_vfree[i + 1], &sm_vfree[i], (sm_vfree_n - i) * sizeof sm_vfree[0]); sm_vfree[i].va = va; sm_vfree[i].size = size; sm_vfree_n++; }
	/* the top range touching the cursor goes back to the cursor */
	if (sm_vfree_n && sm_vfree[sm_vfree_n - 1].va + sm_vfree[sm_vfree_n - 1].size == sm_next_va) { sm_next_va = sm_vfree[sm_vfree_n - 1].va; sm_vfree_n--; }
	pthread_mutex_unlock(&sm_va_mx);
}
void sm_va_give_ext(uint64_t va, uint64_t size) { sm_va_give(va, size); }
static void sm_bo_free(sm_bo *bo)
{
	if (!sm_conn || !bo->handle) return;
	if (!bo->imported && bo->cpu) IOConnectUnmapMemory64(sm_conn, (uint32_t)bo->handle, mach_task_self(), (mach_vm_address_t)bo->cpu);
	uint64_t in[1] = { bo->handle }; uint32_t oc = 0;
	IOConnectCallMethod(sm_conn, 4, in, 1, NULL, 0, NULL, &oc, NULL, NULL);
	/* the VA goes back only after the kernel unmapped it: given back first, another thread could map a new BO there
	 * and then have its pages unmapped by this destroy (GPU translation faults, run157/158) */
	if (bo->vsize) { sm_va_give(bo->vbase, bo->vsize); sm_live_bytes -= bo->vsize; sm_live_n--; }
	memset(bo, 0, sizeof *bo);
}
/* Wire a range of this process's memory (an IOSurface) and map it into the GPU address space. */
static bool sm_bo_import(sm_bo *bo, void *uva, uint64_t len)
{
	if (!sm_conn) return false;
	uint64_t a0 = (uint64_t)uva & ~0x3FFFULL, a1 = ((uint64_t)uva + len + 0x3FFF) & ~0x3FFFULL;
	uint64_t vs = (a1 - a0) + 0x10000, va = sm_va_take(vs);
	uint64_t in[3] = { a0, a1 - a0, va }, out[1] = { 0 }; uint32_t oc = 1;
	kern_return_t kr = IOConnectCallMethod(sm_conn, 8, in, 3, NULL, 0, out, &oc, NULL, NULL);
	if (kr) {
		extern void sm_va_give_ext(uint64_t, uint64_t);
		sm_va_give_ext(va, vs);
		static int nl; if (nl++ < 6) slog("SweetMTL: import %llx+%llx failed %x (live %lluMB in %u)", a0, a1 - a0, kr, sm_live_bytes >> 20, sm_live_n);
		return false;
	}
	bo->handle = out[0]; bo->gpu = va + ((uint64_t)uva - a0); bo->cpu = uva; bo->size = len; bo->imported = 1;
	bo->vbase = va; bo->vsize = vs; sm_live_bytes += vs; sm_live_n++;
	return true;
}
/* transient bytes (setVertexBytes & co): one ring, reused every pass */
static bool sm_is_poster(const char *pn);
static size_t sm_avail(void)   /* os_proc_available_memory, looked up at run time (iOS only) */
{
	static size_t (*f)(void); static bool tried;
	if (!tried) { tried = true; f = (size_t (*)(void))dlsym(RTLD_DEFAULT, "os_proc_available_memory"); }
	return f ? f() : 0;
}
static uint64_t sm_ring_put_locked(sm_bo *ringp, bool *havep, uint64_t *offp, const void *p, uint64_t len, uint8_t **cpu_out);
#include <pthread.h>
static pthread_mutex_t sm_ring_mx = PTHREAD_MUTEX_INITIALIZER;
static sm_bo sm_ring_bo; static uint64_t sm_ring_lo = ~0ULL, sm_ring_hi;   /* CPU-written part since the last flush */
static void sm_ring_take(uint64_t *va, uint64_t *len)
{
	pthread_mutex_lock(&sm_ring_mx);
	if (sm_ring_hi > sm_ring_lo && sm_ring_bo.gpu) { *va = sm_ring_bo.gpu + sm_ring_lo; *len = sm_ring_hi - sm_ring_lo; } else { *va = 0; *len = 0; }
	sm_ring_lo = ~0ULL; sm_ring_hi = 0;
	pthread_mutex_unlock(&sm_ring_mx);
}
static uint64_t sm_ring_put(const void *p, uint64_t len, uint8_t **cpu_out)
{
#define ring sm_ring_bo
	static bool have; static uint64_t off;
	pthread_mutex_lock(&sm_ring_mx);
	uint64_t va = sm_ring_put_locked(&ring, &have, &off, p, len, cpu_out);
	if (va) { uint64_t o = va - ring.gpu; if (o < sm_ring_lo) sm_ring_lo = o; if (o + len > sm_ring_hi) sm_ring_hi = o + len; }
	pthread_mutex_unlock(&sm_ring_mx);
	return va;
#undef ring
}
static uint64_t sm_ring_put_locked(sm_bo *ringp, bool *havep, uint64_t *offp, const void *p, uint64_t len, uint8_t **cpu_out)
{
#define ring (*ringp)
#define have (*havep)
#define off (*offp)
	if (!have) { have = sm_bo_alloc(&ring, sm_is_poster(getprogname()) ? (1u << 20) : (8u << 20)); }   /* extensions have a small memory limit */
	if (!have || len > ring.size) return 0;
	off = (off + 255) & ~255ULL;
	if (off + len > ring.size) off = 0;
	if (p) memcpy(ring.cpu + off, p, len);
	if (cpu_out) *cpu_out = ring.cpu + off;
	uint64_t va = ring.gpu + off; off += len;
	return va;
#undef ring
#undef have
#undef off
}

/* Frame capture for headless debugging: the first passes are written, downscaled 3x, into a preallocated file of the
 * HFS+ rootfs (/private/var/sweetfr.bin, 8 slots of 2 MiB) that the Mac reads back from TWRP. */
#include <fcntl.h>
static void sm_capture(const uint8_t *c, uint32_t W, uint32_t H, uint32_t bpr, uint32_t fmt, uint32_t passno)
{
	static int slot;
	if (slot >= 8 || !c) return;
	int fd = open("/private/var/sweetfr.bin", O_WRONLY);
	if (fd < 0) { static int nl; if (nl++ < 2) slog("SweetMTL: capture open failed errno %d", errno); return; }
	uint32_t w = W / 3, h = H / 3;
	if ((uint64_t)w * h * 4 + 64 > (2u << 20)) { close(fd); return; }
	uint8_t *buf = calloc(1, 64 + (size_t)w * h * 4);
	memcpy(buf, "SWFRAME1", 8);
	uint32_t hd[6] = { w, h, w * 4, fmt, passno, W };
	memcpy(buf + 8, hd, sizeof hd);
	for (uint32_t y = 0; y < h; y++)
		for (uint32_t x = 0; x < w; x++) memcpy(buf + 64 + ((size_t)y * w + x) * 4, c + (size_t)(y * 3) * bpr + (size_t)x * 3 * 4, 4);
	ssize_t r = pwrite(fd, buf, 64 + (size_t)w * h * 4, (off_t)slot * (2u << 20));
	fsync(fd); close(fd); free(buf);
	slog("SweetMTL: captured pass %u into slot %d (%zd bytes)", passno, slot, r);
	slot++;
}

/* Thumbnail through the log (the rootfs is a RAM overlay, so files do not survive): 1/12 scale, RGB332,
 * base64 in 112-char lines "THn <seq> <data>"; the Mac rebuilds a PNG from the pstore log. */
static struct { uint8_t *px; uint32_t n, w, h, id; } sm_thdef[4]; static int sm_nthdef;
static void sm_thumb_emit(const uint8_t *px, uint32_t n, uint32_t w, uint32_t h, uint32_t id, bool hi);
/* id | 0x100: compute now, print later with sm_thumb_flush() (early shots were pushed out of the pmsg ring, run112) */
static void sm_thumb(const uint8_t *c, uint32_t W, uint32_t H, uint32_t bpr, uint32_t id)
{
	if (!c) return;
	bool defer = (id & 0x100) != 0; id &= 0xFF;
	const uint32_t S = (id >= 16 && id <= 19) ? 18 : 12, w = W / S, h = H / S;   /* 18/19: small progress shots */
	bool hi = id >= 20;                       /* ids >= 20: RGB565 (2 bytes/pixel, no colour banding) */
	uint32_t n = w * h * (hi ? 2 : 1); uint8_t *px = malloc(n);
	for (uint32_t y = 0; y < h; y++)
		for (uint32_t x = 0; x < w; x++) {
			uint32_t r = 0, g = 0, b = 0;
			for (uint32_t k = 0; k < 4; k++) {   /* average 4 samples in the cell */
				const uint8_t *q = c + (size_t)(y * S + (k >> 1) * 6) * bpr + (size_t)(x * S + (k & 1) * 6) * 4;
				b += q[0]; g += q[1]; r += q[2];
			}
			r >>= 2; g >>= 2; b >>= 2;
			if (hi) {
				uint16_t v = (uint16_t)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
				px[2 * (y * w + x)] = (uint8_t)v; px[2 * (y * w + x) + 1] = (uint8_t)(v >> 8);
			} else px[y * w + x] = (uint8_t)((r & 0xE0) | ((g & 0xE0) >> 3) | (b >> 6));
		}
	if (defer && sm_nthdef < 4) { sm_thdef[sm_nthdef].px = px; sm_thdef[sm_nthdef].n = n; sm_thdef[sm_nthdef].w = w; sm_thdef[sm_nthdef].h = h; sm_thdef[sm_nthdef++].id = id; return; }
	sm_thumb_emit(px, n, w, h, id, hi);
	free(px);
}
static void sm_thumb_flush(void)
{
	for (int i = 0; i < sm_nthdef; i++) { sm_thumb_emit(sm_thdef[i].px, sm_thdef[i].n, sm_thdef[i].w, sm_thdef[i].h, sm_thdef[i].id, sm_thdef[i].id >= 20); free(sm_thdef[i].px); }
	sm_nthdef = 0;
}
static void sm_thumb_emit(const uint8_t *px, uint32_t n, uint32_t w, uint32_t h, uint32_t id, bool hi)
{
	slog("SweetMTL: THUMB %u %ux%u %s %u bytes", id, w, h, hi ? "rgb565" : "rgb332", n);
	static const char *B = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	char line[140]; uint32_t seq = 0;
	for (uint32_t o = 0; o < n; o += 84, seq++) {
		int L = snprintf(line, sizeof line, "TH%u %u ", id, seq);
		for (uint32_t i = o; i < o + 84 && i < n; i += 3) {
			uint32_t v = (uint32_t)px[i] << 16 | (i + 1 < n ? (uint32_t)px[i + 1] << 8 : 0) | (i + 2 < n ? px[i + 2] : 0);
			line[L++] = B[(v >> 18) & 63]; line[L++] = B[(v >> 12) & 63]; line[L++] = B[(v >> 6) & 63]; line[L++] = B[v & 63];
		}
		line[L] = 0;
		slog("%s", line);
	}
}

static bool sm_gpu_off;   /* a job timed out (or the kernel fenced the GPU): no more GPU work this boot */
static char sm_off_reason[160];   /* why, repeated in every "alive" line so a wrapped pmsg log still shows it */
static char sm_cur_pass[96];      /* what was being drawn */
static char sm_fail_log[240];     /* first GPU failures, also repeated in the alive lines */
static id sm_last_target;         /* last full-screen render target (thumbnails are timed, an idle lock screen draws nothing) */
static bool sm_is_poster(const char *pn);
/* paired submit: the pass's fragment job rides along with its vertex chain in one kernel call (kernel runs it on slot 0
 * after a clean vertex chain). sm_pair_ok: -1 unknown, 0 old kernel / sweetnopair, 1 on. */
static uint64_t sm_pair_frag;
static uint32_t sm_pair_status;
static bool sm_pair_done;
static int sm_pair_ok = -1;
static uint32_t sm_check(uint32_t r, uint32_t slot);
static uint32_t sm_submit(uint32_t slot, uint64_t jc)
{
	if (sm_gpu_off) return 0xFFFCu;
	uint64_t in[4] = { slot, jc, 4000, 0 }, out[1] = { 0xdead }; uint32_t oc = 1;
	if (sm_listmode < 0) {
		char ba[1024] = {0}; size_t bl = sizeof(ba) - 1;
		sm_listmode = sysctlbyname("kern.bootargs", ba, &bl, NULL, 0) == 0 && strstr(ba, "sweetflushall") ? 0 : 1;
	}
	uint64_t t0 = sm_ns();
	kern_return_t kr = 1;
	static int rangemode = -1;   /* kernel selector 12: byte ranges + pre/post flags + timings */
	if (rangemode < 0) { char ba[1024] = {0}; size_t bl = sizeof(ba) - 1; rangemode = sysctlbyname("kern.bootargs", ba, &bl, NULL, 0) == 0 && strstr(ba, "sweetnorange") ? 0 : 1; }
	if (sm_listmode == 1 && rangemode == 1 && !sm_jover) {
		const uint64_t PRE = 1ULL << 62, POST = 1ULL << 63;
		static uint64_t R[512]; uint32_t n = 0;
#define ADD(va_, len_, f_) do { if ((va_) && n < 254) { R[2 * n] = (va_); R[2 * n + 1] = ((len_) & 0xFFFFFFFFFFULL) | (f_); n++; } } while (0)
		if (!sm_jlight) {
			for (uint32_t i = 0; i < sm_ninfra; i++) if (sm_infra[i] != sm_desc_va) ADD(sm_infra[i], sm_infra_len[i], PRE);
			uint64_t rv, rl; sm_ring_take(&rv, &rl); ADD(rv, rl, PRE);
			for (uint32_t i = 0; i < sm_njr; i++) ADD(sm_jr[i], sm_jrl[i], PRE);
		}
		for (uint32_t i = 0; i < sm_nalways; i++)
			/* descriptors: flushed before the job only (the CPU never reads what the GPU writes there and rewrites whole
			 * slots after a clean+invalidate); later jobs of a pass only changed the pass header */
			/* descriptors: boot-arg sweetdescpre=1 flushes them before jobs only (the CPU never reads what the GPU writes
			 * there); run153's broken visuals turned out to be the page-table pool exhaustion, so this is re-tested */
			{ static int dp = -1; if (dp < 0) { char ba[1024] = {0}; size_t bl = sizeof(ba) - 1; dp = sysctlbyname("kern.bootargs", ba, &bl, NULL, 0) == 0 && strstr(ba, "sweetdescpre=0") ? 0 : 1; }   /* on: run161 clean */
			  ADD(sm_always[i], sm_always[i] == sm_desc_va ? (dp && sm_jlight && slot == 0 ? 0x10000 : sm_desc_span) : 0, dp ? PRE : PRE | POST); }
		for (uint32_t i = 0; i < sm_njw; i++) ADD(sm_jw[i], sm_jwl[i], slot == 1 && !sm_pair_frag ? PRE : PRE | POST);
#undef ADD
		uint64_t in4[5] = { slot, jc, 4000, sm_wc == 1 ? 2 : 0, sm_pair_frag }, o4[6] = { 0xdead, 0, 0, 0, 0, 0xFFFFFFFF }; uint32_t oc4 = 6;
		kr = IOConnectCallMethod(sm_conn, 12, in4, sm_pair_frag ? 5 : 4, R, n * 16, o4, &oc4, NULL, NULL);
		if (!kr && sm_pair_frag) {
			/* an old kernel ignores input 4 and returns at most 5 outputs: the fragment job did not run */
			if (oc4 > 5 && o4[5] != 0xFFFFFFFFULL) { sm_pair_done = o4[5] != 0xFFFE; sm_pair_status = (uint32_t)o4[5]; if (sm_pair_ok < 0) { sm_pair_ok = 1; slog("SweetMTL: paired vertex+fragment submits on"); } }
			else { sm_pair_ok = 0; slog("SweetMTL: kernel has no paired submit"); }
		}
		if (kr == (kern_return_t)0xe00002c7) { slog("SweetMTL: range flush unsupported: per-BO lists"); rangemode = 0; kr = 1; }
		else {
			out[0] = o4[0];
			if (!kr) { sm_jlight = true; sm_pf_pre_ns += o4[1]; sm_pf_job_ns += o4[2]; sm_pf_post_ns += o4[3]; if (oc4 > 4) sm_pf_lock_ns += o4[4]; }
			static int nl; if (!kr && nl++ < 3) slog("SweetMTL: range flush job: %u ranges, pre %llu us job %llu us post %llu us", n, o4[1] / 1000, o4[2] / 1000, o4[3] / 1000);
		}
	}
	if (kr == 1 && sm_listmode == 1 && !sm_jover) {
		/* read part (flushed before the job), then the written part (flushed before and after): the descriptor BOs
		 * are always in the written part, the GPU writes job headers and DRAW words there (run101: without the
		 * clean+invalidate after the job, stale CPU lines corrupted descriptors -> faults 0x59 and a timeout) */
		uint64_t L[512]; uint32_t n = 0;
		if (!sm_jlight) {
			for (uint32_t i = 0; i < sm_ninfra; i++) L[n++] = sm_infra[i];
			for (uint32_t i = 0; i < sm_njr && n < 500; i++) L[n++] = sm_jr[i];
		}
		in[3] = n;
		for (uint32_t i = 0; i < sm_nalways; i++) L[n++] = sm_always[i];
		if (slot != 1) for (uint32_t i = 0; i < sm_njw && n < 512; i++) L[n++] = sm_jw[i];   /* vertex jobs do not write the target */
		else for (uint32_t i = 0; i < sm_njw && n < 512; i++) { L[n] = L[in[3]]; L[in[3]++] = sm_jw[i]; n++; }   /* ... but read it: flush before */
		kr = IOConnectCallMethod(sm_conn, 11, in, 4, L, n * 8, out, &oc, NULL, NULL);
		if (!kr) sm_jlight = true;
		if (kr == (kern_return_t)0xe00002c7 || kr == (kern_return_t)0xe00002c2) {   /* unsupported (old kernel) / bad argument */
			slog("SweetMTL: flush list unsupported (kr %x): flushing everything", kr);
			sm_listmode = 0; kr = 1;
		}
		static int nl; if (!kr && nl++ < 3) slog("SweetMTL: flush list job: %u addresses (%u written)", n, sm_njw);
	}
	if (kr == 1) { oc = 1; kr = IOConnectCallMethod(sm_conn, 3, in, 3, NULL, 0, out, &oc, NULL, NULL); }
	sm_pf_gpu_ns += sm_ns() - t0; sm_pf_jobs++;
	if (sm_pair_done) sm_pf_jobs++;
	uint32_t r = kr ? 0xffff0000u | (uint32_t)kr : (uint32_t)out[0];
	return sm_check(r, slot);
}
static uint32_t sm_check(uint32_t r, uint32_t slot)
{
	static int nfail;
	if (r && nfail < 3) {
		nfail++;
		size_t L = strlen(sm_fail_log);
		snprintf(sm_fail_log + L, sizeof sm_fail_log - L, "%x/s%u@%.36s; ", r, slot, sm_cur_pass);
	}
	/* a timeout (0xFFFF) is recovered by the kernel (GPU reset): tolerate two per process before giving up; the faulting
	 * pass's texturing shaders get quarantined by the caller. 0xFFFC = kernel fenced the GPU: off for good */
	static int ntimeouts;
	bool fatal = r == 0xFFFCu || (r >> 16) == 0xffff || (r && (sm_is_poster(getprogname()) || !strcmp(getprogname(), "PosterBoard")));
	if (r == 0xFFFFu && ++ntimeouts > 2) fatal = true;
	if (r == 0xFFFFu && !fatal) slog("SweetMTL: GPU timeout %d tolerated in %s", ntimeouts, sm_cur_pass);
	if (fatal) {   /* guests: first fault ends their GPU use */
		sm_gpu_off = true;
		snprintf(sm_off_reason, sizeof sm_off_reason, "status %x slot %u in %s", r, slot, sm_cur_pass);
		slog("SweetMTL: GPU off: %s", sm_off_reason);
	}
	return r;
}

/* Clear a w x h RGBA8/BGRA8 colour target with one FRAGMENT job (no tiler). Returns the job status. */
static uint32_t sm_clear(sm_bo *desc, uint64_t target_va, uint32_t w, uint32_t h, uint32_t stride, uint32_t packed, bool bgra)
{
	sm_jl_begin(target_va);
	uint8_t *cpu = desc->cpu;
	memset(cpu, 0, 0x400);
	void *fbd = cpu + 0x40;
	pan_section_pack(fbd, FRAMEBUFFER, PARAMETERS, cfg) {
		cfg.pre_frame_0 = MALI_PRE_POST_FRAME_SHADER_MODE_NEVER;
		cfg.pre_frame_1 = MALI_PRE_POST_FRAME_SHADER_MODE_NEVER;
		cfg.post_frame = MALI_PRE_POST_FRAME_SHADER_MODE_NEVER;
		cfg.width = w; cfg.height = h;
		cfg.bound_max_x = w - 1; cfg.bound_max_y = h - 1;
		cfg.effective_tile_size = 256;
		cfg.tie_break_rule = MALI_TIE_BREAK_RULE_MINUS_180_IN_0_OUT;
		cfg.render_target_count = 1;
		cfg.z_internal_format = MALI_Z_INTERNAL_FORMAT_D24;
		cfg.color_buffer_allocation = 1024;
		cfg.sample_count = 1;
		cfg.sample_pattern = MALI_SAMPLE_PATTERN_SINGLE_SAMPLED;
	}
	pan_section_pack(fbd, FRAMEBUFFER, PADDING, padding) {}
	pan_pack((uint8_t *)fbd + pan_size(FRAMEBUFFER), RENDER_TARGET, rt) {
		rt.clean_pixel_write_enable = true;
		rt.clear.color_0 = rt.clear.color_1 = rt.clear.color_2 = rt.clear.color_3 = packed;
		rt.write_enable = true;
		rt.dithering_enable = true;
		rt.internal_format = MALI_COLOR_BUFFER_INTERNAL_FORMAT_R8G8B8A8;
		rt.writeback_format = MALI_COLOR_FORMAT_R8G8B8A8;
		rt.writeback_block_format = MALI_BLOCK_FORMAT_LINEAR;
		rt.writeback_msaa = MALI_MSAA_SINGLE;
		rt.swizzle = bgra ? (2 | (1 << 3) | (0 << 6) | (3 << 9)) : (0 | (1 << 3) | (2 << 6) | (3 << 9));
		rt.rgb.base = target_va;
		rt.rgb.row_stride = stride;
	}
	pan_section_pack(cpu, FRAGMENT_JOB, PAYLOAD, cfg) {
		cfg.bound_min_x = 0; cfg.bound_min_y = 0;
		cfg.bound_max_x = (w - 1) >> 4; cfg.bound_max_y = (h - 1) >> 4;
		cfg.tile_render_order = MALI_TILE_RENDER_ORDER_Z_ORDER;
		cfg.framebuffer = desc->gpu + 0x40;
	}
	pan_section_pack(cpu, FRAGMENT_JOB, HEADER, header) {
		header.type = MALI_JOB_TYPE_FRAGMENT;
		header.index = 1;
	}
	return sm_submit(0, desc->gpu);
}

#define OFF_FJOB 0x000
#define OFF_FBD  0x040
#define OFF_VJOB 0x100
#define OFF_THEAP 0x300
#define OFF_TCTX 0x400
#define OFF_DS   0x500
#define OFF_BLEND 0x540
#define OFF_SPOS 0x580
#define OFF_SFRAG 0x5C0
#define OFF_TLS  0x600
#define OFF_FAU  0x700
#define OFF_FAU2 0x780
#define OFF_BPOS 0x800
#define OFF_BFRAG 0x900
#define OFF_SAMP 0xC00
#include "../userland/malitri_gen.h"

/* Clear + one non-indexed triangle list with the fixed Mesa-compiled shaders (VS_TRI / FS_GREEN):
 * MALLOC_VERTEX (IDVS + tiler) job on slot 1, then the FRAGMENT job on slot 0. */
static uint32_t sm_draw(sm_bo *desc, sm_bo *heap, uint64_t target_va, uint32_t w, uint32_t h, uint32_t stride,
    uint32_t packed, bool bgra, uint32_t vcount, uint32_t *vstatus)
{
	sm_jl_begin(target_va);
	uint8_t *cpu = desc->cpu;
	uint64_t D = desc->gpu;
	memset(cpu, 0, 0x1000);
	memset(heap->cpu, 0, heap->size);
	memcpy(cpu + OFF_BPOS, VS_TRI, sizeof VS_TRI);
	memcpy(cpu + OFF_BFRAG, FS_GREEN, sizeof FS_GREEN);

	pan_pack(cpu + OFF_THEAP, TILER_HEAP, heap_d) {
		heap_d.size = heap->size;
		heap_d.base = heap->gpu;
		heap_d.bottom = heap->gpu;
		heap_d.top = heap->gpu + heap->size;
	}
	pan_pack(cpu + OFF_TCTX, TILER_CONTEXT, t) {
		t.hierarchy_mask = 0x28;
		t.fb_width = w;
		t.fb_height = h;
		t.heap = D + OFF_THEAP;
		t.sample_pattern = MALI_SAMPLE_PATTERN_SINGLE_SAMPLED;
		t.first_provoking_vertex = true;
	}
	void *fbd = cpu + OFF_FBD;
	pan_section_pack(fbd, FRAMEBUFFER, PARAMETERS, cfg) {
		cfg.pre_frame_0 = MALI_PRE_POST_FRAME_SHADER_MODE_NEVER;
		cfg.pre_frame_1 = MALI_PRE_POST_FRAME_SHADER_MODE_NEVER;
		cfg.post_frame = MALI_PRE_POST_FRAME_SHADER_MODE_NEVER;
		cfg.width = w; cfg.height = h;
		cfg.bound_max_x = w - 1; cfg.bound_max_y = h - 1;
		cfg.effective_tile_size = 256;
		cfg.tie_break_rule = MALI_TIE_BREAK_RULE_MINUS_180_IN_0_OUT;
		cfg.render_target_count = 1;
		cfg.z_internal_format = MALI_Z_INTERNAL_FORMAT_D24;
		cfg.color_buffer_allocation = 1024;
		cfg.sample_count = 1;
		cfg.sample_pattern = MALI_SAMPLE_PATTERN_SINGLE_SAMPLED;
		cfg.tiler = D + OFF_TCTX;
		cfg.sample_locations = D + OFF_SAMP;
		cfg.first_provoking_vertex = true;
	}
	pan_section_pack(fbd, FRAMEBUFFER, PADDING, padding) {}
	pan_pack((uint8_t *)fbd + pan_size(FRAMEBUFFER), RENDER_TARGET, rt) {
		rt.clean_pixel_write_enable = true;
		rt.clear.color_0 = rt.clear.color_1 = rt.clear.color_2 = rt.clear.color_3 = packed;
		rt.write_enable = true;
		rt.dithering_enable = true;
		rt.internal_format = MALI_COLOR_BUFFER_INTERNAL_FORMAT_R8G8B8A8;
		rt.writeback_format = MALI_COLOR_FORMAT_R8G8B8A8;
		rt.writeback_block_format = MALI_BLOCK_FORMAT_LINEAR;
		rt.writeback_msaa = MALI_MSAA_SINGLE;
		rt.swizzle = bgra ? (2 | (1 << 3) | (0 << 6) | (3 << 9)) : (0 | (1 << 3) | (2 << 6) | (3 << 9));
		rt.rgb.base = target_va;
		rt.rgb.row_stride = stride;
	}
	pan_pack(cpu + OFF_TLS, LOCAL_STORAGE, tl) {
		tl.wls_instances = MALI_LOCAL_STORAGE_NO_WORKGROUP_MEM;
	}
	pan_pack(cpu + OFF_DS, DEPTH_STENCIL, d) {
		d.depth_function = MALI_FUNC_ALWAYS;
		d.front_compare_function = MALI_FUNC_ALWAYS;
		d.back_compare_function = MALI_FUNC_ALWAYS;
		d.front_write_mask = 0xFF; d.back_write_mask = 0xFF;
		d.front_value_mask = 0xFF; d.back_value_mask = 0xFF;
	}
	pan_pack(cpu + OFF_BLEND, BLEND, b) {
		b.round_to_fb_precision = true;
		b.equation.color_mask = 0xF;
		b.equation.rgb.a = MALI_BLEND_OPERAND_A_SRC;
		b.equation.rgb.b = MALI_BLEND_OPERAND_B_SRC;
		b.equation.rgb.c = MALI_BLEND_OPERAND_C_ZERO;
		b.equation.alpha.a = MALI_BLEND_OPERAND_A_SRC;
		b.equation.alpha.b = MALI_BLEND_OPERAND_B_SRC;
		b.equation.alpha.c = MALI_BLEND_OPERAND_C_ZERO;
		b.internal.mode = MALI_BLEND_MODE_OPAQUE;
		b.internal.fixed_function.num_comps = 4;
		b.internal.fixed_function.rt = 0;
		b.internal.fixed_function.conversion.memory_format = (MALI_RGBA8_TB << 12) | MALI_RGB_COMPONENT_ORDER_RGBA;
	}
	pan_pack(cpu + OFF_SPOS, SHADER_PROGRAM, sp) {
		sp.stage = MALI_SHADER_STAGE_VERTEX;
		sp.register_allocation = MALI_SHADER_REGISTER_ALLOCATION_32_PER_THREAD;
		sp.binary = D + OFF_BPOS;
		sp.preload.r59 = true;
		sp.preload.r60 = true;
	}
	pan_pack(cpu + OFF_SFRAG, SHADER_PROGRAM, sp) {
		sp.stage = MALI_SHADER_STAGE_FRAGMENT;
		sp.register_allocation = MALI_SHADER_REGISTER_ALLOCATION_32_PER_THREAD;
		sp.binary = D + OFF_BFRAG;
		sp.preload.r60 = true;
		sp.preload.r61 = true;
	}

	{
		uint16_t *sp = (uint16_t *)(cpu + OFF_SAMP);
		for (int i = 0; i < 128; i++) sp[i] = 128;
	}

	void *vj = cpu + OFF_VJOB;
	pan_section_pack(vj, MALLOC_VERTEX_JOB, PRIMITIVE, cfg) {
		cfg.draw_mode = MALI_DRAW_MODE_TRIANGLES;
		cfg.index_count = vcount;
		cfg.base_vertex_offset = 0;
		cfg.allow_rotating_primitives = true;
	}
	pan_section_pack(vj, MALLOC_VERTEX_JOB, INSTANCE_COUNT, cfg) { cfg.count = 1; }
	pan_section_pack(vj, MALLOC_VERTEX_JOB, ALLOCATION, cfg) {
		cfg.vertex_packet_stride = 16;
		cfg.vertex_attribute_stride = 0;
	}
	pan_section_pack(vj, MALLOC_VERTEX_JOB, TILER, cfg) { cfg.address = D + OFF_TCTX; }
	pan_section_pack(vj, MALLOC_VERTEX_JOB, SCISSOR, cfg) {
		cfg.scissor_minimum_x = 0; cfg.scissor_minimum_y = 0;
		cfg.scissor_maximum_x = w - 1; cfg.scissor_maximum_y = h - 1;
	}
	pan_section_pack(vj, MALLOC_VERTEX_JOB, PRIMITIVE_SIZE, cfg) {}
	pan_section_pack(vj, MALLOC_VERTEX_JOB, INDICES, cfg) { cfg.address = 0; }
	pan_section_pack(vj, MALLOC_VERTEX_JOB, DRAW, cfg) {
		cfg.allow_forward_pixel_to_kill = true;
		cfg.allow_forward_pixel_to_be_killed = true;
		cfg.pixel_kill_operation = MALI_PIXEL_KILL_FORCE_EARLY;
		cfg.zs_update_operation = MALI_PIXEL_KILL_FORCE_EARLY;
		cfg.sample_mask = 0xFFFF;
		cfg.single_sampled_lines = true;
		cfg.vertex_array.packet = true;
		cfg.minimum_z = 0.0f;
		cfg.maximum_z = 1.0f;
		cfg.depth_stencil = D + OFF_DS;
		cfg.render_target_mask = 1;
		cfg.blend = D + OFF_BLEND;
		cfg.blend_count = 1;
		cfg.overdraw_alpha0 = true;
		cfg.overdraw_alpha1 = true;
		cfg.shader.thread_storage = D + OFF_TLS;
		cfg.shader.shader = D + OFF_SFRAG;
		cfg.shader.fau = D + OFF_FAU2;
		cfg.shader.fau_count = 1;
	}
	pan_section_pack(vj, MALLOC_VERTEX_JOB, POSITION, cfg) {
		cfg.thread_storage = D + OFF_TLS;
		cfg.shader = D + OFF_SPOS;
		cfg.fau = D + OFF_FAU;
		cfg.fau_count = 1;
	}
	pan_section_pack(vj, MALLOC_VERTEX_JOB, HEADER, header) {
		header.type = MALI_JOB_TYPE_MALLOC_VERTEX;
		header.index = 1;
	}
	void *job = cpu + OFF_FJOB;
	pan_section_pack(job, FRAGMENT_JOB, PAYLOAD, cfg) {
		cfg.bound_min_x = 0; cfg.bound_min_y = 0;
		cfg.bound_max_x = (w - 1) >> 4; cfg.bound_max_y = (h - 1) >> 4;
		cfg.tile_render_order = MALI_TILE_RENDER_ORDER_Z_ORDER;
		cfg.framebuffer = D + OFF_FBD;
	}
	pan_section_pack(job, FRAGMENT_JOB, HEADER, header) {
		header.type = MALI_JOB_TYPE_FRAGMENT;
		header.index = 1;
	}


	uint32_t vs = sm_submit(1, D + OFF_VJOB);
	if (vstatus) *vstatus = vs;
	return sm_submit(0, D + OFF_FJOB);
}


/* ------------------------------------------------------------------ shader pack (tools/air: air2nir.py + airc) */
typedef struct {
	char name[64];
	uint32_t stage, size; uint64_t preload;
	uint32_t push_words, work_regs, sec_off, flags; uint64_t sec_preload;
	uint32_t nvar, cdata_size;
	const uint8_t *bin, *cdata;
	uint32_t bad;   /* its pass faulted on the GPU: draws using it are skipped from then on */
} sm_shader;
static sm_shader *sm_pack; static uint32_t sm_pack_n;
#define SMF_READS_TILE (1u << 8)
#define SMF_DISCARD (1u << 9)

static void sm_pack_load(void)
{
	static bool tried; if (tried) return; tried = true;
	const char *path = "/System/Library/Extensions/SweetMetal.bundle/shaders.smsp";
	FILE *f = fopen(path, "rb");
	if (!f) { slog("SweetMTL: no shader pack at %s", path); return; }
	fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
	uint8_t *d = malloc(n); fread(d, 1, n, f); fclose(f);
	if (n < 8 || memcmp(d, "SMSP", 4)) { slog("SweetMTL: bad shader pack"); return; }
	uint32_t cnt; memcpy(&cnt, d + 4, 4);
	sm_pack = calloc(cnt, sizeof(sm_shader));
	long o = 8;
	for (uint32_t i = 0; i < cnt && o + 112 <= n; i++) {
		sm_shader *e = &sm_pack[i];
		memcpy(e, d + o, 112); o += 112;
		e->bin = d + o; o += (e->size + 15) & ~15u;
		e->cdata = d + o; o += (e->cdata_size + 15) & ~15u;
		if (e->stage == 4) {
			/* scan the Valhall code: LD_TILE (0x78) = framebuffer fetch, DISCARD.f32 (0x20) = may discard */
			for (uint32_t k = 0; k + 8 <= e->size; k += 8) {
				uint64_t w; memcpy(&w, e->bin + k, 8);
				uint32_t op = (uint32_t)(w >> 48) & 0x1FF;
				if (op == 0x78) e->flags |= SMF_READS_TILE;
				if (op == 0x20) e->flags |= SMF_DISCARD;
			}
		}
	}
	sm_pack_n = cnt;
	slog("SweetMTL: shader pack: %u shaders", cnt);
}

static const sm_shader *sm_find(NSString *name)
{
	sm_pack_load();
	if (!name) return NULL;
	const char *c = name.UTF8String;
	for (uint32_t i = 0; i < sm_pack_n; i++) if (!strcmp(sm_pack[i].name, c)) return &sm_pack[i];
	return NULL;
}

/* One draw as recorded by the encoder */
typedef struct {
	const sm_shader *vs, *fs;
	uint32_t vcount, vstart;
	uint64_t index_va; uint32_t index_type; int32_t base_vertex; uint32_t strip;
	uint32_t sc_x0, sc_y0, sc_x1, sc_y1, has_scissor;
	uint32_t blend_on, rgb_op, a_op, rgb_sf, rgb_df, a_sf, a_df, wmask;
	uint64_t buf[31];                /* GPU VA bound at each Metal vertex-stage buffer index */
	uint64_t fbuf[31];               /* fragment-stage buffers (separate push block) */
	struct { uint32_t fmt, off, bidx; } attr[16];
	uint32_t stride[31];
	struct { uint64_t va; uint32_t w, h, stride, fmt, pf, imp, swz, astc, nofl; } tex[8];   /* nofl: GPU-only memory, no cache flush */   /* astc: bw | bh << 8 | srgb << 16 */
	struct { uint32_t nearest, wrap; } smp[8];
	uint32_t ntex, nsmp;
	uint32_t fc[64]; uint64_t fc_defined;
} sm_drawrec;

#define SMP_BUF 0
#define SMP_ATTR 64
#define SMP_VP 192
#define SMP_FCDEF 216
#define SMP_CDATA_VS 224
#define SMP_CDATA_FS 232
#define SMP_DUMMY 240
#define SMP_FC 256
#define SMP_BYTES 512
#define SM_DRAW_STRIDE 0x10000      /* per draw: job 0, descs 0x200, resources 0x280, push 0x400, cdata 0x600/0x800,
                                       samplers 0xA00, textures 0xC00, planes 0xD00, VS bin 0x1000, FS bin 0x6000 */

static void sm_shader_desc(void *dst, const sm_shader *s, uint32_t stage, uint64_t bin_va, uint64_t preload, uint32_t wr)
{
	pan_pack(dst, SHADER_PROGRAM, sp) {
		sp.stage = stage;
		sp.register_allocation = wr > 32 ? MALI_SHADER_REGISTER_ALLOCATION_64_PER_THREAD : MALI_SHADER_REGISTER_ALLOCATION_32_PER_THREAD;
		sp.binary = bin_va;
		sp.preload.r48_r63 = (uint32_t)(preload >> 48);
		/* experiment (run73): keep helper threads alive in poster fragment shaders, whose derivatives (earth) hung the GPU */
		if (stage == MALI_SHADER_STAGE_FRAGMENT && sm_is_poster(getprogname())) sp.requires_helper_threads = true;
	}
}

/* Metal blend state -> Mali fixed-function equation (logic after Mesa pan_blend.c, MIT) */
static bool sm_bf_inverted(uint32_t f)   /* hardware sees ONE as inverted ZERO */
{
	switch (f) { case MTLBlendFactorOne: case MTLBlendFactorOneMinusSourceColor: case MTLBlendFactorOneMinusSourceAlpha:
	case MTLBlendFactorOneMinusDestinationColor: case MTLBlendFactorOneMinusDestinationAlpha: case MTLBlendFactorOneMinusBlendColor:
	case MTLBlendFactorOneMinusBlendAlpha: return true; default: return false; }
}
static uint32_t sm_bf_c(uint32_t f)
{
	switch (f) {
	case MTLBlendFactorZero: case MTLBlendFactorOne: return MALI_BLEND_OPERAND_C_ZERO;
	case MTLBlendFactorSourceAlpha: case MTLBlendFactorOneMinusSourceAlpha: return MALI_BLEND_OPERAND_C_SRC_ALPHA;
	case MTLBlendFactorDestinationAlpha: case MTLBlendFactorOneMinusDestinationAlpha: return MALI_BLEND_OPERAND_C_DEST_ALPHA;
	case MTLBlendFactorSourceColor: case MTLBlendFactorOneMinusSourceColor: return MALI_BLEND_OPERAND_C_SRC;
	case MTLBlendFactorDestinationColor: case MTLBlendFactorOneMinusDestinationColor: return MALI_BLEND_OPERAND_C_DEST;
	default: return MALI_BLEND_OPERAND_C_CONSTANT;
	}
}
static uint32_t sm_bf_base(uint32_t f) { return sm_bf_c(f) | (f == MTLBlendFactorZero || f == MTLBlendFactorOne ? 0x100 : 0); }
static bool sm_blend_func(uint32_t op, uint32_t sf, uint32_t df, struct MALI_BLEND_FUNCTION *fn)
{
	memset(fn, 0, sizeof *fn);
	if (op > MTLBlendOperationReverseSubtract || sf == MTLBlendFactorSourceAlphaSaturated || df == MTLBlendFactorSourceAlphaSaturated) return false;
	bool si = sm_bf_inverted(sf), di = sm_bf_inverted(df);
	if (sf == MTLBlendFactorZero) {
		fn->a = MALI_BLEND_OPERAND_A_ZERO; fn->b = MALI_BLEND_OPERAND_B_DEST; fn->negate_b = op == MTLBlendOperationSubtract;
		fn->invert_c = di; fn->c = sm_bf_c(df);
	} else if (sf == MTLBlendFactorOne) {
		fn->a = MALI_BLEND_OPERAND_A_SRC; fn->b = MALI_BLEND_OPERAND_B_DEST;
		fn->negate_b = op == MTLBlendOperationSubtract; fn->negate_a = op == MTLBlendOperationReverseSubtract;
		fn->invert_c = di; fn->c = sm_bf_c(df);
	} else if (df == MTLBlendFactorZero) {
		fn->a = MALI_BLEND_OPERAND_A_ZERO; fn->b = MALI_BLEND_OPERAND_B_SRC; fn->negate_b = op == MTLBlendOperationReverseSubtract;
		fn->invert_c = si; fn->c = sm_bf_c(sf);
	} else if (df == MTLBlendFactorOne) {
		fn->a = MALI_BLEND_OPERAND_A_DEST; fn->b = MALI_BLEND_OPERAND_B_SRC;
		fn->negate_a = op == MTLBlendOperationSubtract; fn->negate_b = op == MTLBlendOperationReverseSubtract;
		fn->invert_c = si; fn->c = sm_bf_c(sf);
	} else if (sf == df) {
		fn->a = MALI_BLEND_OPERAND_A_ZERO; fn->invert_c = si; fn->c = sm_bf_c(sf);
		if (op == MTLBlendOperationAdd) fn->b = MALI_BLEND_OPERAND_B_SRC_PLUS_DEST;
		else { fn->b = MALI_BLEND_OPERAND_B_SRC_MINUS_DEST; fn->negate_b = op == MTLBlendOperationReverseSubtract; }
	} else if ((sm_bf_base(sf) & 0xff) == (sm_bf_base(df) & 0xff) && si != di) {
		fn->a = MALI_BLEND_OPERAND_A_DEST; fn->invert_c = si; fn->c = sm_bf_c(sf);
		if (op == MTLBlendOperationAdd) fn->b = MALI_BLEND_OPERAND_B_SRC_MINUS_DEST;
		else if (op == MTLBlendOperationReverseSubtract) { fn->b = MALI_BLEND_OPERAND_B_SRC_PLUS_DEST; fn->negate_b = true; }
		else { fn->b = MALI_BLEND_OPERAND_B_SRC_PLUS_DEST; fn->negate_a = true; }
	} else return false;
	return true;
}
static void sm_pack_blend(void *dst, const sm_drawrec *r)
{
	pan_pack(dst, BLEND, b) {
		b.round_to_fb_precision = true;
		uint32_t m = r ? r->wmask : 0xF;
		b.equation.color_mask = ((m & 8) ? 1 : 0) | ((m & 4) ? 2 : 0) | ((m & 2) ? 4 : 0) | ((m & 1) ? 8 : 0);
		bool ok = r && r->blend_on && sm_blend_func(r->rgb_op, r->rgb_sf, r->rgb_df, &b.equation.rgb) &&
		    sm_blend_func(r->a_op, r->a_sf, r->a_df, &b.equation.alpha);
		if (!ok) {
			b.equation.rgb.a = MALI_BLEND_OPERAND_A_SRC; b.equation.rgb.b = MALI_BLEND_OPERAND_B_SRC; b.equation.rgb.c = MALI_BLEND_OPERAND_C_ZERO;
			b.equation.alpha.a = MALI_BLEND_OPERAND_A_SRC; b.equation.alpha.b = MALI_BLEND_OPERAND_B_SRC; b.equation.alpha.c = MALI_BLEND_OPERAND_C_ZERO;
			b.internal.mode = MALI_BLEND_MODE_OPAQUE;
		} else { b.internal.mode = MALI_BLEND_MODE_FIXED_FUNCTION; b.load_destination = true; }
		b.internal.fixed_function.num_comps = 4; b.internal.fixed_function.rt = 0;
		b.internal.fixed_function.conversion.memory_format = (MALI_RGBA8_TB << 12) | MALI_RGB_COMPONENT_ORDER_RGBA;
	}
}

/* A whole render pass: clear + N draws (one MALLOC_VERTEX job each, shared tiler context) + one FRAGMENT job. */
static uint32_t sm_pf_info(NSUInteger pf, uint32_t *fmt, uint32_t *swz);
static uint32_t sm_pf_bpp(NSUInteger pf);
/* Thread-local storage for register spills (pack flags bits 16..31 = bytes per thread; aegir_earth_fsh spills 84 and
 * page-faulted at TLS address 0, run74/75). Stack = next_pow2(align16(size)) x 2048 threads x 24 core ids (Mesa
 * panfrost_get_total_stack_size with a safe thread count). */
static void sm_pack_tls(void *dst, uint32_t tls)
{
	static sm_bo stack; static uint32_t have_per;
	uint32_t per = 0;
	if (tls) { per = 16; while (per < ((tls + 15) & ~15u)) per <<= 1; }
	if (per && per > have_per) {
		if (have_per) sm_bo_free(&stack);
		have_per = sm_bo_alloc(&stack, (uint64_t)per * 2048 * 24) ? per : 0; /* TLS stack: GPU only, never flushed */
		slog("SweetMTL: TLS stack %u bytes/thread -> %s", per, have_per ? "ok" : "alloc failed");
	}
	pan_pack(dst, LOCAL_STORAGE, tl) {
		tl.wls_instances = MALI_LOCAL_STORAGE_NO_WORKGROUP_MEM;
		if (per && have_per >= per) {
			uint32_t shift = 0; while ((16u << shift) < per) shift++;
			tl.tls_size = shift; tl.tls_address_mode = MALI_ADDRESS_MODE_PACKED; tl.tls_base_pointer = stack.gpu >> 8;
		}
	}
}
static uint32_t sm_astc_dim(uint32_t d);
static uint32_t sm_clump(NSUInteger pf);
static NSUInteger sm_target_pf = 80;   /* pixel format of the target sm_pass draws into (set by the caller) */
/* render-target writeback for 1/2-byte targets: the tile buffer stays RGBA8 (Mesa BFMT R8/RG8/A8) */
static uint32_t sm_rt_writeback(NSUInteger pf) { return pf == 1 || pf == 10 || pf == 11 ? MALI_COLOR_FORMAT_R8 : pf == 30 ? MALI_COLOR_FORMAT_R8G8 : MALI_COLOR_FORMAT_R8G8B8A8; }
static uint32_t sm_pass(sm_bo *desc, sm_bo *heap, uint64_t target_va, uint32_t w, uint32_t h, uint32_t stride,
    uint32_t packed, bool bgra, const sm_drawrec *dr, uint32_t ndraw, uint32_t *vstatus, bool preload)
{
	if (preload) { const sm_shader *rs = sm_find(@"read_surf_frag"); if (!rs || rs->size > 0x300) preload = false; }
	sm_jl_beginl(target_va, (uint64_t)stride * h);
	sm_desc_span = 0x10000; uint32_t sm_slot_cur = 0x10000;
	/* compact draw slots are opt-in (boot-arg sweetcompact=1): with them the dock blur and widget corners broke and a
	 * fragment job page-faulted (runs 150-154); fixed 64 KiB slots as before */
	static int compact = -1; if (compact < 0) { char ba[1024] = {0}; size_t bl = sizeof(ba) - 1; compact = sysctlbyname("kern.bootargs", ba, &bl, NULL, 0) == 0 && strstr(ba, "sweetcompact=0") ? 0 : 1; }   /* on: run160 clean */
	for (uint32_t i = 0; i < ndraw; i++) {
		const sm_drawrec *r = &dr[i];
		for (int k = 0; k < 31; k++) { sm_jl_add(r->buf[k]); sm_jl_add(r->fbuf[k]); }
		for (uint32_t k = 0; k < r->ntex && k < 8; k++) if (!r->tex[k].nofl) sm_jl_addl(r->tex[k].va, (uint64_t)r->tex[k].stride * (r->tex[k].h ? r->tex[k].h : 1));
		sm_jl_add(r->index_va);
	}
	snprintf(sm_cur_pass, sizeof sm_cur_pass, "%ux%u n%u %s", w, h, ndraw, ndraw && dr[0].fs ? dr[0].fs->name : "-");
	uint8_t *cpu = desc->cpu;
	uint64_t D = desc->gpu;
	memset(cpu, 0, 0x1000);
	/* the tiler heap is not cleared (Mesa never does): a 4 MiB memset + flush per pass was pure overhead */
	/* pass-wide state, same layout as the fixed-shader path */
	pan_pack(cpu + OFF_THEAP, TILER_HEAP, heap_d) {
		heap_d.size = heap->size; heap_d.base = heap->gpu; heap_d.bottom = heap->gpu; heap_d.top = heap->gpu + heap->size;
	}
	pan_pack(cpu + OFF_TCTX, TILER_CONTEXT, t) {
		t.hierarchy_mask = 0x28; t.fb_width = w; t.fb_height = h; t.heap = D + OFF_THEAP;
		t.sample_pattern = MALI_SAMPLE_PATTERN_SINGLE_SAMPLED; t.first_provoking_vertex = true;
	}
	{ uint16_t *sp = (uint16_t *)(cpu + OFF_SAMP); for (int i = 0; i < 128; i++) sp[i] = 128; }
	void *fbd = cpu + OFF_FBD;
	pan_section_pack(fbd, FRAMEBUFFER, PARAMETERS, cfg) {
		cfg.pre_frame_0 = preload ? MALI_PRE_POST_FRAME_SHADER_MODE_ALWAYS : MALI_PRE_POST_FRAME_SHADER_MODE_NEVER;
		if (preload) cfg.frame_shader_dcds = D + 0x1000;
		cfg.pre_frame_1 = MALI_PRE_POST_FRAME_SHADER_MODE_NEVER;
		cfg.post_frame = MALI_PRE_POST_FRAME_SHADER_MODE_NEVER;
		cfg.width = w; cfg.height = h; cfg.bound_max_x = w - 1; cfg.bound_max_y = h - 1;
		cfg.effective_tile_size = 256; cfg.tie_break_rule = MALI_TIE_BREAK_RULE_MINUS_180_IN_0_OUT;
		cfg.render_target_count = 1; cfg.z_internal_format = MALI_Z_INTERNAL_FORMAT_D24;
		cfg.color_buffer_allocation = 1024; cfg.sample_count = 1; cfg.sample_pattern = MALI_SAMPLE_PATTERN_SINGLE_SAMPLED;
		cfg.tiler = D + OFF_TCTX; cfg.sample_locations = D + OFF_SAMP; cfg.first_provoking_vertex = true;
	}
	pan_section_pack(fbd, FRAMEBUFFER, PADDING, padding) {}
	pan_pack((uint8_t *)fbd + pan_size(FRAMEBUFFER), RENDER_TARGET, rt) {
		rt.clean_pixel_write_enable = true;
		rt.clear.color_0 = rt.clear.color_1 = rt.clear.color_2 = rt.clear.color_3 = packed;
		rt.write_enable = true; rt.dithering_enable = true;
		rt.internal_format = MALI_COLOR_BUFFER_INTERNAL_FORMAT_R8G8B8A8;
		rt.writeback_format = sm_rt_writeback(sm_target_pf);
		rt.writeback_block_format = MALI_BLOCK_FORMAT_LINEAR; rt.writeback_msaa = MALI_MSAA_SINGLE;
		rt.swizzle = sm_target_pf == 1 ? (3 | (1 << 3) | (2 << 6) | (0 << 9)) : bgra ? (2 | (1 << 3) | (0 << 6) | (3 << 9)) : (0 | (1 << 3) | (2 << 6) | (3 << 9));
		rt.rgb.base = target_va; rt.rgb.row_stride = stride;
	}
	{
		uint32_t tls = 0;
		for (uint32_t i = 0; i < ndraw; i++) {
			if (dr[i].vs && (dr[i].vs->flags >> 16) > tls) tls = dr[i].vs->flags >> 16;
			if (dr[i].fs && (dr[i].fs->flags >> 16) > tls) tls = dr[i].fs->flags >> 16;
		}
		sm_pack_tls(cpu + OFF_TLS, tls);
	}
	pan_pack(cpu + OFF_DS, DEPTH_STENCIL, d) {
		d.depth_function = MALI_FUNC_ALWAYS; d.front_compare_function = MALI_FUNC_ALWAYS; d.back_compare_function = MALI_FUNC_ALWAYS;
		d.front_write_mask = 0xFF; d.back_write_mask = 0xFF; d.front_value_mask = 0xFF; d.back_value_mask = 0xFF;
	}
	pan_pack(cpu + OFF_BLEND, BLEND, b) {
		b.round_to_fb_precision = true;
		b.equation.color_mask = 0xF;
		b.equation.rgb.a = MALI_BLEND_OPERAND_A_SRC; b.equation.rgb.b = MALI_BLEND_OPERAND_B_SRC; b.equation.rgb.c = MALI_BLEND_OPERAND_C_ZERO;
		b.equation.alpha.a = MALI_BLEND_OPERAND_A_SRC; b.equation.alpha.b = MALI_BLEND_OPERAND_B_SRC; b.equation.alpha.c = MALI_BLEND_OPERAND_C_ZERO;
		b.internal.mode = MALI_BLEND_MODE_OPAQUE;
		b.internal.fixed_function.num_comps = 4; b.internal.fixed_function.rt = 0;
		b.internal.fixed_function.conversion.memory_format = (MALI_RGBA8_TB << 12) | MALI_RGB_COMPONENT_ORDER_RGBA;
	}
	static sm_bo dummy; static bool havedummy;
	if (!havedummy) { havedummy = sm_bo_alloc(&dummy, 0x10000); if (havedummy) sm_infra_add(&dummy); }
	if (preload) {
		/* loadAction = load: a pre-frame DCD runs read_surf_frag (texture 0 at the fragment position) over every tile */
		const sm_shader *ps = sm_find(@"read_surf_frag");
		uint8_t *Q = cpu + 0x1000; uint64_t QV = D + 0x1000;
		memset(Q, 0, 0x800);
		if (ps && ps->size <= 0x300) {
			memcpy(Q + 0x400, ps->bin, ps->size);
			sm_shader_desc(Q + 0x180, ps, MALI_SHADER_STAGE_FRAGMENT, QV + 0x400, ps->preload, ps->work_regs);
			uint32_t fmt = (MALI_RGBA8_UNORM << 12) | (bgra ? MALI_RGB_COMPONENT_ORDER_BGRA : MALI_RGB_COMPONENT_ORDER_RGBA);
			if (sm_pf_bpp(sm_target_pf) != 4) sm_pf_info(sm_target_pf, &fmt, NULL);   /* 1/2-byte target read back as such */
			pan_pack(Q + 0x260, PLANE, pl) {
				pl.plane_type = MALI_PLANE_TYPE_GENERIC; pl.clump_format = sm_clump(sm_target_pf); pl.clump_ordering = MALI_CLUMP_ORDERING_LINEAR;
				pl.pointer = target_va; pl.row_stride = stride; pl.size = stride * h; pl.slice_stride = stride * h;
			}
			pan_pack(Q + 0x240, TEXTURE, tx) {
				tx.dimension = MALI_TEXTURE_DIMENSION_2D; tx.format = fmt; tx.width = w; tx.height = h; tx.sample_count = 1;
				tx.swizzle = 0 | (1 << 3) | (2 << 6) | (3 << 9); tx.levels = 1; tx.array_size = 1; tx.surfaces = QV + 0x260;
			}
			pan_pack(Q + 0x220, SAMPLER, sc) { sc.minify_nearest = true; sc.magnify_nearest = true; sc.normalized_coordinates = true; }
			pan_pack(Q + 0x1C0 + 3 * 16, RESOURCE, rc) { rc.address = QV + 0x220; rc.size = 32; }
			pan_pack(Q + 0x1C0 + 4 * 16, RESOURCE, rc) { rc.address = QV + 0x240; rc.size = 32; }
			sm_pack_blend(Q + 0x2A0, NULL);
			pan_pack(Q, DRAW, cfg) {
				cfg.allow_forward_pixel_to_kill = true; cfg.allow_forward_pixel_to_be_killed = true;
				cfg.pixel_kill_operation = MALI_PIXEL_KILL_FORCE_EARLY; cfg.zs_update_operation = MALI_PIXEL_KILL_STRONG_EARLY;
				cfg.sample_mask = 0xFFFF; cfg.maximum_z = 1.0f; cfg.depth_stencil = D + OFF_DS;
				cfg.render_target_mask = 1; cfg.blend = QV + 0x2A0; cfg.blend_count = 1;
				cfg.shader.resources = (QV + 0x1C0) | 6; cfg.shader.shader = QV + 0x180;
				cfg.shader.thread_storage = D + OFF_TLS; cfg.shader.fau = QV + 0x300; cfg.shader.fau_count = 1;
			}
		}
	}
	uint32_t vs_all = 0;
	/* all vertex jobs of the pass in one chain (each depends on the previous: tiler order), one submit instead of
	 * one per draw; boot-arg sweetnochain = per-draw submits as before */
	static int chain = -1;
	if (chain < 0) { char ba[1024] = {0}; size_t bl = sizeof(ba) - 1; chain = sysctlbyname("kern.bootargs", ba, &bl, NULL, 0) == 0 && strstr(ba, "sweetnochain") ? 0 : 1; }
	uint32_t nchain = 0; uint8_t *prevjob = NULL; uint64_t first_va = 0;
	for (uint32_t i = 0; i < ndraw; i++) {
		const sm_drawrec *r = &dr[i];
		/* compact draw slots: 4 KiB of descriptors + the two shader binaries (was a fixed 64 KiB per draw, all of it
		 * cache-flushed before and after every job: ~7 MiB x 4 per scrolling frame) */
		uint32_t base = compact ? sm_slot_cur : 0x10000 + i * SM_DRAW_STRIDE;
		uint8_t *P = cpu + base; uint64_t PV = D + base;
		memset(P, 0, 0x1000);
		const sm_shader *vs = r->vs, *fs = r->fs;
		if (vs->size > 0x5000 || (fs && fs->size > 0xA000) || vs->cdata_size > 0x200 || (fs && fs->cdata_size > 0x200)) {
			slog("SweetMTL: shader too large for the draw slot (vs %u fs %u)", vs->size, fs ? fs->size : 0);
			continue;
		}
		uint32_t fs_off = compact ? 0x1000 + ((vs->size + 127) & ~127u) : 0x6000, fs_len = fs ? fs->size : (uint32_t)sizeof FS_GREEN;
		sm_slot_cur = base + (compact ? ((fs_off + fs_len + 127 + 0xFFF) & ~0xFFFu) : SM_DRAW_STRIDE);
		sm_desc_span = sm_slot_cur;
		uint64_t vs_bin = PV + 0x1000, fs_bin = PV + fs_off;
		memcpy(P + 0x1000, vs->bin, vs->size);
		if (vs->cdata_size) memcpy(P + 0x600, vs->cdata, vs->cdata_size);
		if (fs && fs->cdata_size) memcpy(P + 0x800, fs->cdata, fs->cdata_size);
		uint32_t fs_preload_hi, fs_wr, fs_push;
		if (fs) { memcpy(P + fs_off, fs->bin, fs->size); fs_preload_hi = 0; fs_wr = fs->work_regs; fs_push = fs->push_words; }
		else { memcpy(P + fs_off, FS_GREEN, sizeof FS_GREEN); fs_wr = 32; fs_push = 0; }
		sm_shader_desc(P + 0x200, vs, MALI_SHADER_STAGE_VERTEX, vs_bin, vs->preload, vs->work_regs);
		bool sec = (vs->flags & 1) != 0;
		if (sec) sm_shader_desc(P + 0x220, vs, MALI_SHADER_STAGE_VERTEX, vs_bin + vs->sec_off, vs->sec_preload, vs->work_regs);
		sm_shader_desc(P + 0x240, fs, MALI_SHADER_STAGE_FRAGMENT, fs_bin, fs ? fs->preload : FS_GREEN_PRELOAD, fs_wr);
		(void)fs_preload_hi;
		sm_pack_blend(P + 0x300, r);
		/* push constants (see air2nir.py ABI) */
		uint8_t *push = P + 0x400;
		{
			uint64_t cv = PV + 0x600, cf = PV + 0x800, dv = havedummy ? dummy.gpu : 0;
			memcpy(push + SMP_FCDEF, &r->fc_defined, 8);
			memcpy(push + SMP_CDATA_VS, &cv, 8); memcpy(push + SMP_CDATA_FS, &cf, 8); memcpy(push + SMP_DUMMY, &dv, 8);
			memcpy(push + SMP_FC, r->fc, sizeof r->fc);
		}
		for (int k = 0; k < 8; k++) { uint64_t v = r->buf[k] ? r->buf[k] : (havedummy ? dummy.gpu : 0); memcpy(push + SMP_BUF + 8 * k, &v, 8); }
		for (int L = 0; L < 8; L++) {
			uint32_t bi = r->attr[L].bidx;
			uint64_t va = bi < 31 && r->buf[bi] ? r->buf[bi] + r->attr[L].off : (havedummy ? dummy.gpu : 0);  /* unbound attribute: zeroed page, never VA 0 */
			uint32_t st = bi < 31 ? r->stride[bi] : 0;
			memcpy(push + SMP_ATTR + 16 * L, &va, 8); memcpy(push + SMP_ATTR + 16 * L + 8, &st, 4);
		}
		float vp[6] = { w * 0.5f, -(float)h * 0.5f, 1.0f, w * 0.5f, h * 0.5f, 0.0f };
		memcpy(push + SMP_VP, vp, sizeof vp);
		/* fragment stage: same push block but its own buffer table */
		memcpy(P + 0xE00, push, SMP_BYTES);
		if (sm_is_poster(getprogname()) || (fs && !strncmp(fs->name, "variable_blur", 13))) {   /* variable_blur: built with AIR_TXS_PUSH, no fcs */
			/* NanoUniverse shaders read texture sizes from push 480 + 4*slot (AIR_TXS_PUSH): the Valhall size query
			 * page-faulted the GPU (earth shader, run74). Not done for CoreAnimation, whose function constants 56..63 live there. */
			for (uint32_t k = 0; k < 8; k++) {
				uint32_t sz = k < r->ntex && r->tex[k].va ? (r->tex[k].w | (r->tex[k].h << 16)) : (16 | (16 << 16));
				memcpy(push + 480 + 4 * k, &sz, 4);
			}
		}
		memcpy(P + 0xE00, push, SMP_BYTES);
		/* unbound fragment buffers point at the zeroed dummy page instead of address 0 */
		for (int k = 0; k < 8; k++) { uint64_t v = r->fbuf[k] ? r->fbuf[k] : (havedummy ? dummy.gpu : 0); memcpy(P + 0xE00 + SMP_BUF + 8 * k, &v, 8); }
		/* fragment resources: SAMPLER table (3) x16 at 0xA00 (slot 15 = constexpr sampler), TEXTURE table (4) x8 at 0xC00
		 * (slot 7 = 1x1 null 2D, slot 6 = 1x1x1 null 3D, both pointing at the zeroed dummy page) */
		uint64_t res_va = 0;
		{
			for (uint32_t k = 0; k < 16; k++) {
				bool nearest = k < r->nsmp ? r->smp[k].nearest : false;
				uint32_t w = k < r->nsmp ? r->smp[k].wrap : 0;
				pan_pack(P + 0xA00 + 32 * k, SAMPLER, sc) {
					sc.minify_nearest = nearest; sc.magnify_nearest = nearest;
					sc.normalized_coordinates = true;
					sc.wrap_mode_s = sc.wrap_mode_t = sc.wrap_mode_r = MALI_WRAP_MODE_CLAMP_TO_EDGE;
					if (w) { sc.wrap_mode_s = w & 0xFF; sc.wrap_mode_t = (w >> 8) & 0xFF; sc.wrap_mode_r = (w >> 16) & 0xFF; }
					if (w >> 24) { sc.border_color_r = sc.border_color_g = sc.border_color_b = sc.border_color_a = 0x3F800000u; }
				}
			}
			for (uint32_t k = 0; k < 8; k++) {
				bool real = k < r->ntex && r->tex[k].va;
				bool is3d = !real && k == 6;
				uint64_t va = real ? r->tex[k].va : (havedummy ? dummy.gpu : 0);
				/* the null texture is 16x16 with a 64-byte row: a 1x1/4-byte plane makes the texel fetch run past
				 * the plane size and the fragment job dies with a bus fault (run32 bisect) */
				uint32_t tw = real ? r->tex[k].w : 16, th = real ? r->tex[k].h : 16, ts = real ? r->tex[k].stride : 64;
				uint32_t fmt = real ? r->tex[k].fmt : ((MALI_RGBA8_UNORM << 12) | MALI_RGB_COMPONENT_ORDER_RGBA);
				uint32_t astc = real ? r->tex[k].astc : 0;
				pan_pack(P + 0xD00 + 32 * k, PLANE, pl) {
					if (astc) {
						pl.plane_type = MALI_PLANE_TYPE_ASTC_2D;
						pl.astc._2d.block_width = sm_astc_dim(astc & 0xFF); pl.astc._2d.block_height = sm_astc_dim((astc >> 8) & 0xFF);
						pl.astc.decode_hdr = false; pl.astc.decode_wide = !((astc >> 16) & 1);
					} else pl.plane_type = MALI_PLANE_TYPE_GENERIC;
					if (!astc) pl.clump_format = real ? sm_clump(r->tex[k].pf) : MALI_CLUMP_FORMAT_RAW32;
					pl.clump_ordering = astc ? MALI_CLUMP_ORDERING_TILED_U_INTERLEAVED : MALI_CLUMP_ORDERING_LINEAR;
					pl.pointer = va; pl.row_stride = ts;
					/* ASTC: ts is one row of 16x16-block tiles */
					uint32_t prow = astc ? ((th + ((astc >> 8) & 0xFF) - 1) / ((astc >> 8) & 0xFF) + 15) / 16 : th;
					pl.size = real ? ts * prow : 0x10000; pl.slice_stride = ts * prow;
				}
				pan_pack(P + 0xC00 + 32 * k, TEXTURE, tx) {
					tx.dimension = is3d ? MALI_TEXTURE_DIMENSION_3D : MALI_TEXTURE_DIMENSION_2D;
					tx.format = fmt; tx.width = tw; tx.height = th;
					if (is3d) tx.depth = 16; else tx.sample_count = 1;
					tx.swizzle = real ? r->tex[k].swz : (0 | (1 << 3) | (2 << 6) | (3 << 9));
					/* Mesa v9: compressed textures need texel interleave even when linear (without it ASTC decoded
					 * to the magenta error colour, run80-82) */
					tx.texel_interleave = astc != 0;
					tx.levels = 1; tx.array_size = 1;
					tx.surfaces = PV + 0xD00 + 32 * k;
					tx.minimum_lod = 0; tx.maximum_lod = 0;
				}
				if (astc) {
					static int nd;
					if (nd++ < 3) {
						const uint32_t *tw32 = (const uint32_t *)(P + 0xC00 + 32 * k), *pw32 = (const uint32_t *)(P + 0xD00 + 32 * k);
						slog("SweetMTL: astc desc T %08x %08x %08x %08x %08x %08x %08x %08x", tw32[0], tw32[1], tw32[2], tw32[3], tw32[4], tw32[5], tw32[6], tw32[7]);
						slog("SweetMTL: astc desc P %08x %08x %08x %08x %08x %08x %08x %08x", pw32[0], pw32[1], pw32[2], pw32[3], pw32[4], pw32[5], pw32[6], pw32[7]);
					}
				}
			}
			memset(P + 0x280, 0, 6 * 16);
			pan_pack(P + 0x280 + 3 * 16, RESOURCE, rc) { rc.address = PV + 0xA00; rc.size = 16 * 32; }
			pan_pack(P + 0x280 + 4 * 16, RESOURCE, rc) { rc.address = PV + 0xC00; rc.size = 8 * 32; }
			res_va = (PV + 0x280) | 6;
		}
		uint32_t vs_fau = (vs->push_words + 1) / 2, fs_fau = (fs_push + 1) / 2;
		if (fs_fau < 1) fs_fau = 1;
		if (vs_fau == 0) vs_fau = 1;
		uint32_t nvar = vs->nvar; if (fs && fs->nvar > nvar) nvar = fs->nvar;
		void *vj = P;
		pan_section_pack(vj, MALLOC_VERTEX_JOB, PRIMITIVE, cfg) {
			cfg.draw_mode = r->strip ? MALI_DRAW_MODE_TRIANGLE_STRIP : MALI_DRAW_MODE_TRIANGLES; cfg.index_count = r->vcount;
			cfg.index_type = r->index_type; cfg.base_vertex_offset = r->index_type ? r->base_vertex : (int32_t)r->vstart;
			cfg.allow_rotating_primitives = true; cfg.secondary_shader = sec;
		}
		pan_section_pack(vj, MALLOC_VERTEX_JOB, INSTANCE_COUNT, cfg) { cfg.count = 1; }
		pan_section_pack(vj, MALLOC_VERTEX_JOB, ALLOCATION, cfg) {
			cfg.vertex_attribute_stride = sec ? 16 * nvar : 0;
			cfg.vertex_packet_stride = 16 + (sec ? 16 * nvar : 0);
		}
		pan_section_pack(vj, MALLOC_VERTEX_JOB, TILER, cfg) { cfg.address = D + OFF_TCTX; }
		pan_section_pack(vj, MALLOC_VERTEX_JOB, SCISSOR, cfg) {
			if (r->has_scissor) { cfg.scissor_minimum_x = r->sc_x0; cfg.scissor_minimum_y = r->sc_y0; cfg.scissor_maximum_x = r->sc_x1; cfg.scissor_maximum_y = r->sc_y1; }
			else { cfg.scissor_minimum_x = 0; cfg.scissor_minimum_y = 0; cfg.scissor_maximum_x = w - 1; cfg.scissor_maximum_y = h - 1; }
		}
		pan_section_pack(vj, MALLOC_VERTEX_JOB, PRIMITIVE_SIZE, cfg) {}
		pan_section_pack(vj, MALLOC_VERTEX_JOB, INDICES, cfg) { cfg.address = r->index_va; }
		/* forward pixel kill would drop the earlier draws' pixels under a draw that reads them back
		 * (framebuffer fetch, blending) or may not write them (discard): luma_boost read 0 (run37) */
		bool fpk = !(r->blend_on || (fs && (fs->flags & (SMF_READS_TILE | SMF_DISCARD))));
		/* run122: forward pixel kill off everywhere (boot-arg sweetfpk=1 re-enables): CA's colour-matrix/backdrop shaders
		 * (TimgBvcm*, TimgBdso*) read the destination without being flagged, and FPK dropped the wallpaper under them */
		{ static int fpkon = -1; if (fpkon < 0) { char ba[1024] = {0}; size_t bl = sizeof(ba) - 1; fpkon = sysctlbyname("kern.bootargs", ba, &bl, NULL, 0) == 0 && strstr(ba, "sweetfpk=1") ? 1 : 0; } if (!fpkon) fpk = false; }
		pan_section_pack(vj, MALLOC_VERTEX_JOB, DRAW, cfg) {
			cfg.allow_forward_pixel_to_kill = fpk; cfg.allow_forward_pixel_to_be_killed = true;
			cfg.pixel_kill_operation = MALI_PIXEL_KILL_FORCE_EARLY; cfg.zs_update_operation = MALI_PIXEL_KILL_FORCE_EARLY;
			cfg.sample_mask = 0xFFFF; cfg.single_sampled_lines = true; cfg.vertex_array.packet = true;
			cfg.minimum_z = 0.0f; cfg.maximum_z = 1.0f; cfg.depth_stencil = D + OFF_DS;
			cfg.render_target_mask = 1; cfg.blend = PV + 0x300; cfg.blend_count = 1;
			cfg.overdraw_alpha0 = false; cfg.overdraw_alpha1 = false;
			cfg.shader.thread_storage = D + OFF_TLS; cfg.shader.shader = PV + 0x240;
			cfg.shader.fau = PV + 0xE00; cfg.shader.fau_count = fs_fau ? fs_fau : 1;
			cfg.shader.resources = res_va;
		}
		pan_section_pack(vj, MALLOC_VERTEX_JOB, POSITION, cfg) {
			cfg.thread_storage = D + OFF_TLS; cfg.shader = PV + 0x200; cfg.fau = PV + 0x400; cfg.fau_count = vs_fau;
		}
		pan_section_pack(vj, MALLOC_VERTEX_JOB, VARYING, cfg) {
			if (sec) { cfg.thread_storage = D + OFF_TLS; cfg.shader = PV + 0x220; cfg.fau = PV + 0x400; cfg.fau_count = vs_fau; }
		}
		uint32_t vst = 0, vexc = 0;
		if (chain) {
			pan_section_pack(vj, MALLOC_VERTEX_JOB, HEADER, header) {
				header.type = MALI_JOB_TYPE_MALLOC_VERTEX; header.index = nchain + 1; header.dependency_2 = nchain;
			}
			if (prevjob) { uint64_t nx = PV; memcpy(prevjob + 24, &nx, 8); } else first_va = PV;
			prevjob = P; nchain++;
		} else {
			pan_section_pack(vj, MALLOC_VERTEX_JOB, HEADER, header) { header.type = MALI_JOB_TYPE_MALLOC_VERTEX; header.index = 1; }
			vst = sm_submit(1, PV);
			vexc = *(volatile uint32_t *)P;
		}
		if (sm_is_poster(getprogname())) { static int na; if (na++ < 6) slog("SweetMTL: poster draw%u avail %zuMB", i, sm_avail() >> 20); }
		{ static int nd; if (vst || nd++ < 6 || sm_is_poster(getprogname()) && nd < 40)   /* per-draw lines filled the pmsg ring (run64) */
		slog("SweetMTL: draw%u vs=%s fs=%s n=%u sec=%d nvar=%u job=%x exc=%x", i, vs->name, fs ? fs->name : "(FS_GREEN)",
		    r->vcount, sec, nvar, vst, vexc); }
		{
			static int nl;
			if (nl++ < 12) {
				slog("SweetMTL:  vb %llx %llx %llx fb %llx %llx %llx %llx", r->buf[0], r->buf[1], r->buf[2], r->fbuf[0], r->fbuf[1], r->fbuf[2], r->fbuf[3]);
				slog("SweetMTL:  tex n=%u %llx %ux%u fmt %x | %llx %ux%u | push vs %u fs %u", r->ntex, r->tex[0].va, r->tex[0].w, r->tex[0].h, r->tex[0].fmt,
				    r->tex[1].va, r->tex[1].w, r->tex[1].h, vs->push_words, fs ? fs->push_words : 0);
			}
		}
		vs_all |= vst;
	}
	pan_section_pack(cpu + OFF_FJOB, FRAGMENT_JOB, PAYLOAD, cfg) {
		cfg.bound_min_x = 0; cfg.bound_min_y = 0; cfg.bound_max_x = (w - 1) >> 4; cfg.bound_max_y = (h - 1) >> 4;
		cfg.tile_render_order = MALI_TILE_RENDER_ORDER_Z_ORDER; cfg.framebuffer = D + OFF_FBD;
	}
	pan_section_pack(cpu + OFF_FJOB, FRAGMENT_JOB, HEADER, header) { header.type = MALI_JOB_TYPE_FRAGMENT; header.index = 1; }
	if (sm_pair_ok < 0) { char ba[1024] = {0}; size_t bl = sizeof(ba) - 1; if (sysctlbyname("kern.bootargs", ba, &bl, NULL, 0) == 0 && strstr(ba, "sweetnopair")) sm_pair_ok = 0; }
	if (chain && nchain) {
		bool pair = sm_pair_ok != 0;
		sm_pair_frag = pair ? D + OFF_FJOB : 0; sm_pair_done = false;
		uint32_t cst = sm_submit(1, first_va);
		sm_pair_frag = 0;
		static int nl; if ((cst && cst != 0xFFFCu) || nl++ < 3) slog("SweetMTL: vertex chain of %u jobs -> %x", nchain, cst);
		vs_all |= cst;
		if (pair && sm_pair_done) {
			sm_pair_done = false;
			if (vstatus) *vstatus = vs_all;
			return sm_check(sm_pair_status, 0);
		}
	}
	if (vstatus) *vstatus = vs_all;
	return sm_submit(0, D + OFF_FJOB);
}

/* Base for every SweetMTL object: selectors CoreAnimation sends that are not implemented yet are logged
 * once and answered with zero instead of raising "unrecognized selector". */
static void sm_zero_return(NSInvocation *inv)
{
	const char *rt = inv.methodSignature.methodReturnType;
	const char *sn = sel_getName(inv.selector);
	if (rt[0] == '@' && (!strncmp(sn, "new", 3) || strstr(sn, "Encoder"))) {
		/* unimplemented factory: hand back a placeholder that swallows every message */
		void *o = (__bridge_retained void *)[NSClassFromString(@"SweetMTLObject") new];
		[inv setReturnValue:&o];
		return;
	}
	uint8_t z[128] = {0};
	if (inv.methodSignature.methodReturnLength && inv.methodSignature.methodReturnLength <= sizeof z) [inv setReturnValue:z];
}
static __weak id sm_device;
@interface SweetMTLObject : NSObject
@property (nonatomic, copy) NSString *label;
@end
@implementation SweetMTLObject
- (id)device { return sm_device; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
	NSMethodSignature *m = [super methodSignatureForSelector:sel];
	return m ? m : [NSMethodSignature signatureWithObjCTypes:"@@:@@@@"];
}
- (void)forwardInvocation:(NSInvocation *)inv
{
	static NSMutableSet *seen; static dispatch_once_t once; dispatch_once(&once, ^{ seen = [NSMutableSet new]; });
	NSString *k = [NSString stringWithFormat:@"%s %s", class_getName(object_getClass(self)), sel_getName(inv.selector)];
	BOOL first = NO;
	@synchronized (seen) { if (![seen containsObject:k]) { [seen addObject:k]; first = YES; } }
	if (first) slog("SweetMTL: stub %s", k.UTF8String);
	sm_zero_return(inv);
}
@end

static void sm_bt_kept(void);
static void sm_region_info(const void *p);
static void sm_find_sharers(const void *p, const char *what);
@class SweetMTLTexture;
@interface SweetMTLBuffer : SweetMTLObject
@property (nonatomic, readonly) NSUInteger length;
@end
@protocol SweetBufClient
- (const uint8_t *)sm_clientPtr;
@end
@protocol SweetTexBufferInit
- (instancetype)initWithBuffer:(id)buf bo:(const sm_bo *)bbo descriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)off bytesPerRow:(NSUInteger)bpr;
@end
@implementation SweetMTLBuffer { sm_bo _bo; void (^_dealloc)(void *, NSUInteger); void *_ptr; bool _copied; }
/* not importable client memory: the GPU-side copy goes stale, so textures made on it re-copy from here */
- (const uint8_t *)sm_clientPtr { return _copied ? (const uint8_t *)_ptr : NULL; }
- (instancetype)initWithLength:(NSUInteger)len bytes:(const void *)p
{
	self = [super init];
	if (!sm_bo_alloc(&_bo, len ? len : 16)) return nil;
	_length = len;
	if (p) memcpy(_bo.cpu, p, len);
	return self;
}
- (instancetype)initWithBytesNoCopy:(void *)p length:(NSUInteger)len deallocator:(void (^)(void *, NSUInteger))dealloc
{
	self = [super init];
	if (!p || !len || !sm_bo_import(&_bo, p, len)) {
		/* not importable: fall back to a copy (contents stay the caller's pointer semantics only at creation) */
		if (!sm_bo_alloc(&_bo, len ? len : 16)) return nil;
		if (p && len) memcpy(_bo.cpu, p, len);
		_copied = (p != NULL);
	}
	_length = len; _dealloc = [dealloc copy]; _ptr = p;
	return self;
}
- (void)dealloc { sm_bo_free(&_bo); if (_dealloc) _dealloc(_ptr, _length); }
- (const sm_bo *)smBo { return &_bo; }
- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)off bytesPerRow:(NSUInteger)bpr
{
	id<SweetTexBufferInit> t = (id<SweetTexBufferInit>)[NSClassFromString(@"SweetMTLTexture") alloc];
	return [t initWithBuffer:self bo:&_bo descriptor:d offset:off bytesPerRow:bpr];
}
- (id)newLinearTextureWithDescriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)off bytesPerRow:(NSUInteger)bpr bytesPerImage:(NSUInteger)bpi
{
	return [self newTextureWithDescriptor:d offset:off bytesPerRow:bpr];
}
- (void *)contents { return _bo.cpu; }
- (uint64_t)gpuAddress { return _bo.gpu; }
- (MTLStorageMode)storageMode { return MTLStorageModeShared; }
- (void)didModifyRange:(NSRange)r {}
@end

@interface SweetMTLFunction : SweetMTLObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSDictionary *constants;      /* index -> uint32 */
@end
static NSMutableDictionary *sm_fc_dict(id obj);
/* function constant name -> [[function_constant(N)]] index, from the library's CNST metadata (fcmap.txt, made on the Mac) */
static NSDictionary *sm_fc_names(void)
{
	static NSDictionary *m;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSMutableDictionary *d = [NSMutableDictionary dictionary];
		NSString *t = [NSString stringWithContentsOfFile:@"/System/Library/Extensions/SweetMetal.bundle/fcmap.txt" encoding:NSUTF8StringEncoding error:NULL];
		for (NSString *line in [t componentsSeparatedByString:@"\n"]) {
			NSArray *p = [line componentsSeparatedByString:@" "];
			if (p.count == 2) d[p[0]] = @([p[1] integerValue]);
		}
		m = d;
		slog("SweetMTL: fcmap %lu names", (unsigned long)d.count);
	});
	return m;
}
static NSMutableDictionary *sm_fc_read(id cv);
@implementation SweetMTLFunction
- (MTLFunctionType)functionType
{
	const sm_shader *s = sm_find(_name);
	return s && s->stage == 4 ? MTLFunctionTypeFragment : MTLFunctionTypeVertex;
}
@end

@interface SweetMTLLibrary : SweetMTLObject
@end
/* CoreAnimation asks for its uber shaders by base name + function constants; the pipelinelib ships them
 * pre-specialized. variants.txt (generated on the Mac from pipelines.desc) lists every specialization:
 *   <published name> <base function> name=value ...   -> pick the one whose constants match. */
static NSDictionary *sm_variants;   /* base -> array of @[published, @{name: value}] */
static void sm_variants_load(void)
{
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSString *t = [NSString stringWithContentsOfFile:@"/System/Library/Extensions/SweetMetal.bundle/variants.txt" encoding:NSUTF8StringEncoding error:NULL];
		NSMutableDictionary *m = [NSMutableDictionary dictionary]; NSUInteger nv = 0;
		for (NSString *line in [t componentsSeparatedByString:@"\n"]) {
			NSArray *f = [line componentsSeparatedByString:@" "];
			if (f.count < 2) continue;
			NSMutableDictionary *kv = [NSMutableDictionary dictionary];
			for (NSUInteger i = 2; i < f.count; i++) {
				NSArray *p = [f[i] componentsSeparatedByString:@"="];
				if (p.count == 2) kv[p[0]] = @([p[1] intValue]);
			}
			NSMutableArray *a = m[f[1]] ?: (m[f[1]] = [NSMutableArray array]);
			[a addObject:@[ f[0], kv ]]; nv++;
		}
		sm_variants = m;
		slog("SweetMTL: %lu specialized variants of %lu base functions", (unsigned long)nv, (unsigned long)m.count);
	});
}
static NSString *sm_match_variant(NSString *base, NSDictionary *cv)
{
	sm_variants_load();
	NSArray *cands = sm_variants[base];
	if (!cands.count) return nil;
	NSString *best = nil; NSUInteger bestMiss = NSUIntegerMax;
	for (NSArray *c in cands) {
		NSDictionary *kv = c[1]; NSUInteger miss = 0;
		for (NSString *k in kv) {
			NSNumber *want = cv[k];
			if ((want ? want.intValue : 0) != [kv[k] intValue]) miss++;
		}
		if (miss < bestMiss && sm_find(c[0])) { bestMiss = miss; best = c[0]; }
		if (miss == 0 && sm_find(c[0])) break;
	}
	static int nl;
	if (nl++ < 40) slog("SweetMTL: %s + %lu constants -> %s (%lu mismatches)", base.UTF8String, (unsigned long)cv.count,
	    best ? best.UTF8String : "none", (unsigned long)(best ? bestMiss : 0));
	if (bestMiss > 0 && best) slog("SweetMTL: near %s miss %lu", best.UTF8String + (strncmp(best.UTF8String, "com.apple.coreanimation.frag.", 29) ? 0 : 29), (unsigned long)bestMiss);
	if (bestMiss > 0) {
		/* no exact specialization: dump the non-zero constants so the variant can be built offline */
		static int nm;
		if (nm++ < 10) {
			char b[132]; int L = snprintf(b, sizeof b, "nomatch%d %s:", nm, base.UTF8String);
			NSMutableArray *ks0 = [NSMutableArray array];
			for (id k in cv) if ([k isKindOfClass:[NSString class]]) [ks0 addObject:k];
			for (NSString *k in [ks0 sortedArrayUsingSelector:@selector(compare:)]) {
				int v = [cv[k] intValue]; if (!v) continue;
				const char *ks = k.UTF8String; if (!strncmp(ks, "fc_", 3)) ks += 3;
				char one[48]; int n = snprintf(one, sizeof one, " %s=%d", ks, v);
				if (L + n >= 128) { slog("SweetMTL: %s", b); L = snprintf(b, sizeof b, "nomatch%d +", nm); }
				memcpy(b + L, one, n + 1); L += n;
			}
			slog("SweetMTL: %s", b);
		}
	}
	return bestMiss <= 2 ? best : nil;
}

@implementation SweetMTLLibrary
- (id)newFunctionWithName:(NSString *)name
{
	SweetMTLFunction *f = [SweetMTLFunction new]; f.name = name;
	slog("SweetMTL: function %s -> %s", name.UTF8String, sm_find(name) ? "translated" : "NOT in pack");
	return f;
}
- (id)newFunctionWithName:(NSString *)name constantValues:(id)cv functionCache:(id)fc specializedName:(NSString *)sp error:(NSError **)err
{
	if (err) *err = nil;
	NSString *use = (sp && sm_find(sp)) ? sp : name;
	if (use == name && !sm_find(name) && cv) {
		NSString *v = sm_match_variant(name, sm_fc_read(cv));
		if (v) use = v;
	}
	SweetMTLFunction *f = [SweetMTLFunction new]; f.name = use;
	f.constants = cv ? [sm_fc_read(cv) copy] : @{};
	slog("SweetMTL: function %s (specialized %s) -> %s", name.UTF8String, sp ? sp.UTF8String : "-", sm_find(use) ? "translated" : "NOT in pack");
	{
		/* which keys arrive: indices or names (the pipeline only applies index keys) */
		static int nl;
		if (nl++ < 12) {
			NSMutableString *ks = [NSMutableString string];
			for (id k in f.constants) { if (ks.length > 150) break; [ks appendFormat:@"%@=%@ ", k, f.constants[k]]; }
			slog("SweetMTL: fc %s: %s", use.UTF8String, ks.UTF8String);
		}
	}
	return f;
}
- (void)newFunctionWithName:(NSString *)name constantValues:(id)cv functionCache:(id)fc specializedName:(NSString *)sp completionHandler:(void (^)(id, NSError *))h
{
	id f = [self newFunctionWithName:name constantValues:cv functionCache:fc specializedName:sp error:NULL];
	if (h) h(f, nil);
}
- (id)newFunctionWithName:(NSString *)name constantValues:(id)cv pipelineLibrary:(id)pl error:(NSError **)err
{
	return [self newFunctionWithName:name constantValues:cv error:err];
}
- (void)newFunctionWithName:(NSString *)name constantValues:(id)cv completionHandler:(void (^)(id, NSError *))h
{
	id f = [self newFunctionWithName:name constantValues:cv error:NULL];
	if (h) h(f, nil);
}
- (id)newFunctionWithName:(NSString *)name constantValues:(id)cv error:(NSError **)err
{
	if (err) *err = nil;
	SweetMTLFunction *f = [self newFunctionWithName:name];
	f.constants = cv ? [sm_fc_read(cv) copy] : @{};
	slog("SweetMTL: function %s with %lu constants", name.UTF8String, (unsigned long)f.constants.count);
	return f;
}
- (id)newFunctionWithDescriptor:(MTLFunctionDescriptor *)d error:(NSError **)err
{
	NSString *sp = [d respondsToSelector:@selector(specializedName)] ? [d valueForKey:@"specializedName"] : nil;
	return [self newFunctionWithName:d.name constantValues:d.constantValues functionCache:nil specializedName:sp error:err];
}
- (void)newFunctionWithDescriptor:(MTLFunctionDescriptor *)d completionHandler:(void (^)(id, NSError *))h
{
	id f = [self newFunctionWithDescriptor:d error:NULL];
	if (h) h(f, nil);
}
- (NSArray *)functionNames
{
	sm_pack_load();
	NSMutableArray *a = [NSMutableArray array];
	for (uint32_t i = 0; i < sm_pack_n; i++) [a addObject:@(sm_pack[i].name)];
	return a;
}
@end


/* ------------------------------------------------------------------ function constants
 * MTLFunctionConstantValues is opaque; record what the app sets by intercepting the internal setters. */
static char sm_fc_key;
static NSMutableDictionary *sm_fc_dict(id obj)
{
	NSMutableDictionary *d = objc_getAssociatedObject(obj, &sm_fc_key);
	if (!d) { d = [NSMutableDictionary dictionary]; objc_setAssociatedObject(obj, &sm_fc_key, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
	return d;
}
static NSUInteger sm_dt_size(NSUInteger t)
{
	switch (t) {
	case MTLDataTypeBool: case MTLDataTypeChar: case MTLDataTypeUChar: return 1;
	case MTLDataTypeChar2: case MTLDataTypeUChar2: case MTLDataTypeShort: case MTLDataTypeUShort: case MTLDataTypeHalf: return 2;
	case MTLDataTypeChar3: case MTLDataTypeUChar3: return 3;
	case MTLDataTypeChar4: case MTLDataTypeUChar4: return 4;
	default: return 4;
	}
}
static IMP sm_orig_set1, sm_orig_setN;
static void sm_set1(id self, SEL _cmd, const void *v, NSUInteger type, NSUInteger idx)
{
	NSUInteger n = sm_dt_size(type); uint32_t w = 0; memcpy(&w, v, n > 4 ? 4 : n);
	sm_fc_dict(self)[@(idx)] = @(w);
	((void (*)(id, SEL, const void *, NSUInteger, NSUInteger))sm_orig_set1)(self, _cmd, v, type, idx);
}
static void sm_setN(id self, SEL _cmd, const void *v, NSUInteger type, NSRange r)
{
	NSUInteger n = sm_dt_size(type);
	for (NSUInteger i = 0; i < r.length; i++) {
		uint32_t w = 0; memcpy(&w, (const uint8_t *)v + i * n, n > 4 ? 4 : n);
		sm_fc_dict(self)[@(r.location + i)] = @(w);
	}
	((void (*)(id, SEL, const void *, NSUInteger, NSRange))sm_orig_setN)(self, _cmd, v, type, r);
}
/* Read the constants straight out of an MTLFunctionConstantValues (works for copies made inside Metal too):
 * newIndexedConstantArray / newNamedConstantArray hold MTLIndexedConstantValue / MTLNamedConstantValue. */
static uint32_t sm_cv_word(id o)
{
	SEL sd = sel_registerName("data"), st = sel_registerName("dataType");
	Method m = class_getInstanceMethod(object_getClass(o), sd);
	if (!m) return 0;
	NSUInteger type = [o respondsToSelector:st] ? ((NSUInteger (*)(id, SEL))objc_msgSend)(o, st) : 0;
	const char *enc = method_getTypeEncoding(m);
	const void *p = NULL;
	if (enc && enc[0] == '@') { NSData *d = ((id (*)(id, SEL))objc_msgSend)(o, sd); p = d.bytes; }
	else p = ((const void *(*)(id, SEL))objc_msgSend)(o, sd);
	uint32_t w = 0;
	if (p) { NSUInteger n = sm_dt_size(type); memcpy(&w, p, n > 4 ? 4 : (n ? n : 1)); }
	return w;
}
static NSMutableDictionary *sm_fc_read(id cv)
{
	NSMutableDictionary *d = [NSMutableDictionary dictionary];
	if (!cv) return d;
	SEL si = sel_registerName("newIndexedConstantArray"), sn = sel_registerName("newNamedConstantArray");
	if ([cv respondsToSelector:si]) {
		NSArray *a = ((id (*)(id, SEL))objc_msgSend)(cv, si);
		for (id o in a) d[@(((NSUInteger (*)(id, SEL))objc_msgSend)(o, sel_registerName("index")))] = @(sm_cv_word(o));
	}
	if ([cv respondsToSelector:sn]) {
		NSArray *a = ((id (*)(id, SEL))objc_msgSend)(cv, sn);
		for (id o in a) { NSString *nm = ((id (*)(id, SEL))objc_msgSend)(o, sel_registerName("name")); if (nm) d[nm] = @(sm_cv_word(o)); }
	}
	[d addEntriesFromDictionary:sm_fc_dict(cv)];
	return d;
}
static IMP sm_orig_setName;
static void sm_setName(id self, SEL _cmd, const void *v, NSUInteger type, NSString *name)
{
	NSUInteger n = sm_dt_size(type); uint32_t w = 0; memcpy(&w, v, n > 4 ? 4 : n);
	if (name) sm_fc_dict(self)[name] = @(w);
	((void (*)(id, SEL, const void *, NSUInteger, NSString *))sm_orig_setName)(self, _cmd, v, type, name);
}
static void sm_fc_hook(void)
{
	static bool done; if (done) return; done = true;
	Class c = NSClassFromString(@"MTLFunctionConstantValuesInternal");
	if (!c) { slog("SweetMTL: no MTLFunctionConstantValuesInternal"); return; }
	Method m1 = class_getInstanceMethod(c, @selector(setConstantValue:type:atIndex:));
	Method m2 = class_getInstanceMethod(c, @selector(setConstantValues:type:withRange:));
	if (m1) sm_orig_set1 = method_setImplementation(m1, (IMP)sm_set1);
	if (m2) sm_orig_setN = method_setImplementation(m2, (IMP)sm_setN);
	Method m3 = class_getInstanceMethod(c, @selector(setConstantValue:type:withName:));
	if (m3) sm_orig_setName = method_setImplementation(m3, (IMP)sm_setName);
}
/* ------------------------------------------------------------------ Metal objects (phase 2a) */
/* MTLPixelFormat -> bytes per pixel, Mali format word, texture swizzle (after Mesa pan_format.c, Valhall).
 * Swizzle: 3 bits per channel, R=0 G=1 B=2 A=3 zero=4 one=5. Unknown formats fall back to 4-byte RGBA8. */
#define SM_SWZ(r, g, b, a) ((r) | ((g) << 3) | ((b) << 6) | ((a) << 9))
static uint32_t sm_pf_info(NSUInteger pf, uint32_t *fmt, uint32_t *swz)
{
	uint32_t f = (MALI_RGBA8_UNORM << 12) | MALI_RGB_COMPONENT_ORDER_RGBA, w = SM_SWZ(0, 1, 2, 3), b = 4;
	switch (pf) {
	case 1:   f = MALI_R8_UNORM << 12; w = SM_SWZ(4, 4, 4, 0); b = 1; break;            /* A8Unorm */
	case 10: case 11: f = MALI_R8_UNORM << 12; w = SM_SWZ(0, 4, 4, 5); b = 1; break;   /* R8Unorm(_sRGB) */
	case 25:  f = MALI_R16F << 12; w = SM_SWZ(0, 4, 4, 5); b = 2; break;                /* R16Float */
	case 30:  f = MALI_RG8_UNORM << 12; w = SM_SWZ(0, 1, 4, 5); b = 2; break;           /* RG8Unorm */
	case 55:  f = MALI_R32F << 12; w = SM_SWZ(0, 4, 4, 5); b = 4; break;                /* R32Float */
	case 65:  f = MALI_RG16F << 12; w = SM_SWZ(0, 1, 4, 5); b = 4; break;               /* RG16Float */
	case 115: f = MALI_RGBA16F << 12; b = 8; break;                                      /* RGBA16Float */
	case 125: f = MALI_RGBA32F << 12; b = 16; break;                                     /* RGBA32Float */
	default:
		if (sm_is_bgra(pf)) f = (MALI_RGBA8_UNORM << 12) | MALI_RGB_COMPONENT_ORDER_BGRA;
		break;
	}
	if (fmt) *fmt = f;
	if (swz) *swz = w;
	return b;
}
static uint32_t sm_pf_bpp(NSUInteger pf) { return sm_pf_info(pf, NULL, NULL); }
/* plane clump format = bytes per texel (RAW32 on a 1-byte R8 texture made the GPU address 4x past its rows) */
static uint32_t sm_clump(NSUInteger pf)
{
	uint32_t b = sm_pf_bpp(pf);
	return b == 1 ? MALI_CLUMP_FORMAT_RAW8 : b == 2 ? MALI_CLUMP_FORMAT_RAW16 : b == 8 ? MALI_CLUMP_FORMAT_RAW64 : b == 16 ? MALI_CLUMP_FORMAT_RAW128 : MALI_CLUMP_FORMAT_RAW32;
}
/* ASTC: MTLPixelFormatASTC_*_sRGB 186..200, _LDR 204..218 (no 191/209). Returns block width (0 = not ASTC). */
static uint32_t sm_astc(NSUInteger pf, uint32_t *bh, bool *srgb)
{
	static const uint8_t W[15] = { 4, 5, 5, 6, 6, 0, 8, 8, 8, 10, 10, 10, 10, 12, 12 }, H[15] = { 4, 4, 5, 5, 6, 0, 5, 6, 8, 5, 6, 8, 10, 10, 12 };
	int i = pf >= 186 && pf <= 200 ? (int)pf - 186 : pf >= 204 && pf <= 218 ? (int)pf - 204 : -1;
	if (i < 0 || !W[i]) return 0;
	if (bh) *bh = H[i];
	if (srgb) *srgb = pf <= 200;
	return W[i];
}
void decode_block(const uint8_t *buf, const int bw, const int bh, uint32_t *outbuf);   /* astc_dec.c */
static uint32_t sm_astc_dim(uint32_t d) { return d == 4 ? 0 : d == 5 ? 1 : d == 6 ? 2 : d == 8 ? 4 : d == 10 ? 6 : 7; }

@interface SweetMTLTexture : SweetMTLObject
@property (nonatomic, readonly) NSUInteger width, height, pixelFormat, bytesPerRow;
@property (nonatomic, readonly) sm_bo *bo;
@property (nonatomic, weak) id device;
- (void)sm_sync;
- (void)sm_setLazy:(const void *)p length:(NSUInteger)len bytesPerRow:(NSUInteger)bpr deallocator:(void (^)(void *, NSUInteger))dl;
- (NSUInteger)gpuWidth;
- (NSUInteger)gpuHeight;
- (bool)sm_noflush;
- (bool)sm_isShadowed;
- (bool)sm_allZero;
- (void)sm_writeback;
- (uint32_t)maliFormat;
- (uint32_t)maliSwizzle;
- (uint32_t)bpp;
@end
@implementation SweetMTLTexture {
	sm_bo _store; IOSurfaceRef _surface;
	id _parent;                 /* buffer whose memory this texture aliases (newTextureWithDescriptor:offset:...) */
	bool _view;                 /* _store borrowed from _parent: never freed here */
	sm_bo _shadow; bool _hasShadow; const uint8_t *_src; NSUInteger _srcBpr;   /* unaligned pitch: GPU reads a copy */
	NSUInteger _dec, _gw, _gh;   /* CPU-decoded ASTC: downscale factor and the stored (GPU) size */
	const uint8_t *_lazy; NSUInteger _lazyLen, _lazyBpr; uint64_t _lazySum; void (^_lazyDl)(void *, NSUInteger);   /* no-copy ASTC: client fills it later */
	uint8_t _swz[4];            /* descriptor channel swizzle (MTLTextureSwizzle: 0 zero, 1 one, 2 R, 3 G, 4 B, 5 A) */
	bool _allZero;              /* last full CPU upload was entirely zero (no content yet) */
	int8_t _wbOK;               /* shadow write-back target writable: -1 unknown, 0 no, 1 yes */
	bool _priv, _cpuDirty;      /* MTLStorageModePrivate: only the GPU touches it, so no cache flush unless we wrote it on the CPU */
}
- (bool)sm_isShadowed { return _hasShadow; }
- (bool)sm_allZero { return _allZero; }
/* GPU wrote this texture: copy an aligned shadow back to the memory it stands for (client buffer / IOSurface). Without it
 * snapshots rendered into 16-byte-pitch shared buffers stayed all zero for their readers (the home screen black
 * rectangle: an opaque snapshot image that came back empty, run131), and the next sm_sync overwrote the GPU's output. */
- (void)sm_writeback
{
	if (_view && [_parent isKindOfClass:[SweetMTLTexture class]]) { [(SweetMTLTexture *)_parent sm_writeback]; return; }
	if (!_hasShadow || !_src || !_shadow.cpu) return;
	NSUInteger rb = _width * sm_pf_bpp(_pixelFormat); if (rb > _srcBpr) rb = _srcBpr;
	if (_wbOK < 0) {
		vm_address_t a = (vm_address_t)_src; vm_size_t sz = 0; natural_t depth = 4;
		vm_region_submap_info_data_64_t info; mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
		kern_return_t kr = vm_region_recurse_64(mach_task_self(), &a, &sz, &depth, (vm_region_recurse_info_t)&info, &cnt);
		uint64_t need = (uint64_t)_srcBpr * (_height ? _height - 1 : 0) + rb;
		_wbOK = (!kr && a <= (vm_address_t)_src && (info.protection & VM_PROT_WRITE) && (uint64_t)((vm_address_t)_src - a) + need <= sz) ? 1 : 0;
		static int nl; if (nl++ < 8) slog("SweetMTL: shadow writeback %lux%lu pf%lu src bpr %lu -> %s (prot %x tag %u)", (unsigned long)_width, (unsigned long)_height,
		    (unsigned long)_pixelFormat, (unsigned long)_srcBpr, _wbOK ? "on" : "off", kr ? 0 : info.protection, kr ? 0 : info.user_tag);
	}
	if (_wbOK != 1) return;
	for (NSUInteger y = 0; y < _height; y++) memcpy((uint8_t *)_src + y * _srcBpr, _shadow.cpu + y * _bytesPerRow, rb);
}
/* true when this texture can skip the pre-job cache flush: private and not written by the CPU since the last flush */
- (bool)sm_noflush
{
	if (!_priv || _cpuDirty || _hasShadow || _lazy || _surface || _view) { _cpuDirty = false; return false; }
	return true;
}
- (void)sm_setLazy:(const void *)p length:(NSUInteger)len bytesPerRow:(NSUInteger)bpr deallocator:(void (^)(void *, NSUInteger))dl
{
	_lazy = p; _lazyLen = len; _lazyBpr = bpr; _lazyDl = [dl copy]; _lazySum = 1;
}
- (bool)sm_lazyRefresh
{
	/* re-decode when sampled blocks changed (cheap check: 256 blocks spread over the image) */
	if (!_lazy) return false;
	uint64_t h = 1469598103934665603ULL; NSUInteger nb = _lazyLen / 16;
	for (NSUInteger i = 0; i < 4096 && nb; i++) { uint64_t v[2]; memcpy(v, _lazy + ((i * (nb / 4096 + 1) + i * 7) % nb) * 16, 16); h = (h ^ v[0] ^ (v[1] * 31)) * 1099511628211ULL; }
	if (h == _lazySum) return false;
	_lazySum = h;
	{ static int nl; if (nl++ < 3) { const uint64_t *q = (const uint64_t *)_lazy; NSUInteger m = (_lazyLen / 32) & ~(NSUInteger)1;
	  slog("SweetMTL: astc lazy bytes %016llx %016llx %016llx %016llx | mid %016llx %016llx", q[0], q[1], q[2], q[3], q[m], q[m + 1]); } }
	[self replaceRegion:MTLRegionMake2D(0, 0, _width, _height) mipmapLevel:0 withBytes:_lazy bytesPerRow:_lazyBpr];
	return true;
}
/* texture views share the store (Astronomy's earth bound an sRGB view at slot 0 that arrived as nil, run114) */
- (instancetype)initViewOf:(SweetMTLTexture *)src pixelFormat:(NSUInteger)pf
{
	self = [super init];
	_device = src->_device; _width = src->_width; _height = src->_height; _pixelFormat = pf; _bytesPerRow = src->_bytesPerRow;
	_store = src->_hasShadow ? src->_shadow : src->_store; _view = true; _parent = src;
	_dec = src->_dec; _gw = src->_gw; _gh = src->_gh; _priv = src->_priv; _cpuDirty = true;
	memcpy(_swz, src->_swz, 4);
	if (sm_astc(src->_pixelFormat, NULL, NULL) && !sm_astc(pf, NULL, NULL)) _pixelFormat = src->_pixelFormat;   /* decoded store stays BGRA8 */
	_bo = &_store;
	static int nl; if (nl++ < 8) slog("SweetMTL: texture view %lux%lu pf%lu -> pf%lu", (unsigned long)_width, (unsigned long)_height, (unsigned long)src->_pixelFormat, (unsigned long)pf);
	return self;
}
- (id)newTextureViewWithPixelFormat:(MTLPixelFormat)pf { return [[SweetMTLTexture alloc] initViewOf:self pixelFormat:pf]; }
- (id)newTextureViewWithPixelFormat:(MTLPixelFormat)pf textureType:(MTLTextureType)tt levels:(NSRange)lv slices:(NSRange)sl
{
	return [[SweetMTLTexture alloc] initViewOf:self pixelFormat:pf];
}
- (id)newTextureViewWithPixelFormat:(MTLPixelFormat)pf textureType:(MTLTextureType)tt levels:(NSRange)lv slices:(NSRange)sl swizzle:(MTLTextureSwizzleChannels)sw
{
	return [[SweetMTLTexture alloc] initViewOf:self pixelFormat:pf];
}
- (NSUInteger)gpuWidth { return _gw ? _gw : _width; }
- (NSUInteger)gpuHeight { return _gh ? _gh : _height; }
- (instancetype)initWithBuffer:(id)buf bo:(const sm_bo *)bbo descriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)off bytesPerRow:(NSUInteger)bpr
{
	self = [super init];
	_pixelFormat = d.pixelFormat; _width = d.width; _height = d.height;
	if (!bbo || !bbo->cpu || off + (uint64_t)bpr * (_height ? _height - 1 : 0) + _width * sm_pf_bpp(_pixelFormat) > bbo->size + 0x4000) return nil;
	_parent = buf; _view = true;
	_store = *bbo; _store.cpu = bbo->cpu + off; _store.gpu = bbo->gpu + off; _store.size = bbo->size - off;
	_bytesPerRow = bpr;
	const uint8_t *client = [buf respondsToSelector:@selector(sm_clientPtr)] ? [buf sm_clientPtr] : NULL;
	if ((bpr & 63) || client) {
		/* Mali linear planes need a 64-byte aligned pitch (run34): sample from an aligned copy, refreshed per draw */
		NSUInteger abpr = (_width * sm_pf_bpp(_pixelFormat) + 63) & ~(NSUInteger)63;
		if (!sm_bo_alloc(&_shadow, abpr * (_height ? _height : 1))) return nil;
		_hasShadow = true; _src = client ? client + off : _store.cpu; _srcBpr = bpr; _wbOK = -1;
		_store = _shadow; _bytesPerRow = abpr;
		[self sm_sync];
	}
	static int nl; if (nl++ < 8) slog("SweetMTL: buffer texture %lux%lu fmt %lu bpr %lu off %lu%s", (unsigned long)_width, (unsigned long)_height,
	    (unsigned long)_pixelFormat, (unsigned long)bpr, (unsigned long)off, _hasShadow ? " (shadow)" : "");
	_bo = &_store;
	return self;
}
- (void)sm_sync
{
	if (_view && [_parent isKindOfClass:[SweetMTLTexture class]]) { [(SweetMTLTexture *)_parent sm_sync]; return; }
	if (_lazy && [self sm_lazyRefresh]) { static int nl; if (nl++ < 6) slog("SweetMTL: astc lazy decode %lux%lu", (unsigned long)_width, (unsigned long)_height); }
	if (!_hasShadow) return;
	NSUInteger n = _width * sm_pf_bpp(_pixelFormat) < _srcBpr ? _width * sm_pf_bpp(_pixelFormat) : _srcBpr;
	for (NSUInteger y = 0; y < _height; y++) memcpy(_shadow.cpu + y * _bytesPerRow, _src + y * _srcBpr, n);
}
- (instancetype)initWithDevice:(id)dev descriptor:(MTLTextureDescriptor *)d
{
	self = [super init];
	_device = dev; _width = d.width; _height = d.height; _pixelFormat = d.pixelFormat;
	_priv = d.storageMode == MTLStorageModePrivate; _cpuDirty = true;
	_swz[0] = 2; _swz[1] = 3; _swz[2] = 4; _swz[3] = 5;
	if ([d respondsToSelector:@selector(swizzle)]) {
		MTLTextureSwizzleChannels sw = d.swizzle;
		_swz[0] = (uint8_t)sw.red; _swz[1] = (uint8_t)sw.green; _swz[2] = (uint8_t)sw.blue; _swz[3] = (uint8_t)sw.alpha;
		if (_swz[0] != 2 || _swz[1] != 3 || _swz[2] != 4 || _swz[3] != 5) { static int nl; if (nl++ < 8) slog("SweetMTL: astc swizzle pf%lu %lux%lu: %u%u%u%u", (unsigned long)_pixelFormat, (unsigned long)_width, (unsigned long)_height, _swz[0], _swz[1], _swz[2], _swz[3]); }
	}
	_bytesPerRow = (_width * sm_pf_bpp(_pixelFormat) + 63) & ~(NSUInteger)63;  /* Mali linear planes need a 64-byte aligned row stride (run34: 776 faulted) */
	NSUInteger rows = _height;
	uint32_t abh = 0, abw = sm_astc(_pixelFormat, &abh, NULL);
	if (abw) { static int nl; if (nl++ < 8) slog("SweetMTL: astc create %lux%lu pf%lu mips %lu storage %lu usage %lu", (unsigned long)_width, (unsigned long)_height,
	    (unsigned long)_pixelFormat, (unsigned long)d.mipmapLevelCount, (unsigned long)d.storageMode, (unsigned long)d.usage); }
	if (abw) {
		/* ASTC is decoded on the CPU at upload (the GPU ASTC path gave the magenta error colour in every layout,
		 * runs 80-86) into BGRA8, downscaled by _dec so the copy stays <= 8 MiB (4096x4096 -> 1024x1024) */
		_dec = 1;
		while (((_width + _dec - 1) / _dec) * ((_height + _dec - 1) / _dec) * 4 > (8u << 20)) _dec <<= 1;
		_gw = (_width + _dec - 1) / _dec; _gh = (_height + _dec - 1) / _dec;
		_bytesPerRow = (_gw * 4 + 63) & ~(NSUInteger)63;
		rows = _gh;
	}
	if (!sm_bo_alloc(&_store, _bytesPerRow * rows)) {
		static int nl; if (nl++ < 6) slog("SweetMTL: texture bo alloc failed %lux%lu fmt %lu", (unsigned long)_width, (unsigned long)_height, (unsigned long)_pixelFormat);
		return nil;
	}
	_bo = &_store;
	return self;
}
- (instancetype)initWithDevice:(id)dev descriptor:(MTLTextureDescriptor *)d iosurface:(IOSurfaceRef)ios plane:(NSUInteger)plane
{
	self = [super init];
	_device = dev; _pixelFormat = d.pixelFormat;
	_width = IOSurfaceGetWidthOfPlane(ios, plane) ?: IOSurfaceGetWidth(ios);
	_height = IOSurfaceGetHeightOfPlane(ios, plane) ?: IOSurfaceGetHeight(ios);
	_bytesPerRow = IOSurfaceGetBytesPerRowOfPlane(ios, plane) ?: IOSurfaceGetBytesPerRow(ios);
	void *base = IOSurfaceGetBaseAddressOfPlane(ios, plane) ?: IOSurfaceGetBaseAddress(ios);
	if (!base) return nil;
	if (_bytesPerRow & 63) {
		/* unaligned pitch (230x186 RG8 at 480 bytes bus-faulted the lock screen pass, run55): sample an aligned
		 * copy refreshed before every draw instead of the surface itself */
		NSUInteger abpr = (_width * sm_pf_bpp(_pixelFormat) + 63) & ~(NSUInteger)63;
		if (!sm_bo_alloc(&_shadow, abpr * (_height ? _height : 1))) return nil;
		_hasShadow = true; _src = base; _srcBpr = _bytesPerRow; _wbOK = -1;
		_store = _shadow; _bytesPerRow = abpr;
		[self sm_sync];
	} else if (!sm_bo_import(&_store, base, (uint64_t)_bytesPerRow * _height)) return nil;
	_surface = ios; CFRetain(ios);
	_bo = &_store;
	static int nl; if (nl++ < (sm_is_poster(getprogname()) ? 16 : 8)) slog("SweetMTL: iosurface %u %lux%lu bpr %lu fmt %lu -> gpu %llx", IOSurfaceGetID(ios),
	    (unsigned long)_width, (unsigned long)_height, (unsigned long)_bytesPerRow, (unsigned long)_pixelFormat, _store.gpu);
	return self;
}
- (void)dealloc { if (_hasShadow) sm_bo_free(&_shadow); else if (!_view) sm_bo_free(&_store); if (_surface) CFRelease(_surface); if (_lazyDl) _lazyDl((void *)_lazy, _lazyLen); }
- (IOSurfaceRef)iosurface { return _surface; }
- (NSUInteger)iosurfacePlane { return 0; }
- (MTLStorageMode)storageMode { return MTLStorageModeShared; }
- (MTLTextureUsage)usage { return MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget; }
- (uint32_t)maliFormat
{
	bool srgb = false;
	if (sm_astc(_pixelFormat, NULL, &srgb))   /* decoded on the CPU into BGRA8 */
		return (MALI_RGBA8_UNORM << 12) | MALI_RGB_COMPONENT_ORDER_BGRA;
	uint32_t f; sm_pf_info(_pixelFormat, &f, NULL); return f;
}
- (uint32_t)maliSwizzle { uint32_t w; sm_pf_info(_pixelFormat, NULL, &w); return w; }
- (uint32_t)bpp { return sm_pf_bpp(_pixelFormat); }
- (NSUInteger)depth { return 1; }
- (NSUInteger)mipmapLevelCount { return 1; }
- (NSUInteger)sampleCount { return 1; }
- (NSUInteger)arrayLength { return 1; }
- (MTLTextureType)textureType { return MTLTextureType2D; }
- (BOOL)sm_inRegion:(MTLRegion)r level:(NSUInteger)lvl
{
	return lvl == 0 && r.origin.x + r.size.width <= _width && r.origin.y + r.size.height <= _height && _store.cpu;
}
- (void)replaceRegion:(MTLRegion)r mipmapLevel:(NSUInteger)lvl slice:(NSUInteger)sl withBytes:(const void *)src bytesPerRow:(NSUInteger)bpr bytesPerImage:(NSUInteger)bpi
{
	if (sl == 0) [self replaceRegion:r mipmapLevel:lvl withBytes:src bytesPerRow:bpr];
}
- (void)getBytes:(void *)dst bytesPerRow:(NSUInteger)bpr bytesPerImage:(NSUInteger)bpi fromRegion:(MTLRegion)r mipmapLevel:(NSUInteger)lvl slice:(NSUInteger)sl
{
	if (sl == 0) [self getBytes:dst bytesPerRow:bpr fromRegion:r mipmapLevel:lvl];
}
- (uint8_t *)sm_cpu { _cpuDirty = true; return _store.cpu; }
- (void)getBytes:(void *)dst bytesPerRow:(NSUInteger)bpr fromRegion:(MTLRegion)r mipmapLevel:(NSUInteger)lvl
{
	if (_surface && _store.gpu) sm_flush_now(_store.gpu, (uint64_t)_bytesPerRow * _height);
	{
		static int nl;
		if (nl++ < 6) {
			uint32_t c = 0; if (_store.cpu) memcpy(&c, _store.cpu + (_height / 2) * _bytesPerRow + (_width / 2) * 4, 4);
			slog("SweetMTL: getBytes %lux%lu pf%lu region %lux%lu mid %08x", (unsigned long)_width, (unsigned long)_height, (unsigned long)_pixelFormat,
			    (unsigned long)r.size.width, (unsigned long)r.size.height, c);
			/* the poster's snapshot image: one thumbnail of what the GPU produced (RGBA order, shown channel-swapped) */
			static bool th;
			if (!th && sm_is_poster(getprogname()) && _width >= 512 && sm_pf_bpp(_pixelFormat) == 4 && _store.cpu) { th = true; sm_thumb(_store.cpu, (uint32_t)_width, (uint32_t)_height, (uint32_t)_bytesPerRow, 31); }
		}
	}
	if (![self sm_inRegion:r level:lvl]) return;
	for (NSUInteger y = 0; y < r.size.height; y++)
		memcpy((uint8_t *)dst + y * bpr, _store.cpu + (r.origin.y + y) * _bytesPerRow + r.origin.x * sm_pf_bpp(_pixelFormat), r.size.width * sm_pf_bpp(_pixelFormat));
}
- (void)replaceRegion:(MTLRegion)r mipmapLevel:(NSUInteger)lvl withBytes:(const void *)src bytesPerRow:(NSUInteger)bpr
{
	_cpuDirty = true;
	if (src && !sm_astc(_pixelFormat, NULL, NULL) && r.origin.x == 0 && r.origin.y == 0 && r.size.width == _width && r.size.height == _height) {
		/* whole-image upload: remember whether it carried any content (sampled every 7th byte of every 4th row) */
		const uint8_t *c = src; bool any = false; NSUInteger rb = r.size.width * sm_pf_bpp(_pixelFormat);
		for (NSUInteger y = 0; y < r.size.height && !any; y += 4) for (NSUInteger x = 0; x < rb; x += 7) if (c[y * bpr + x]) { any = true; break; }
		_allZero = !any;
		if (!any && r.size.width >= 1000) { static int nb; if (nb++ < 2) { slog("SweetMTL: empty upload %lux%lu pf%lu bt:", (unsigned long)r.size.width, (unsigned long)r.size.height, (unsigned long)_pixelFormat); sm_region_info(src); sm_find_sharers(src, r.size.width == 1105 ? "img1105" : "img1271"); } }
	} else if (src) _allZero = false;
	if (r.size.width >= 300 && src && !sm_astc(_pixelFormat, NULL, NULL)) {
		uint64_t nz = 0, nn = 0; const uint8_t *c = src;
		for (NSUInteger y = 0; y < r.size.height; y += r.size.height / 16 + 1) for (NSUInteger x = 0; x < r.size.width * sm_pf_bpp(_pixelFormat); x += 61) { nn++; if (c[y * bpr + x]) nz++; }
		static int nl; if (nl++ < 12) slog("SweetMTL: upload %lux%lu pf%lu bpr %lu nonzero %llu/%llu", (unsigned long)r.size.width, (unsigned long)r.size.height, (unsigned long)_pixelFormat, (unsigned long)bpr, nz, nn);
	}
	if (sm_astc(_pixelFormat, NULL, NULL) && lvl == 0 && ![self sm_inRegion:r level:lvl]) { static int nl; if (nl++ < 4) slog("SweetMTL: astc upload rejected %lux%lu", (unsigned long)r.size.width, (unsigned long)r.size.height); }
	if (![self sm_inRegion:r level:lvl] || !src) return;
	uint32_t abh = 0, abw = sm_astc(_pixelFormat, &abh, NULL);
	if (abw) {
		static int nl; if (nl++ < 8) { uint64_t b0 = 0; memcpy(&b0, src, 8);
		    slog("SweetMTL: astc upload %lux%lu at %lu,%lu bpr %lu src %016llx store %p", (unsigned long)r.size.width, (unsigned long)r.size.height,
		    (unsigned long)r.origin.x, (unsigned long)r.origin.y, (unsigned long)bpr, b0, _store.cpu); }
		NSUInteger bx = r.origin.x / abw, by = r.origin.y / abh, nbx = (r.size.width + abw - 1) / abw, nby = (r.size.height + abh - 1) / abh;
		uint32_t px[144]; NSUInteger nerr = 0, ntot = 0, ex = 0, ey = 0;
		bool ident = (_swz[0] == 2 && _swz[1] == 3 && _swz[2] == 4 && _swz[3] == 5) || !(_swz[0] | _swz[1] | _swz[2] | _swz[3]);
		for (NSUInteger y = 0; y < nby; y++) {
			const uint8_t *row = (const uint8_t *)src + y * bpr;
			for (NSUInteger x = 0; x < nbx; x++) {
				NSUInteger X0 = (bx + x) * abw, Y0 = (by + y) * abh;
				/* only blocks holding a kept (every _dec-th) texel */
				NSUInteger fx = (X0 + _dec - 1) / _dec * _dec, fy = (Y0 + _dec - 1) / _dec * _dec;
				if (fx >= X0 + abw || fy >= Y0 + abh) continue;
				decode_block(row + x * 16, (int)abw, (int)abh, px);
				ntot++;
				if (px[0] == 0xFFFF00FFu && px[abw * abh - 1] == 0xFFFF00FFu) {
					if (!nerr++) { ex = bx + x; ey = by + y; }
					static int nd; if (nd < 6 && (nerr == 1 || nerr == 50 || nerr == 500)) { nd++; const uint64_t *q = (const uint64_t *)(row + x * 16);
					  slog("SweetMTL: astc bad block %lu,%lu: %016llx %016llx", (unsigned long)(bx + x), (unsigned long)(by + y), q[0], q[1]); }
				}
				if (!ident) for (uint32_t q = 0; q < abw * abh; q++) {
					uint32_t v = px[q], ch[6] = { 0, 255, (v >> 16) & 255, (v >> 8) & 255, v & 255, v >> 24 };
					px[q] = (ch[_swz[3] < 6 ? _swz[3] : 5] << 24) | (ch[_swz[0] < 6 ? _swz[0] : 2] << 16) | (ch[_swz[1] < 6 ? _swz[1] : 3] << 8) | ch[_swz[2] < 6 ? _swz[2] : 4];
				}
				for (NSUInteger yy = fy; yy < Y0 + abh && yy < _height; yy += _dec)
					for (NSUInteger xx = fx; xx < X0 + abw && xx < _width; xx += _dec)
						memcpy(_store.cpu + (yy / _dec) * _bytesPerRow + (xx / _dec) * 4, &px[(yy - Y0) * abw + (xx - X0)], 4);
			}
		}
		{
			/* decoded content summary: mean colour and share of near-black texels (sampled grid) */
			uint64_t sr = 0, sg = 0, sb = 0, nd = 0, nn = 0;
			for (NSUInteger y = 0; y < _gh; y += 8) for (NSUInteger x = 0; x < _gw; x += 8) {
				const uint8_t *q = _store.cpu + y * _bytesPerRow + x * 4; sb += q[0]; sg += q[1]; sr += q[2]; nn++; if (q[0] < 16 && q[1] < 16 && q[2] < 16) nd++;
			}
			static int ns; if (nn && ns++ < 12) slog("SweetMTL: astc stats pf%lu %lux%lu (%lux%lu blocks %ux%u): mean rgb %llu %llu %llu, dark %llu%%", (unsigned long)_pixelFormat,
			    (unsigned long)_width, (unsigned long)_height, (unsigned long)nbx, (unsigned long)nby, abw, abh, sr / nn, sg / nn, sb / nn, nd * 100 / nn);
		}
		{ static int nl; if (nerr && nl++ < 6) slog("SweetMTL: astc decode %lux%lu pf%lu: %lu/%lu error blocks, first at block %lu,%lu", (unsigned long)_width, (unsigned long)_height,
		    (unsigned long)_pixelFormat, (unsigned long)nerr, (unsigned long)ntot, (unsigned long)ex, (unsigned long)ey); }
		return;
	}
	for (NSUInteger y = 0; y < r.size.height; y++)
		memcpy(_store.cpu + (r.origin.y + y) * _bytesPerRow + r.origin.x * sm_pf_bpp(_pixelFormat), (const uint8_t *)src + y * bpr, r.size.width * sm_pf_bpp(_pixelFormat));
}
@end

@interface SweetMTLRenderPipelineState : SweetMTLObject
@property (nonatomic, copy) NSString *vsName, *fsName;
@property (nonatomic) const sm_shader *vs, *fs;
@end
@implementation SweetMTLRenderPipelineState {
@public
	struct { uint32_t fmt, off, bidx; } _attr[16];
	uint32_t _stride[31];
	uint32_t _fc[64]; uint64_t _fcdef;
	uint32_t _blend[8];
}
@end

@interface SweetMTLSampler : SweetMTLObject
@property (nonatomic) uint32_t nearest;
@property (nonatomic) uint32_t wrap;   /* Mali wrap modes s | t << 8 | r << 16 | border white << 24 (0 = clamp to edge) */
@end
@implementation SweetMTLSampler
@end

@interface SweetMTLCommandBuffer : SweetMTLObject
@property (nonatomic, strong) NSMutableArray *passes;
@property (nonatomic) NSUInteger status;
@property (nonatomic) uint32_t lastJobStatus;
@property (nonatomic, weak) id commandQueue;
@property (nonatomic, strong) NSMutableArray *scheduled, *completed, *toPresent;
@end

@interface SweetMTLRenderEncoder : SweetMTLObject
@property (nonatomic, strong) SweetMTLTexture *target;
@property (nonatomic) BOOL clear;
@property (nonatomic) BOOL load;
@property (nonatomic) uint32_t packed;
@property (nonatomic, strong) SweetMTLRenderPipelineState *pipeline;
@property (nonatomic, strong) NSMutableArray *keep;     /* buffers referenced by recorded draws */
@end
@implementation SweetMTLRenderEncoder {
@public
	uint64_t _buf[31];
	__unsafe_unretained SweetMTLTexture *_tex[8];
	__unsafe_unretained SweetMTLSampler *_smp[8];
	sm_drawrec _draws[32];
	uint32_t _ndraw, _skipped;
	uint64_t _bufBase[31];
	uint64_t _fbuf[31], _fbufBase[31];
	MTLScissorRect _scissor;
	BOOL _hasScissor;
}
- (instancetype)init { self = [super init]; _keep = [NSMutableArray array]; return self; }
- (void)endEncoding {}
- (void)setRenderPipelineState:(id)ps { _pipeline = ps; }
- (void)setViewport:(MTLViewport)vp {}
- (void)setCullMode:(MTLCullMode)m {}
- (void)setFrontFacingWinding:(MTLWinding)w {}
- (void)setVertexBuffer:(id)buf offset:(NSUInteger)off atIndex:(NSUInteger)i
{
	if (i < 31) { _bufBase[i] = buf ? [(SweetMTLBuffer *)buf gpuAddress] : 0; _buf[i] = buf ? _bufBase[i] + off : 0; if (buf) [_keep addObject:buf]; }
}
- (void)setVertexBytes:(const void *)p length:(NSUInteger)len atIndex:(NSUInteger)i
{
	uint64_t va = sm_ring_put(p, len, NULL);
	if (i < 31) { _bufBase[i] = 0; _buf[i] = va; }
}
- (void)setFragmentTexture:(id)t atIndex:(NSUInteger)i
{
	if (sm_is_poster(getprogname())) { static int nl; if (nl++ < 24) slog("SweetMTL: poster tex set %lu <- %s %lux%lu pf%lu", (unsigned long)i, t ? object_getClassName(t) : "nil",
	    t ? (unsigned long)[t width] : 0, t ? (unsigned long)[t height] : 0, t ? (unsigned long)[t pixelFormat] : 0); }
	if (i < 8) { _tex[i] = t; if (t) [_keep addObject:t]; }
}
- (void)setFragmentTextures:(id const *)ts withRange:(NSRange)r
{
	for (NSUInteger k = 0; k < r.length; k++) [self setFragmentTexture:ts ? ts[k] : nil atIndex:r.location + k];
}
- (void)setFragmentSamplerStates:(id const *)ss withRange:(NSRange)r
{
	for (NSUInteger k = 0; k < r.length; k++) [self setFragmentSamplerState:ss ? ss[k] : nil atIndex:r.location + k];
}
- (void)setFragmentSamplerState:(id)smp atIndex:(NSUInteger)i
{
	if (i < 8) { _smp[i] = smp; if (smp) [_keep addObject:smp]; }
}
- (void)setFragmentBuffer:(id)buf offset:(NSUInteger)off atIndex:(NSUInteger)i
{
	if (i < 31) { _fbufBase[i] = buf ? [(SweetMTLBuffer *)buf gpuAddress] : 0; _fbuf[i] = buf ? _fbufBase[i] + off : 0; if (buf) [_keep addObject:buf]; }
}
- (void)setVertexBufferOffset:(NSUInteger)off atIndex:(NSUInteger)i { if (i < 31 && _bufBase[i]) _buf[i] = _bufBase[i] + off; }
- (void)setFragmentBufferOffset:(NSUInteger)off atIndex:(NSUInteger)i { if (i < 31 && _fbufBase[i]) _fbuf[i] = _fbufBase[i] + off; }
- (void)setFragmentBytes:(const void *)p length:(NSUInteger)len atIndex:(NSUInteger)i
{
	uint64_t va = sm_ring_put(p, len, NULL);
	if (i < 31) { _fbufBase[i] = 0; _fbuf[i] = va; }
}
- (void)setScissorRect:(MTLScissorRect)sr
{
	_scissor = sr; _hasScissor = YES;
}
- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count instanceCount:(NSUInteger)ic
{
	if (ic == 1) [self drawPrimitives:type vertexStart:start vertexCount:count];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)type indexCount:(NSUInteger)count indexType:(MTLIndexType)it indexBuffer:(id)ib indexBufferOffset:(NSUInteger)off
{
	sm_drawrec *r = [self sm_record:type];
	if (!r) return;
	r->vcount = (uint32_t)count;
	r->index_type = it == MTLIndexTypeUInt16 ? 2 : 3;
	r->index_va = (uint64_t)[ib gpuAddress] + off;
	if (ib) [_keep addObject:ib];
	r->base_vertex = 0;
	_ndraw++;
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)type indexCount:(NSUInteger)count indexType:(MTLIndexType)it indexBuffer:(id)ib indexBufferOffset:(NSUInteger)off instanceCount:(NSUInteger)ic
{
	if (ic == 1) [self drawIndexedPrimitives:type indexCount:count indexType:it indexBuffer:ib indexBufferOffset:off];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)type indexCount:(NSUInteger)count indexType:(MTLIndexType)it indexBuffer:(id)ib indexBufferOffset:(NSUInteger)off instanceCount:(NSUInteger)ic baseVertex:(NSInteger)bv baseInstance:(NSUInteger)bi
{
	if (ic != 1) return;
	[self drawIndexedPrimitives:type indexCount:count indexType:it indexBuffer:ib indexBufferOffset:off];
	if (_ndraw && _draws[_ndraw - 1].index_va) _draws[_ndraw - 1].base_vertex = (int32_t)bv;
}
- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count
{
	sm_drawrec *r = [self sm_record:type];
	if (!r) return;
	r->vcount = (uint32_t)count; r->vstart = (uint32_t)start;
	_ndraw++;
}
- (sm_drawrec *)sm_record:(MTLPrimitiveType)type
{
	if (type != MTLPrimitiveTypeTriangle && type != MTLPrimitiveTypeTriangleStrip) {
		static int nl; if (nl++ < 4) slog("SweetMTL: draw type %lu not supported yet", (unsigned long)type);
		return NULL;
	}
	if (_ndraw >= 32) { static int nl; if (nl++ < 4) slog("SweetMTL: too many draws in one pass"); return NULL; }
	sm_drawrec *r = &_draws[_ndraw];
	memset(r, 0, sizeof *r);
	r->strip = type == MTLPrimitiveTypeTriangleStrip;
	if (_hasScissor && _target) {
		uint32_t W = (uint32_t)_target.width, H = (uint32_t)_target.height;
		uint32_t x0 = (uint32_t)_scissor.x, y0 = (uint32_t)_scissor.y;
		uint32_t x1 = (uint32_t)(_scissor.x + _scissor.width), y1 = (uint32_t)(_scissor.y + _scissor.height);
		if (x1 > W) x1 = W;
		if (y1 > H) y1 = H;
		if (x0 >= x1 || y0 >= y1) return NULL;  /* empty scissor: nothing to draw */
		r->has_scissor = 1; r->sc_x0 = x0; r->sc_y0 = y0; r->sc_x1 = x1 - 1; r->sc_y1 = y1 - 1;
	}
	if (_pipeline.fs && _pipeline.fs->bad) { _skipped++; return NULL; }
	static int skipz = -1; if (skipz < 0) { char ba[1024] = {0}; size_t bl = sizeof(ba) - 1; skipz = sysctlbyname("kern.bootargs", ba, &bl, NULL, 0) == 0 && strstr(ba, "sweetskipempty=0") ? 0 : 1; }   /* default on: source not found (runs 130-141) */
	if (skipz && _pipeline.fs && strstr(_pipeline.fs->name, "Ixrg")) {
		/* opaque-image draw (alpha ignored) of a texture whose content never arrived (all-zero upload): it would paint a solid
		 * black rectangle over the home screen wallpaper (run128 bisect). Skip it until the content source is fixed. */
		for (uint32_t k = 0; k < 8; k++) {
			SweetMTLTexture *t = _tex[k];
			if (t && [t isKindOfClass:[SweetMTLTexture class]] && [t sm_allZero]) {
				static int nl; if (nl++ < 4) slog("SweetMTL: skipped empty opaque image %lux%lu (%s)", (unsigned long)t.width, (unsigned long)t.height, _pipeline.fs->name);
				_skipped++; return NULL;
			}
		}
	}
	{
		/* run124 experiment: skip the backdrop colour-matrix draws (TimgBvcm*, TimgBdso*): suspected to paint the black
		 * rectangle over the home screen wallpaper. Boot-arg sweetbvcm=1 keeps them. */
		static int keep = -1; if (keep < 0) { char ba[1024] = {0}; size_t bl = sizeof(ba) - 1; keep = sysctlbyname("kern.bootargs", ba, &bl, NULL, 0) == 0 && strstr(ba, "sweetbvcm=0") ? 0 : 1; }
		const char *fn = _pipeline.fs ? _pipeline.fs->name : "";
		if (!keep && (strstr(fn, "Bvcm") || strstr(fn, "Bdso"))) {
			static int nl; if (nl++ < 4) slog("SweetMTL: skipped backdrop draw %s (%u vertices)", fn, (unsigned)0);
			_skipped++; return NULL;
		}
	}
	r->vs = _pipeline.vs; r->fs = _pipeline.fs; r->wmask = 0xF;
	memcpy(r->buf, _buf, sizeof _buf);
	memcpy(r->fbuf, _fbuf, sizeof _fbuf);
	if (_pipeline) {
		for (int k = 0; k < 16; k++) { r->attr[k].fmt = _pipeline->_attr[k].fmt; r->attr[k].off = _pipeline->_attr[k].off; r->attr[k].bidx = _pipeline->_attr[k].bidx; }
		memcpy(r->stride, _pipeline->_stride, sizeof r->stride);
		memcpy(r->fc, _pipeline->_fc, sizeof r->fc); r->fc_defined = _pipeline->_fcdef;
		r->blend_on = _pipeline->_blend[0]; r->rgb_op = _pipeline->_blend[1]; r->a_op = _pipeline->_blend[2];
		r->rgb_sf = _pipeline->_blend[3]; r->rgb_df = _pipeline->_blend[4]; r->a_sf = _pipeline->_blend[5]; r->a_df = _pipeline->_blend[6];
		r->wmask = _pipeline->_blend[7];
	}
	for (uint32_t k = 0; k < 8; k++) {
		SweetMTLTexture *t = _tex[k];
		if (t && ![t isKindOfClass:[SweetMTLTexture class]]) {
			static int nl; if (nl++ < 4) slog("SweetMTL: texture slot %u holds a %s, skipped", k, object_getClassName(t));
			t = nil;
		}
		if (t) {
			[t sm_sync];
			r->tex[k].va = t.bo->gpu; r->tex[k].w = (uint32_t)[t gpuWidth]; r->tex[k].h = (uint32_t)[t gpuHeight];
			r->tex[k].stride = (uint32_t)t.bytesPerRow; r->tex[k].fmt = [t maliFormat];
			r->tex[k].pf = (uint32_t)t.pixelFormat; r->tex[k].imp = t.bo->imported;
			r->tex[k].swz = [t maliSwizzle];
			r->tex[k].nofl = [t sm_noflush];
			{ uint32_t bh = 0; bool sr = false; uint32_t bw = sm_astc(t.pixelFormat, &bh, &sr); r->tex[k].astc = 0; (void)sr;   /* ASTC is decoded on the CPU */
			  if (bw) { static int nl; if (nl++ < 6) { uint64_t b0 = 0, b1 = 0; if (t.bo->cpu) { memcpy(&b0, t.bo->cpu, 8); memcpy(&b1, t.bo->cpu + 4096, 8); }
			    slog("SweetMTL: astc draw tex%u pf%lu va %llx cpu %p blk0 %016llx blk256 %016llx", k, (unsigned long)t.pixelFormat, t.bo->gpu, t.bo->cpu, b0, b1); } } }
			r->ntex = k + 1;
			{
				int slot = r->tex[k].w == 1105 ? 0 : r->tex[k].w == 563 ? 1 : r->tex[k].w == 650 ? 2 : -1;
				if (slot >= 0 && !sm_dbg_tex[slot]) sm_dbg_tex[slot] = t;
			}
			if (sm_describe > 0 && t.bo->cpu && sm_pf_bpp(t.pixelFormat) == 4 && r->tex[k].w >= 300) {
				/* content summary of the bound texture (CPU view): which layer inputs are black */
				const uint8_t *c = t.bo->cpu; uint64_t s0 = 0, s1 = 0, s2 = 0, s3 = 0, nd = 0, nn = 0; uint32_t W = r->tex[k].w, H = r->tex[k].h, bpr = r->tex[k].stride;
				for (uint32_t y = 0; y < H; y += H / 16 + 1) for (uint32_t x = 0; x < W; x += W / 16 + 1) { const uint8_t *q = c + (uint64_t)y * bpr + x * 4; s0 += q[0]; s1 += q[1]; s2 += q[2]; s3 += q[3]; nn++; if (q[0] < 8 && q[1] < 8 && q[2] < 8) nd++; }
				static int ns; if (nn && ns++ < 40) slog("SweetMTL:  tstat %ux%u pf%lu%s%s: mean %llu %llu %llu a%llu dark %llu%%", W, H, (unsigned long)t.pixelFormat, t.bo->imported ? " imp" : "",
				    [t sm_isShadowed] ? " shadow" : "", s0 / nn, s1 / nn, s2 / nn, s3 / nn, nd * 100 / nn);
			}
			if (sm_describe > 0) { static int nl; if (nl++ < 60) slog("SweetMTL:  rt%u draw%u %ux%u pf%lu%s fs %.40s", k, _ndraw, r->tex[k].w, r->tex[k].h,
			    (unsigned long)t.pixelFormat, t.bo->imported ? " imp" : "", _pipeline.fs ? _pipeline.fs->name + (strncmp(_pipeline.fs->name, "com.apple.coreanimation.frag.", 29) ? 0 : 29) : "-"); }
		}
		if (_smp[k]) { r->smp[k].nearest = _smp[k].nearest; r->smp[k].wrap = _smp[k].wrap; r->nsmp = k + 1; }
	}
	return r;
}
@end

/* blit/compute encoders: accepted and dropped for now (logged once per selector by the base) */
@interface SweetMTLStubEncoder : SweetMTLObject
@end
@implementation SweetMTLStubEncoder
- (void)endEncoding {}
@end
/* Compute (phase 1: record and describe; GPU dispatch comes next) */
@interface SweetMTLComputePipelineState : SweetMTLObject
@property (nonatomic, copy) NSString *fnName;
@property (nonatomic) const sm_shader *cs;
@end
@implementation SweetMTLComputePipelineState
- (NSUInteger)maxTotalThreadsPerThreadgroup { return 256; }
- (NSUInteger)threadExecutionWidth { return 16; }
- (NSUInteger)staticThreadgroupMemoryLength { return 0; }
@end
@interface SweetMTLComputeEncoder : SweetMTLObject
- (void)sm_run;
@end
/* One recorded dispatch: everything the job needs, snapshotted because the encoder state changes between dispatches */
typedef struct {
	const sm_shader *cs; char name[48];
	uint32_t wg[3], cnt[3];
	uint64_t buf[8];
	struct { uint64_t va; uint32_t w, h, stride, fmt, swz, pf; } tex[4];
	uint32_t ntex;
} sm_dispatch;
@implementation SweetMTLComputeEncoder {
	SweetMTLComputePipelineState *_ps;
	__unsafe_unretained SweetMTLTexture *_tex[4];
	uint64_t _buf[8];
	sm_dispatch _d[16]; uint32_t _nd;
	NSMutableArray *_keep;
}
- (instancetype)init { self = [super init]; _keep = [NSMutableArray array]; return self; }
- (void)endEncoding {}
- (void)setComputePipelineState:(id)ps { _ps = [ps isKindOfClass:[SweetMTLComputePipelineState class]] ? ps : nil; if (ps) [_keep addObject:ps]; }
- (void)setTexture:(id)t atIndex:(NSUInteger)i
{
	if (i < 4) { _tex[i] = [t isKindOfClass:[SweetMTLTexture class]] ? t : nil; if (t) [_keep addObject:t]; }
}
- (void)setBuffer:(id)b offset:(NSUInteger)o atIndex:(NSUInteger)i
{
	if (i < 8) { _buf[i] = b ? [(SweetMTLBuffer *)b gpuAddress] + o : 0; if (b) [_keep addObject:b]; }
}
- (void)setBytes:(const void *)p length:(NSUInteger)n atIndex:(NSUInteger)i { if (i < 8) _buf[i] = sm_ring_put(p, n, NULL); }
- (void)setSamplerState:(id)s atIndex:(NSUInteger)i {}
- (void)sm_record:(MTLSize)cnt tg:(MTLSize)t how:(const char *)how
{
	static int nl;
	if (nl++ < 12) slog("SweetMTL: compute %s %s count %lux%lux%lu tg %lux%lux%lu", how, _ps ? _ps.fnName.UTF8String : "?",
	    (unsigned long)cnt.width, (unsigned long)cnt.height, (unsigned long)cnt.depth, (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.depth);
	{
		static int nt;
		if (nt++ < 6) for (uint32_t k = 0; k < 2; k++) if (_tex[k]) slog("SweetMTL: compute tex%u %lux%lu pf%lu%s", k, (unsigned long)_tex[k].width,
		    (unsigned long)_tex[k].height, (unsigned long)_tex[k].pixelFormat, _tex[k].iosurface ? " ios" : "");
	}
	if (!_ps || !_ps.cs || _nd >= 16) return;
	sm_dispatch *d = &_d[_nd++];
	memset(d, 0, sizeof *d);
	d->cs = _ps.cs; strlcpy(d->name, _ps.fnName.UTF8String, sizeof d->name);
	d->wg[0] = (uint32_t)t.width; d->wg[1] = (uint32_t)t.height; d->wg[2] = (uint32_t)(t.depth ? t.depth : 1);
	d->cnt[0] = (uint32_t)cnt.width; d->cnt[1] = (uint32_t)cnt.height; d->cnt[2] = (uint32_t)(cnt.depth ? cnt.depth : 1);
	memcpy(d->buf, _buf, sizeof d->buf);
	for (uint32_t k = 0; k < 4; k++) {
		SweetMTLTexture *tx = _tex[k];
		if (!tx || !tx.bo) continue;
		[tx sm_sync];
		d->tex[k].va = tx.bo->gpu; d->tex[k].w = (uint32_t)tx.width; d->tex[k].h = (uint32_t)tx.height;
		d->tex[k].stride = (uint32_t)tx.bytesPerRow; d->tex[k].fmt = [tx maliFormat]; d->tex[k].swz = [tx maliSwizzle];
		d->tex[k].pf = (uint32_t)tx.pixelFormat; d->ntex = k + 1;
	}
}
- (void)dispatchThreadgroups:(MTLSize)g threadsPerThreadgroup:(MTLSize)t { [self sm_record:g tg:t how:"groups"]; }
- (void)dispatchThreads:(MTLSize)g threadsPerThreadgroup:(MTLSize)t
{
	NSUInteger tw = t.width ? t.width : 1, th = t.height ? t.height : 1, td = t.depth ? t.depth : 1;
	[self sm_record:MTLSizeMake((g.width + tw - 1) / tw, (g.height + th - 1) / th, (g.depth + td - 1) / td) tg:t how:"threads"];
}
/* Valhall COMPUTE_JOB per dispatch (job 0x0, shader 0x200, resources 0x280, TLS 0x300, samplers 0xA00, textures 0xC00,
 * planes 0xD00, push 0xE00, binary 0x1000). Texture writes go straight to memory (address/pitch/format in the push
 * block, see air2nir PUSH_CS_*); reads use the texture table. */
- (void)sm_run
{
	static sm_bo cd; static bool have; static sm_bo dummy; static bool hd;
	if (!have) { have = sm_bo_alloc(&cd, 0x10000); if (have) sm_always_add(&cd); }
	if (!hd) { hd = sm_bo_alloc(&dummy, 0x10000); if (hd) sm_infra_add(&dummy); }
	if (!have || !hd) return;
	for (uint32_t n = 0; n < _nd; n++) {
		const sm_dispatch *d = &_d[n];
		const sm_shader *cs = d->cs;
		if (cs->size > 0xE000 || cs->cdata_size > 0x200) continue;
		/* compute may write any bound buffer or texture: all of them are cleaned+invalidated after the job */
		sm_jl_begin(0);
		for (int k = 0; k < (int)(sizeof d->buf / sizeof d->buf[0]); k++) sm_jl_write(d->buf[k]);
		for (uint32_t k = 0; k < d->ntex && k < 4; k++) sm_jl_write(d->tex[k].va);
		uint8_t *P = cd.cpu; uint64_t PV = cd.gpu;
		memset(P, 0, 0x1000);
		memcpy(P + 0x1000, cs->bin, cs->size);
		if (cs->cdata_size) memcpy(P + 0x800, cs->cdata, cs->cdata_size);
		sm_shader_desc(P + 0x200, cs, MALI_SHADER_STAGE_COMPUTE, PV + 0x1000, cs->preload, cs->work_regs);
		sm_pack_tls(P + 0x300, cs->flags >> 16);
		for (uint32_t k = 0; k < 16; k++)
			pan_pack(P + 0xA00 + 32 * k, SAMPLER, sc) { sc.minify_nearest = true; sc.magnify_nearest = true; sc.normalized_coordinates = false;
				sc.wrap_mode_s = sc.wrap_mode_t = sc.wrap_mode_r = MALI_WRAP_MODE_CLAMP_TO_EDGE; }
		for (uint32_t k = 0; k < 8; k++) {
			bool real = k < d->ntex && d->tex[k].va;
			uint64_t va = real ? d->tex[k].va : dummy.gpu;
			uint32_t tw = real ? d->tex[k].w : 16, th = real ? d->tex[k].h : 16, ts = real ? d->tex[k].stride : 64;
			pan_pack(P + 0xD00 + 32 * k, PLANE, pl) {
				pl.plane_type = MALI_PLANE_TYPE_GENERIC; pl.clump_format = real ? sm_clump(d->tex[k].pf) : MALI_CLUMP_FORMAT_RAW32; pl.clump_ordering = MALI_CLUMP_ORDERING_LINEAR;
				pl.pointer = va; pl.row_stride = ts; pl.size = real ? ts * th : 0x10000; pl.slice_stride = ts * th;
			}
			pan_pack(P + 0xC00 + 32 * k, TEXTURE, tx) {
				tx.dimension = MALI_TEXTURE_DIMENSION_2D;
				tx.format = real ? d->tex[k].fmt : ((MALI_RGBA8_UNORM << 12) | MALI_RGB_COMPONENT_ORDER_RGBA);
				tx.width = tw; tx.height = th; tx.sample_count = 1;
				tx.swizzle = real ? d->tex[k].swz : (0 | (1 << 3) | (2 << 6) | (3 << 9));
				tx.levels = 1; tx.array_size = 1; tx.surfaces = PV + 0xD00 + 32 * k;
			}
		}
		pan_pack(P + 0x280 + 3 * 16, RESOURCE, rc) { rc.address = PV + 0xA00; rc.size = 16 * 32; }
		pan_pack(P + 0x280 + 4 * 16, RESOURCE, rc) { rc.address = PV + 0xC00; rc.size = 8 * 32; }
		uint8_t *push = P + 0xE00;
		for (int k = 0; k < 8; k++) { uint64_t v = d->buf[k] ? d->buf[k] : dummy.gpu; memcpy(push + SMP_BUF + 8 * k, &v, 8); }
		uint64_t cdv = PV + 0x800, dv = dummy.gpu;
		memcpy(push + SMP_CDATA_VS, &cdv, 8); memcpy(push + SMP_CDATA_FS, &cdv, 8); memcpy(push + SMP_DUMMY, &dv, 8);
		memcpy(push + 448, d->wg, 12);
		for (uint32_t k = 0; k < 4; k++) { uint32_t sz = d->tex[k].w | (d->tex[k].h << 16); memcpy(push + 464 + 4 * k, &sz, 4); }
		for (uint32_t k = 0; k < 2; k++) {
			uint64_t va = d->tex[k].va ? d->tex[k].va : dummy.gpu; uint32_t st = d->tex[k].stride, f = sm_is_bgra(d->tex[k].pf) ? 1 : 0;
			memcpy(push + 480 + 16 * k, &va, 8); memcpy(push + 488 + 16 * k, &st, 4); memcpy(push + 492 + 16 * k, &f, 4);
		}
		pan_section_pack(P, COMPUTE_JOB, PAYLOAD, cfg) {
			cfg.workgroup_size_x = d->wg[0]; cfg.workgroup_size_y = d->wg[1]; cfg.workgroup_size_z = d->wg[2];
			cfg.workgroup_count_x = d->cnt[0]; cfg.workgroup_count_y = d->cnt[1]; cfg.workgroup_count_z = d->cnt[2];
			cfg.allow_merging_workgroups = false; cfg.task_increment = 1; cfg.task_axis = MALI_TASK_AXIS_Z;
			cfg.compute.shader = PV + 0x200; cfg.compute.thread_storage = PV + 0x300;
			cfg.compute.resources = (PV + 0x280) | 6; cfg.compute.fau = PV + 0xE00;
			cfg.compute.fau_count = (cs->push_words + 1) / 2 ? (cs->push_words + 1) / 2 : 1;
		}
		pan_section_pack(P, COMPUTE_JOB, HEADER, h) { h.type = MALI_JOB_TYPE_COMPUTE; h.index = 1; }
		uint32_t st = sm_submit(1, PV);
		static int nl; if (st || nl++ < 6) slog("SweetMTL: compute run %s %ux%u groups of %ux%u -> %x", d->name, d->cnt[0], d->cnt[1], d->wg[0], d->wg[1], st);
	}
	if (_nd) for (uint32_t k = 0; k < 4; k++) if (_tex[k]) [_tex[k] sm_writeback];   /* compute may write any bound texture */
	_nd = 0;
}
@end

/* Blits are CPU copies. They are queued in the command buffer and run at commit, in order with the GPU passes:
 * running them at encode time read render targets before the passes that draw them had run (black copies). */
@interface SweetMTLBlitEncoder : SweetMTLStubEncoder
- (void)sm_run;
@end
@implementation SweetMTLBlitEncoder { NSMutableArray *_ops; }
- (void)sm_add:(dispatch_block_t)op { if (!_ops) _ops = [NSMutableArray array]; [_ops addObject:[op copy]]; }
- (void)sm_run { NSArray *ops = _ops; _ops = nil; for (dispatch_block_t op in ops) op(); }
- (void)copyFromTexture:(id)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)sz
    toTexture:(id)dst destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)dO
{
	[self sm_add:^{ [self sm_copyTex:src ss:ss sl:sl so:so sz:sz dst:dst ds:ds dl:dl dO:dO]; }];
}
- (void)copyFromBuffer:(id)b sourceOffset:(NSUInteger)so sourceBytesPerRow:(NSUInteger)sbpr sourceBytesPerImage:(NSUInteger)sbpi sourceSize:(MTLSize)sz
    toTexture:(id)t destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)o
{
	{ static int nl; if (nl++ < 6) slog("SweetMTL: blit buffer->tex %lux%lu pf%lu bpr %lu level %lu", (unsigned long)sz.width, (unsigned long)sz.height,
	    (unsigned long)[t pixelFormat], (unsigned long)sbpr, (unsigned long)dl); }
	[self sm_add:^{
		if (ds || dl || ![b respondsToSelector:@selector(contents)] || ![t respondsToSelector:@selector(replaceRegion:mipmapLevel:withBytes:bytesPerRow:)]) return;
		if ([b length] < so + sbpr * (sz.height ? sz.height - 1 : 0)) return;
		[t replaceRegion:MTLRegionMake2D(o.x, o.y, sz.width, sz.height) mipmapLevel:0 withBytes:(const uint8_t *)[b contents] + so bytesPerRow:sbpr];
	}];
}
- (void)copyFromBuffer:(id)b sourceOffset:(NSUInteger)so sourceBytesPerRow:(NSUInteger)sbpr sourceBytesPerImage:(NSUInteger)sbpi sourceSize:(MTLSize)sz
    toTexture:(id)t destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)o options:(NSUInteger)opt
{
	[self copyFromBuffer:b sourceOffset:so sourceBytesPerRow:sbpr sourceBytesPerImage:sbpi sourceSize:sz toTexture:t destinationSlice:ds destinationLevel:dl destinationOrigin:o];
}
- (void)copyFromTexture:(id)t sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)sz
    toBuffer:(id)b destinationOffset:(NSUInteger)dof destinationBytesPerRow:(NSUInteger)dbpr destinationBytesPerImage:(NSUInteger)dbpi
{
	{ static int nl; if (nl++ < 6) slog("SweetMTL: blit tex->buffer %lux%lu pf%lu bpr %lu", (unsigned long)sz.width, (unsigned long)sz.height, (unsigned long)[t pixelFormat], (unsigned long)dbpr); }
	[self sm_add:^{
		if (ss || sl || ![b respondsToSelector:@selector(contents)] || [b length] < dof + dbpr * (sz.height ? sz.height - 1 : 0) + sz.width) return;
		[t getBytes:(uint8_t *)[b contents] + dof bytesPerRow:dbpr fromRegion:MTLRegionMake2D(so.x, so.y, sz.width, sz.height) mipmapLevel:0];
	}];
}
- (void)copyFromTexture:(id)t sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)sz
    toBuffer:(id)b destinationOffset:(NSUInteger)dof destinationBytesPerRow:(NSUInteger)dbpr destinationBytesPerImage:(NSUInteger)dbpi options:(NSUInteger)opt
{
	[self copyFromTexture:t sourceSlice:ss sourceLevel:sl sourceOrigin:so sourceSize:sz toBuffer:b destinationOffset:dof destinationBytesPerRow:dbpr destinationBytesPerImage:dbpi];
}
- (void)sm_copyTex:(id)src ss:(NSUInteger)ss sl:(NSUInteger)sl so:(MTLOrigin)so sz:(MTLSize)sz dst:(id)dst ds:(NSUInteger)ds dl:(NSUInteger)dl dO:(MTLOrigin)dO
{
	{ static int nl; if (nl++ < 6) slog("SweetMTL: blit copy tex pf%lu -> pf%lu %lux%lu level %lu->%lu", (unsigned long)[src pixelFormat], (unsigned long)[dst pixelFormat],
	    (unsigned long)sz.width, (unsigned long)sz.height, (unsigned long)sl, (unsigned long)dl); }
	if (![src isKindOfClass:NSClassFromString(@"SweetMTLTexture")] || ![dst isKindOfClass:NSClassFromString(@"SweetMTLTexture")]) return;
	if (ss || sl || ds || dl) return;
	NSUInteger sw = [src width], sh = [src height], dw = [dst width], dh = [dst height];
	if (so.x + sz.width > sw || so.y + sz.height > sh || dO.x + sz.width > dw || dO.y + sz.height > dh) return;
	uint8_t *sp = [src sm_cpu], *dp = [dst sm_cpu];
	NSUInteger sb = [src bytesPerRow], db = [dst bytesPerRow];
	if (!sp || !dp) return;
	for (NSUInteger y = 0; y < sz.height; y++)
		memmove(dp + (dO.y + y) * db + dO.x * [dst bpp], sp + (so.y + y) * sb + so.x * [src bpp], sz.width * [src bpp]);
}
- (void)copyFromTexture:(id)src toTexture:(id)dst
{
	[self copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
	    sourceSize:MTLSizeMake(MIN([src width], [dst width]), MIN([src height], [dst height]), 1)
	    toTexture:dst destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
}
- (void)generateMipmapsForTexture:(id)t {}
- (void)fillBuffer:(id)b range:(NSRange)r value:(uint8_t)v
{
	[self sm_add:^{ if ([b respondsToSelector:@selector(contents)] && [b length] >= NSMaxRange(r)) memset((uint8_t *)[b contents] + r.location, v, r.length); }];
}
- (void)copyFromBuffer:(id)s sourceOffset:(NSUInteger)so toBuffer:(id)d destinationOffset:(NSUInteger)dof size:(NSUInteger)n
{
	[self sm_add:^{ if ([s length] >= so + n && [d length] >= dof + n) memmove((uint8_t *)[d contents] + dof, (uint8_t *)[s contents] + so, n); }];
}
@end
@interface SweetMTLCommandQueue : SweetMTLObject
@property (nonatomic, strong) dispatch_queue_t submissionQueue, completionQueue;
@end
@implementation SweetMTLCommandBuffer
- (instancetype)init { self = [super init]; _passes = [NSMutableArray array]; _scheduled = [NSMutableArray array]; _completed = [NSMutableArray array]; return self; }
- (void)addScheduledHandler:(void (^)(id))h { if (h) [_scheduled addObject:[h copy]]; }
- (void)addCompletedHandler:(void (^)(id))h { if (h) [_completed addObject:[h copy]]; }
- (id)blitCommandEncoder { SweetMTLBlitEncoder *e = [SweetMTLBlitEncoder new]; [_passes addObject:e]; return e; }
- (id)blitCommandEncoderWithDescriptor:(id)d { return [self blitCommandEncoder]; }
- (id)computeCommandEncoder { SweetMTLComputeEncoder *e = [SweetMTLComputeEncoder new]; [_passes addObject:e]; return e; }
- (id)computeCommandEncoderWithDispatchType:(NSUInteger)t { return [self computeCommandEncoder]; }
- (id)computeCommandEncoderWithDescriptor:(id)d { return [self computeCommandEncoder]; }
- (BOOL)retainedReferences { return YES; }
- (void)enqueue {}
- (void)waitUntilScheduled {}
- (double)GPUStartTime { return CFAbsoluteTimeGetCurrent(); }
- (double)GPUEndTime { return CFAbsoluteTimeGetCurrent(); }
- (double)kernelStartTime { return CFAbsoluteTimeGetCurrent(); }
- (double)kernelEndTime { return CFAbsoluteTimeGetCurrent(); }
- (void)sm_runHandlers
{
	NSArray *sch = [_scheduled copy], *cmp = [_completed copy];
	[_scheduled removeAllObjects]; [_completed removeAllObjects];
	for (void (^h)(id) in sch) h(self);
	if (!cmp.count) return;
	dispatch_queue_t q = ((SweetMTLCommandQueue *)_commandQueue).completionQueue ?: dispatch_get_global_queue(0, 0);
	dispatch_async(q, ^{ for (void (^h)(id) in cmp) h(self); });
}
- (id)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)d
{
	SweetMTLRenderEncoder *e = [SweetMTLRenderEncoder new];
	MTLRenderPassColorAttachmentDescriptor *ca = d.colorAttachments[0];
	e.target = (SweetMTLTexture *)ca.texture;
	e.clear = ca.loadAction == MTLLoadActionClear;
	e.load = ca.loadAction == MTLLoadActionLoad;
	MTLClearColor c = ca.clearColor;
#define SM8(v) ((uint32_t)((v) <= 0 ? 0 : (v) >= 1 ? 255 : (v) * 255.0 + 0.5))
	e.packed = SM8(c.red) | (SM8(c.green) << 8) | (SM8(c.blue) << 16) | (SM8(c.alpha) << 24);
	/* DontCare: the tile buffer starts cleared anyway; use transparent black, not the default clear colour (opaque black):
	 * CA renders mostly transparent layers with DontCare and they came out as opaque black rectangles (run125) */
	if (!e.load && !e.clear) e.packed = 0;
	{ static int nl; if (e.target && [e.target width] >= 1000 && [e.target height] >= 1000 && [e.target height] != 2436 && nl++ < 16) slog("SweetMTL: pass desc %lux%lu load action %lu clear %08x", (unsigned long)[e.target width],
	    (unsigned long)[e.target height], (unsigned long)ca.loadAction, SM8(c.red) | (SM8(c.green) << 8) | (SM8(c.blue) << 16) | (SM8(c.alpha) << 24)); }
	[_passes addObject:e];
	return e;
}
/* Command buffers share the descriptor BO, tiler heap, flush lists and the GPU: CoreAnimation commits from more
 * than one thread (display + snapshot renders in the app-to-home transition), which overwrote descriptors under a
 * running job (transient 0x58/0x59 faults that passed on replay, run105). One commit at a time. */
static pthread_mutex_t sm_commit_mx = PTHREAD_RECURSIVE_MUTEX_INITIALIZER;
- (void)commit
{
	if (pthread_mutex_trylock(&sm_commit_mx) != 0) {
		static int nl; if (nl++ < 4) slog("SweetMTL: commit collision: another thread is committing, waiting");
		pthread_mutex_lock(&sm_commit_mx);
	}
	static sm_bo desc; static bool have;
	if (!have) { have = sm_bo_alloc(&desc, 0x10000 + 32 * SM_DRAW_STRIDE); if (have) { sm_always_add(&desc); sm_desc_va = desc.gpu; } }
	_status = 4; /* MTLCommandBufferStatusCompleted */
	sm_commits++;
	uint64_t pf_t0 = sm_ns();
	if (sm_pf_last) { uint64_t g = (pf_t0 - sm_pf_last) / 1000000; sm_pf_gap[g < 20 ? 0 : g < 40 ? 1 : g < 100 ? 2 : 3]++; }
	for (SweetMTLRenderEncoder *e in _passes) if ([e isKindOfClass:[SweetMTLRenderEncoder class]] && ![e isKindOfClass:[SweetMTLComputeEncoder class]]) sm_pf_draws += e->_ndraw;
	for (SweetMTLRenderEncoder *e in _passes) {
		if ([e isKindOfClass:[SweetMTLBlitEncoder class]]) { [(SweetMTLBlitEncoder *)e sm_run]; continue; }
		if ([e isKindOfClass:[SweetMTLComputeEncoder class]]) { if (!sm_gpu_off) [(SweetMTLComputeEncoder *)e sm_run]; continue; }
		if (!have || !e.target) { _status = 5; continue; }
		sm_target_pf = e.target.pixelFormat;
		{ static int nf = -1; if (nf < 0) { char ba[1024] = {0}; size_t bl = sizeof(ba) - 1; nf = sysctlbyname("kern.bootargs", ba, &bl, NULL, 0) == 0 && strstr(ba, "sweetiosflush=1") ? 0 : 1; }
		  sm_target_noflush = nf && e.target.iosurface && e.target.bo && e.target.bo->imported; }
		if (sm_pf_bpp(e.target.pixelFormat) != 4 && sm_rt_writeback(e.target.pixelFormat) == MALI_COLOR_FORMAT_R8G8B8A8) {
			/* render targets are written as 4-byte RGBA8/BGRA8 only: a 1/2/8-byte target would overflow */
			static int nl; if (nl++ < 6) slog("SweetMTL: skipped pass into pixel format %lu", (unsigned long)e.target.pixelFormat);
			continue;
		}
		bool bgra = sm_is_bgra(e.target.pixelFormat);
		if (e->_ndraw) {
			static sm_bo heap; static bool haveheap;
			if (!haveheap) { haveheap = sm_bo_alloc(&heap, sm_is_poster(getprogname()) ? (1u << 20) : (4u << 20)); /* never written by the CPU (kernel pages come zeroed): no flush */ }
			if (!haveheap) { _status = 5; continue; }
			bool generic = true;
			for (uint32_t i = 0; i < e->_ndraw; i++) if (!e->_draws[i].vs) generic = false;
			uint32_t vs = 0;
			if (generic) {
				/* prefix bisect (run125): for full-screen loaded passes after the unlock, save the target, run the pass, then
				 * replay draws 0..k from the saved image and sample one pixel inside the black rectangle (600,300) and one in the
				 * wallpaper (600,1500): the first k that turns the inside pixel black is the culprit */
				uint8_t *save = NULL; static int nbis2;
				uint32_t W = (uint32_t)e.target.width, H = (uint32_t)e.target.height, bpr = (uint32_t)e.target.bytesPerRow;
				bool lay = (W == 1082 && H == 1226) || (W == 1085 && H == 1227);
				/* wallpaper seam (run163): the head layer (1085x1227) must be transparent where its mask is (top-left corner),
				 * yet the screen looked lighter inside it: sample the layer at (20,20) (mask 0) and the screen at (100,100)
				 * (inside the layer, mask 0) against (20,100) (left of the layer) */
				uint32_t ix = lay ? 20 : 100, iy = lay ? 20 : 100, ox = lay ? W / 2 : 20, oy = lay ? 300 : 100;
				bool scr = e.load && (W == 1125 || W == 1127) && (H == 2436 || H == 2438) && e->_ndraw >= 2;
				if (sm_describe > 0 && (scr || lay) && e.target.bo->cpu && nbis2 < 8) {
					sm_target_noflush = false;   /* the CPU reads and rewrites this target here: keep cache maintenance on */
					sm_flush_now(e.target.bo->gpu, (uint64_t)bpr * H);
					save = malloc((size_t)bpr * H); if (save) memcpy(save, e.target.bo->cpu, (size_t)bpr * H);
				}
				_lastJobStatus = sm_pass(&desc, &heap, e.target.bo->gpu, (uint32_t)e.target.width, (uint32_t)e.target.height,
				    (uint32_t)e.target.bytesPerRow, e.packed, bgra, e->_draws, e->_ndraw, &vs, e.load);
				if (save) {
					nbis2++;
					const uint8_t *c = e.target.bo->cpu;
					uint32_t in0, out0, inF, outF; memcpy(&in0, save + iy * bpr + ix * 4, 4); memcpy(&out0, save + oy * bpr + ox * 4, 4);
					memcpy(&inF, c + iy * bpr + ix * 4, 4); memcpy(&outF, c + oy * bpr + ox * 4, 4);
					slog("SweetMTL: bisect2 pass %ux%u load %d clear %08x n=%u before in %08x out %08x after in %08x out %08x", W, H, e.load, e.packed, e->_ndraw, in0, out0, inF, outF);
					uint8_t *fin = malloc((size_t)bpr * H); if (fin) memcpy(fin, c, (size_t)bpr * H);
					for (uint32_t k = 0; k < e->_ndraw && k < 12; k++) {
						memcpy(e.target.bo->cpu, save, (size_t)bpr * H);
						uint32_t v2 = 0, f2 = sm_pass(&desc, &heap, e.target.bo->gpu, W, H, bpr, e.packed, bgra, e->_draws, k + 1, &v2, e.load);
						uint32_t pin, pout; memcpy(&pin, c + iy * bpr + ix * 4, 4); memcpy(&pout, c + oy * bpr + ox * 4, 4);
						const sm_drawrec *o = &e->_draws[k]; const char *fn = o->fs ? o->fs->name : "GREEN"; if (!strncmp(fn, "sweet.frag.a1.", 14)) fn += 14;
						slog("SweetMTL: bisect2  +d%u %.30s bl%u sf%u df%u tex %ux%u: in %08x out %08x st %x", k, fn, o->blend_on, o->rgb_sf, o->rgb_df,
						    o->ntex ? o->tex[o->ntex - 1].w : 0, o->ntex ? o->tex[o->ntex - 1].h : 0, pin, pout, f2);
					}
					if (fin) { memcpy(e.target.bo->cpu, fin, (size_t)bpr * H); free(fin); }
					free(save);
				}
			} else {
				/* no translated vertex shader: fixed Mesa shaders (phase 2b) */
				uint32_t n = 0; for (uint32_t i = 0; i < e->_ndraw; i++) n += e->_draws[i].vcount;
				_lastJobStatus = sm_draw(&desc, &heap, e.target.bo->gpu, (uint32_t)e.target.width, (uint32_t)e.target.height,
				    (uint32_t)e.target.bytesPerRow, e.packed, bgra, n, &vs);
			}
			static int npass; if (_lastJobStatus || vs || npass++ < 6 || (sm_is_poster(getprogname()) && npass < 40))
			slog("SweetMTL: pass %u draws into %lux%lu pf%lu%s load=%d clear=%d vertex=%x fragment=%x", e->_ndraw, (unsigned long)e.target.width,
			    (unsigned long)e.target.height, (unsigned long)e.target.pixelFormat, e.target.iosurface ? " ios" : "", e.load, e.clear, vs, _lastJobStatus);
			if (sm_describe > 0 && !sm_is_poster(getprogname())) {
				sm_describe--;
				slog("SweetMTL: fpass %lux%lu pf%lu n=%u load=%d st=%x", (unsigned long)e.target.width, (unsigned long)e.target.height,
				    (unsigned long)e.target.pixelFormat, e->_ndraw, e.load, _lastJobStatus);
				if (e.target.width == 1082 && !sm_dbg_tex[3]) sm_dbg_tex[3] = e.target;
				for (uint32_t i = 0; i < e->_ndraw && i < 40; i++) {
					const sm_drawrec *o = &e->_draws[i];
					const char *fn = o->fs ? o->fs->name : "GREEN";
					if (!strncmp(fn, "com.apple.coreanimation.frag.", 29)) fn += 29;
					char tb[64] = ""; int tl = 0;
					for (uint32_t k = o->ntex > 3 ? o->ntex - 3 : 0; k < o->ntex; k++)
						tl += snprintf(tb + tl, sizeof tb - tl, " %ux%u/%u", o->tex[k].w, o->tex[k].h, o->tex[k].pf);
					slog("SweetMTL:  fd%u %.36s n%u bl%u vb%llx ix%llx%s", i, fn, o->vcount, o->blend_on, o->buf[0], o->index_va, tb);
				}
			}
			if (generic && _lastJobStatus == 0xFFFFu && sm_is_poster(getprogname())) {
				/* poster pass hung (timeout, not a fault): replay each draw alone, as recorded and with its ASTC textures
				 * swapped for the null texture, to tell a shader hang from an ASTC decode hang. Once per process. */
				static bool done;
				if (!done) {
					done = true; sm_gpu_off = false;
					for (uint32_t i = 0; i < e->_ndraw && i < 3; i++) {
						sm_drawrec one = e->_draws[i];
						uint32_t v1 = 0, v2 = 0;
						uint32_t f1 = sm_pass(&desc, &heap, e.target.bo->gpu, (uint32_t)e.target.width, (uint32_t)e.target.height,
						    (uint32_t)e.target.bytesPerRow, e.packed, bgra, &one, 1, &v1, false);
						sm_gpu_off = false;
						bool hasastc = false;
						for (uint32_t k = 0; k < one.ntex; k++) if (one.tex[k].astc) { one.tex[k].va = 0; hasastc = true; }
						uint32_t f2 = hasastc ? sm_pass(&desc, &heap, e.target.bo->gpu, (uint32_t)e.target.width, (uint32_t)e.target.height,
						    (uint32_t)e.target.bytesPerRow, e.packed, bgra, &one, 1, &v2, false) : 0xEEEE;
						sm_gpu_off = false;
						slog("SweetMTL: hang bisect draw%u %s: as-is %x/%x, no-astc %x/%x", i, one.fs ? one.fs->name : "-", v1, f1, v2, f2);
					}
					sm_gpu_off = true;
				}
			}
			if (generic && _lastJobStatus && _lastJobStatus != 0xFFFCu) {
				/* fragment fault: describe the pass once, then quarantine the texturing fragment shaders of this pass
				 * (draws without textures never faulted; the GPU was reset by the kernel) */
				static int ndesc;
				if (ndesc++ < 2) {
					for (uint32_t i = 0; i < e->_ndraw; i++) {
						const sm_drawrec *o = &e->_draws[i];
						slog("SweetMTL: fd%u %.60s nt=%u ns=%u n=%u bl=%u", i, o->fs ? o->fs->name : "-", o->ntex, o->nsmp, o->vcount, o->blend_on);
						slog("SweetMTL:  fb %llx %llx %llx %llx %llx %llx push %u", o->fbuf[0], o->fbuf[1], o->fbuf[2], o->fbuf[3], o->fbuf[4], o->fbuf[5], o->fs ? o->fs->push_words : 0);
						for (uint32_t k = 0; k < o->ntex; k++)
							if (o->tex[k].va) slog("SweetMTL:  t%u %ux%u pf%u st%u va%llx imp%u", k, o->tex[k].w, o->tex[k].h, o->tex[k].pf, o->tex[k].stride, o->tex[k].va, o->tex[k].imp);
					}
				}
				for (uint32_t i = 0; i < e->_ndraw; i++) {
					sm_shader *f = (sm_shader *)e->_draws[i].fs;
					if (f && !f->bad && e->_draws[i].ntex) { f->bad = 1; slog("SweetMTL: quarantined %s after fragment status %x", f->name, _lastJobStatus); }
				}
			}
			if (generic && (_lastJobStatus || vs) && _lastJobStatus != 0xFFFCu && !sm_is_poster(getprogname())) {
				/* app-to-home transition faults (0x58/0x59, runs 101-104): replay the pass once as-is and once without
				 * the load preload, to tell a transient (memory changed under the GPU) from a deterministic fault */
				static int nrep;
				if (nrep++ < 2) {
					uint32_t va1 = 0, va2 = 0;
					uint32_t fa1 = sm_pass(&desc, &heap, e.target.bo->gpu, (uint32_t)e.target.width, (uint32_t)e.target.height,
					    (uint32_t)e.target.bytesPerRow, e.packed, bgra, e->_draws, e->_ndraw, &va1, e.load);
					uint32_t fa2 = sm_pass(&desc, &heap, e.target.bo->gpu, (uint32_t)e.target.width, (uint32_t)e.target.height,
					    (uint32_t)e.target.bytesPerRow, e.packed, bgra, e->_draws, e->_ndraw, &va2, false);
					slog("SweetMTL: fault replay %ux%u bpr %lu bo %llx+%llx imp %u load %d: first %x/%x, again %x/%x, noload %x/%x", (uint32_t)e.target.width,
					    (uint32_t)e.target.height, (unsigned long)e.target.bytesPerRow, e.target.bo->gpu, e.target.bo->size, e.target.bo->imported, e.load,
					    vs, _lastJobStatus, va1, fa1, va2, fa2);
				}
			}
			static int nbis;
			if (generic && _lastJobStatus && nbis++ < 0) {   /* per-draw replay off: its own faults used up the kernel fault budget (run50) */
				/* fragment fault: replay each draw alone (the kernel resets the GPU after a fault), once as recorded
				 * and once with its fragment buffers redirected to the dummy page, to find which binding faults */
				for (uint32_t i = 0; i < e->_ndraw; i++) {
					sm_drawrec one = e->_draws[i];
					uint32_t v1 = 0, v2 = 0;
					uint32_t f1 = sm_pass(&desc, &heap, e.target.bo->gpu, (uint32_t)e.target.width, (uint32_t)e.target.height,
					    (uint32_t)e.target.bytesPerRow, e.packed, bgra, &one, 1, &v1, false);
					memset(one.fbuf, 0, sizeof one.fbuf);
					uint32_t f2 = sm_pass(&desc, &heap, e.target.bo->gpu, (uint32_t)e.target.width, (uint32_t)e.target.height,
					    (uint32_t)e.target.bytesPerRow, e.packed, bgra, &one, 1, &v2, false);
					one = e->_draws[i]; one.ntex = 0;
					uint32_t v3 = 0;
					uint32_t f3 = sm_pass(&desc, &heap, e.target.bo->gpu, (uint32_t)e.target.width, (uint32_t)e.target.height,
					    (uint32_t)e.target.bytesPerRow, e.packed, bgra, &one, 1, &v3, false);
					slog("SweetMTL: bisect pass%d draw%u fs=%s ntex=%u: as-is %x/%x, nofbuf %x/%x, notex %x/%x", nbis, i,
					    one.fs ? one.fs->name : "-", e->_draws[i].ntex, v1, f1, v2, f2, v3, f3);
					if (f1 && !f3) {
						/* textures are to blame: describe each and replay with just that one swapped for the null texture */
						for (uint32_t k = 0; k < e->_draws[i].ntex; k++) {
							const sm_drawrec *o = &e->_draws[i];
							if (!o->tex[k].va) continue;
							one = *o; one.tex[k].va = 0;
							uint32_t v4 = 0;
							uint32_t f4 = sm_pass(&desc, &heap, e.target.bo->gpu, (uint32_t)e.target.width, (uint32_t)e.target.height,
							    (uint32_t)e.target.bytesPerRow, e.packed, bgra, &one, 1, &v4, false);
							slog("SweetMTL: bisect  tex%u va %llx %ux%u stride %u fmt %x pf %u imp %u target %llx -> without it %x/%x", k,
							    o->tex[k].va, o->tex[k].w, o->tex[k].h, o->tex[k].stride, o->tex[k].fmt, o->tex[k].pf, o->tex[k].imp,
							    e.target.bo->gpu, v4, f4);
						}
					}
				}
				uint32_t v0 = 0;
				uint32_t f0 = sm_pass(&desc, &heap, e.target.bo->gpu, (uint32_t)e.target.width, (uint32_t)e.target.height,
				    (uint32_t)e.target.bytesPerRow, e.packed, bgra, e->_draws, e->_ndraw, &v0, e.load);
				slog("SweetMTL: bisect pass%d full replay %x/%x", nbis, v0, f0);
			}
			if (e.target.width == 1125 && e.target.bo && e.target.bo->cpu) sm_last_target = e.target;   /* for the timed thumbnails */
			static int ndiag;
			if (generic && !_lastJobStatus && ndiag++ < 0) {
				/* coverage check: replay each draw alone over a cleared target, once with the green test shader and once
				 * as translated; count changed pixels and the most common written values */
				const uint8_t *c = e.target.bo->cpu; uint32_t W = (uint32_t)e.target.width, H = (uint32_t)e.target.height, bpr = (uint32_t)e.target.bytesPerRow;
				for (uint32_t i = 0; i < e->_ndraw && c; i++) {
					uint32_t cnt[2] = {0}, top[2][3] = {{0}}, topn[2][3] = {{0}}, st[2] = {0}, c00[2] = {0}, mid[2] = {0};
					for (int mode = 0; mode < 2; mode++) {
						sm_drawrec one = e->_draws[i];
						if (mode == 0) one.fs = NULL;
						uint32_t vv = 0;
						st[mode] = sm_pass(&desc, &heap, e.target.bo->gpu, W, H, bpr, e.packed, bgra, &one, 1, &vv, false);
						uint32_t ref; memcpy(&ref, c, 4);
						uint32_t clr = 0; bool clrset = false;
						for (uint32_t y = 0; y < H; y += 2) for (uint32_t x = 0; x < W; x += 2) {
							uint32_t v; memcpy(&v, c + (uint64_t)y * bpr + x * 4, 4);
							if (!clrset) { clr = v; clrset = true; c00[mode] = v; }
							if (y == (H / 2 & ~1u) && x == (W / 2 & ~1u)) mid[mode] = v;
							(void)ref;
							if (v == clr) continue;
							cnt[mode]++;
							int j; for (j = 0; j < 3 && topn[mode][j] && top[mode][j] != v; j++);
							if (j < 3) { if (!topn[mode][j]) top[mode][j] = v; topn[mode][j]++; }
						}
					}
					const sm_drawrec *o = &e->_draws[i];
					slog("SweetMTL: cov%d.%u real %x %u px mid %08x top %08x:%u %08x:%u", ndiag, i, st[1], cnt[1], mid[1], top[1][0], topn[1][0], top[1][1], topn[1][1]);
					for (uint32_t k = 0; k < o->ntex; k++) {
						SweetMTLTexture *t = e->_tex[k];
						if (!t || !t.bo || !t.bo->cpu) continue;
						const uint32_t *px = (const uint32_t *)t.bo->cpu; uint64_t nw = (uint64_t)t.bytesPerRow * t.height / 4, nzc = 0; uint32_t any = 0;
						for (uint64_t q = 0; q < nw; q += 7) if (px[q]) { nzc++; any = px[q]; }
						slog("SweetMTL: cov%d.%u tex%u %lux%lu imp %u nz %llu/%llu sample %08x", ndiag, i, k, (unsigned long)t.width, (unsigned long)t.height, t.bo->imported, nzc, nw / 7, any);
					}
					slog("SweetMTL: cover pass%d draw%u fs=%s blend=%u wmask=%x sc=%u: green %x %u px c00 %08x mid %08x | real %x %u px c00 %08x mid %08x top %08x:%u %08x:%u %08x:%u", ndiag, i,
					    o->fs ? o->fs->name : "-", o->blend_on, o->wmask, o->has_scissor, st[0], cnt[0], c00[0], mid[0], st[1], cnt[1], c00[1], mid[1],
					    top[1][0], topn[1][0], top[1][1], topn[1][1], top[1][2], topn[1][2]);
				}
				uint32_t v0 = 0;
				sm_pass(&desc, &heap, e.target.bo->gpu, W, H, bpr, e.packed, bgra, e->_draws, e->_ndraw, &v0, e.load);
				slog("SweetMTL: cover pass%d clear %08x first px after replay %08x", ndiag, e.packed, c ? *(const uint32_t *)c : 0);
			}
			static int nsamp;
			if (nsamp++ < 16) {
				/* sample a 4x4 grid of the target: proves the GPU wrote real content */
				const uint8_t *c = e.target.bo->cpu; uint32_t W = (uint32_t)e.target.width, H = (uint32_t)e.target.height, bpr = (uint32_t)e.target.bytesPerRow;
				uint32_t nz = 0, hsh = 2166136261u, px[4] = {0};
				for (uint32_t gy = 0; gy < 4 && c; gy++) for (uint32_t gx = 0; gx < 4; gx++) {
					uint32_t v; memcpy(&v, c + (uint64_t)((2 * gy + 1) * H / 8) * bpr + ((2 * gx + 1) * W / 8) * 4, 4);
					if (v) nz++;
					hsh = (hsh ^ v) * 16777619u;
					if (gy == gx) px[gy] = v;
				}
				sm_capture(c, W, H, bpr, (uint32_t)e.target.pixelFormat, (uint32_t)nsamp);
				/* early thumbnails dropped: the late ones (600/800/1000 s) need the log space */
				slog("SweetMTL: target %ux%u fmt %lu nz=%u/16 hash=%08x diag %08x %08x %08x %08x", W, H, (unsigned long)e.target.pixelFormat, nz, hsh, px[0], px[1], px[2], px[3]);
			}
			if (_lastJobStatus != 0 || vs != 0) _status = 5;
			[e.target sm_writeback];
		} else if (e.clear) {
			_lastJobStatus = sm_clear(&desc, e.target.bo->gpu, (uint32_t)e.target.width, (uint32_t)e.target.height,
			    (uint32_t)e.target.bytesPerRow, e.packed, bgra);
			slog("SweetMTL: clear %lux%lu job status=%x", (unsigned long)e.target.width, (unsigned long)e.target.height, _lastJobStatus);
			if (_lastJobStatus != 0) _status = 5;
			[e.target sm_writeback];
		}
	}
	pthread_mutex_unlock(&sm_commit_mx);
	/* CAMetalLayer drawables queued with presentDrawable: go to the compositor once the GPU work is done
	 * (an empty presentDrawable: kept AegirPoster's stars off the screen, run63) */
	for (id<MTLDrawable> d in _toPresent) {
		static int nl; if (nl++ < 4) slog("SweetMTL: present drawable %s", object_getClassName(d));
		if ([d respondsToSelector:@selector(present)]) [d present];
	}
	[_toPresent removeAllObjects];
	{ uint64_t t1 = sm_ns(), d = t1 - pf_t0; sm_pf_ns += d; if (d > sm_pf_max_ns) sm_pf_max_ns = d; sm_pf_n++; sm_pf_last = t1; }
	[self sm_runHandlers];
}
- (void)waitUntilCompleted {}
- (void)commitAndWaitUntilSubmitted { [self commit]; }
- (void)setProtectionOptions:(uint64_t)o {}
- (uint64_t)protectionOptions { return 0; }
- (void)presentDrawable:(id)d { if (!d) return; if (!_toPresent) _toPresent = [NSMutableArray array]; [_toPresent addObject:d]; }
- (void)presentDrawable:(id)d atTime:(CFTimeInterval)t { [self presentDrawable:d]; }
- (void)presentDrawable:(id)d afterMinimumDuration:(CFTimeInterval)t { [self presentDrawable:d]; }
- (NSError *)error { return nil; }
@end

@implementation SweetMTLCommandQueue
- (id)commandBuffer { SweetMTLCommandBuffer *b = [SweetMTLCommandBuffer new]; b.commandQueue = self; return b; }
- (id)commandBufferWithUnretainedReferences { return [self commandBuffer]; }
- (id)commandBufferWithDescriptor:(id)d { return [self commandBuffer]; }
- (void)insertDebugCaptureBoundary {}
- (void)setGPUPriority:(NSUInteger)p {}
@end

/*
 * Metal (getMetalPluginClassForService) takes the class with -[NSBundle classNamed:], which only
 * returns classes compiled into this bundle, and requires it to be a subclass of the private
 * _MTLDevice. So _MTLDevice is declared here and its class symbols are resolved at load time
 * (-Wl,-U in the build). Everything not implemented is logged and answered with 0/nil.
 */
@interface _MTLDevice : NSObject
@end

/* MTLAddDevice asserts conformance to MTLDevice and to the private MTLDeviceSPI
 * (protocols are matched by name by the runtime, so an empty redeclaration is enough). */
@protocol MTLDeviceSPI <MTLDevice>
@end

/* ------------------------------------------------------------------ crash diagnostics */
#include <signal.h>
#include <execinfo.h>
#include <dlfcn.h>
#include <sys/ucontext.h>
#include <pthread.h>
#include <mach/mach.h>
static void sm_sym(const char *tag, void *pc)
{
	Dl_info di; memset(&di, 0, sizeof di);
	if (dladdr(pc, &di) && di.dli_sname)
		slog("SweetMTL: %s %p %s+0x%lx (%s)", tag, pc, di.dli_sname, (unsigned long)((char *)pc - (char *)di.dli_saddr),
		    di.dli_fname ? (strrchr(di.dli_fname, '/') ? strrchr(di.dli_fname, '/') + 1 : di.dli_fname) : "?");
	else
		slog("SweetMTL: %s %p (%s+0x%lx)", tag, pc, di.dli_fname ? (strrchr(di.dli_fname, '/') ? strrchr(di.dli_fname, '/') + 1 : di.dli_fname) : "?",
		    (unsigned long)((char *)pc - (char *)di.dli_fbase));
}
/* VM region of a client pointer: who provided the memory (user tag, share mode) */
static void sm_region_info(const void *p)
{
	vm_address_t a = (vm_address_t)p; vm_size_t sz = 0; natural_t depth = 4;
	vm_region_submap_info_data_64_t info; mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
	kern_return_t kr = vm_region_recurse_64(mach_task_self(), &a, &sz, &depth, (vm_region_recurse_info_t)&info, &cnt);
	slog("SweetMTL: ebt region %p kr %x start %lx size %lx tag %u share %u prot %x obj %x refs %u", p, kr, a, sz, info.user_tag, info.share_mode, info.protection, info.object_id, info.ref_count);
}
/* Which process shares this memory? The VM object id reported by vm_region_recurse is the same in every task that maps
 * the object, and backboardd is root: walk every task's regions for it (writable mapping = the producer). */
extern kern_return_t processor_set_default(host_t, processor_set_name_t *);
extern kern_return_t host_processor_set_priv(host_priv_t, processor_set_name_t, processor_set_t *);
extern kern_return_t processor_set_tasks(processor_set_t, task_array_t *, mach_msg_type_number_t *);
extern kern_return_t task_for_pid(mach_port_name_t, int, mach_port_name_t *);
extern int pid_for_task(mach_port_name_t, int *);
extern int proc_name(int, void *, uint32_t);
static void sm_find_sharers(const void *p, const char *what)
{
	vm_address_t a = (vm_address_t)p; vm_size_t sz = 0; natural_t depth = 4;
	vm_region_submap_info_data_64_t info; mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
	if (vm_region_recurse_64(mach_task_self(), &a, &sz, &depth, (vm_region_recurse_info_t)&info, &cnt)) return;
	uint32_t want = info.object_id; vm_size_t wsz = sz;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		task_array_t tasks = NULL; mach_msg_type_number_t nt = 0; processor_set_name_t ps = 0; processor_set_t pp = 0;
		kern_return_t k1 = processor_set_default(mach_host_self(), &ps), k2 = k1 ? k1 : host_processor_set_priv(mach_host_self(), ps, &pp);
		kern_return_t k3 = k2 ? k2 : processor_set_tasks(pp, &tasks, &nt);
		slog("SweetMTL: sharers of %s obj %x size %lx: tasks kr %x/%x/%x n %u", what, want, (unsigned long)wsz, k1, k2, k3, nt);
		int found = 0;
		for (int i = 0; i < (k3 ? 4000 : (int)nt) && found < 6; i++) {
			mach_port_name_t t = 0; int pid = i;
			if (k3) { if (task_for_pid(mach_task_self(), i, &t) || !t) continue; } else { t = tasks[i]; pid_for_task(t, &pid); }
			if (t == mach_task_self()) continue;
			vm_address_t ra = 0; vm_size_t rs = 0;
			for (int guard = 0; guard < 20000; guard++) {
				natural_t d = 4; vm_region_submap_info_data_64_t ri; mach_msg_type_number_t rc = VM_REGION_SUBMAP_INFO_COUNT_64;
				if (vm_region_recurse_64(t, &ra, &rs, &d, (vm_region_recurse_info_t)&ri, &rc)) break;
				if (ri.object_id == want) {
					char nm[64] = "?"; proc_name(pid, nm, sizeof nm);
					slog("SweetMTL: sharer %s pid %d %s prot %x tag %u at %lx size %lx", what, pid, nm, ri.protection, ri.user_tag, (unsigned long)ra, (unsigned long)rs);
					found++; break;
				}
				ra += rs;
			}
		}
		slog("SweetMTL: sharers of %s done, %d found", what, found);
	});
}
/* backtrace into the kept lines (prefix "ebt") */
static void sm_bt_kept(void)
{
	void *f[20]; int n = backtrace(f, 20);
	for (int i = 1; i < n; i++) {
		Dl_info di; memset(&di, 0, sizeof di); dladdr(f[i], &di);
		const char *lib = di.dli_fname ? (strrchr(di.dli_fname, '/') ? strrchr(di.dli_fname, '/') + 1 : di.dli_fname) : "?";
		slog("SweetMTL: ebt %d %.24s %.60s+0x%lx base+0x%lx", i, lib, di.dli_sname ? di.dli_sname : "?", (unsigned long)((char *)f[i] - (char *)(di.dli_saddr ? di.dli_saddr : di.dli_fbase)),
		    (unsigned long)((char *)f[i] - (char *)di.dli_fbase));
	}
}
static void sm_bt(void)
{
	void *f[24]; int n = backtrace(f, 24);
	for (int i = 0; i < n; i++) sm_sym("  bt", f[i]);
}
static void sm_sig(int sig, siginfo_t *si, void *uc)
{
	ucontext_t *u = uc;
	slog("SweetMTL: SIGNAL %d in %s addr=%p", sig, getprogname(), si ? si->si_addr : NULL);
	if (u && u->uc_mcontext) { sm_sym("pc", (void *)u->uc_mcontext->__ss.__pc); sm_sym("lr", (void *)u->uc_mcontext->__ss.__lr); }
	sm_bt();
	signal(sig, SIG_DFL); raise(sig);
}
static void sm_exc(NSException *e)
{
	slog("SweetMTL: EXCEPTION %s: %s", e.name.UTF8String, e.reason.UTF8String ?: "-");
	int i = 0;
	for (NSNumber *a in e.callStackReturnAddresses) { if (i++ > 20) break; sm_sym("  ebt", (void *)a.unsignedLongValue); }
}
static void sm_diag_install(void)
{
	struct sigaction sa; memset(&sa, 0, sizeof sa);
	sa.sa_sigaction = sm_sig; sa.sa_flags = SA_SIGINFO;
	int sigs[] = { SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGFPE };
	for (unsigned i = 0; i < sizeof sigs / sizeof *sigs; i++) sigaction(sigs[i], &sa, NULL);
	NSSetUncaughtExceptionHandler(sm_exc);
}
@interface NSInvocation (SweetPrivate)
- (void)invokeUsingIMP:(IMP)imp;
@end
static Class sm_super_cls;
/* Route every _MTLDevice method we do not override through forwardInvocation so each one is logged once
 * and then run with the inherited implementation. */
static void sm_trace_install(Class me)
{
	Class sup = class_getSuperclass(me); sm_super_cls = sup;
	unsigned n = 0; Method *ms = class_copyMethodList(sup, &n);
	static const char *skip[] = { "dealloc", ".cxx_destruct", "retain", "release", "autorelease", "retainCount", "description",
	    "debugDescription", "respondsToSelector:", "methodSignatureForSelector:", "forwardInvocation:", "class", "isKindOfClass:",
	    "conformsToProtocol:", "hash", "isEqual:", "_tryRetain", "_isDeallocating", "allowsWeakReference", "retainWeakReference", NULL };
	unsigned added = 0;
	for (unsigned i = 0; i < n; i++) {
		SEL sel = method_getName(ms[i]); const char *sn = sel_getName(sel);
		bool sk = !strncmp(sn, "init", 4) || sn[0] == '_' || sn[0] == '.' || class_getInstanceMethod([NSObject class], sel) != NULL;
		for (int k = 0; skip[k] && !sk; k++) if (!strcmp(sn, skip[k])) sk = true;
		if (sk) continue;
		Method mine = class_getInstanceMethod(me, sel);
		if (mine && method_getImplementation(mine) != method_getImplementation(ms[i])) continue; /* we override it */
		if (class_addMethod(me, sel, _objc_msgForward, method_getTypeEncoding(ms[i]))) added++;
	}
	free(ms);
	slog("SweetMTL: tracing %u inherited _MTLDevice methods", added);
}

static const char *sm_symof(uint64_t a, char *buf, size_t n)
{
	Dl_info di; memset(&di, 0, sizeof di);
	if (a && dladdr((void *)a, &di)) {
		const char *im = di.dli_fname ? strrchr(di.dli_fname, '/') : NULL;
		if (di.dli_sname && strcmp(di.dli_sname, "<redacted>"))
			snprintf(buf, n, "%s:%s+%lx", im ? im + 1 : "?", di.dli_sname, (unsigned long)(a - (uint64_t)di.dli_saddr));
		else snprintf(buf, n, "%s:+%lx", im ? im + 1 : "?", (unsigned long)(a - (uint64_t)di.dli_fbase));
	} else snprintf(buf, n, "%llx", (unsigned long long)a);
	return buf;
}
/* Boot diagnosis (boot-arg sweetbootdiag=1): nothing is drawn between the boot logo (26 s) and the lock screen (916 s).
 * From backboardd (root): list the processes and symbolicate another task's main thread (the shared cache has the same
 * slide in every process, so dladdr here resolves their PCs). */
extern int proc_listallpids(void *, int);
static void sm_remote_stack(int pid, const char *nm, int nthreads)
{
	mach_port_name_t t = 0;
	if (task_for_pid(mach_task_self(), pid, &t) || !t) { slog("SweetMTL: bootdiag %s pid %d: no task port", nm, pid); return; }
	thread_act_array_t th = NULL; mach_msg_type_number_t n = 0;
	if (task_threads(t, &th, &n)) return;
	for (mach_msg_type_number_t i = 0; i < n && (int)i < nthreads; i++) {
		arm_thread_state64_t st; mach_msg_type_number_t c = ARM_THREAD_STATE64_COUNT;
		if (thread_get_state(th[i], ARM_THREAD_STATE64, (thread_state_t)&st, &c)) continue;
		uint64_t pcs[14]; int np = 0;
		pcs[np++] = (uint64_t)arm_thread_state64_get_pc(st) & 0xFFFFFFFFFULL; pcs[np++] = (uint64_t)arm_thread_state64_get_lr(st) & 0xFFFFFFFFFULL;
		uint64_t fp = (uint64_t)arm_thread_state64_get_fp(st);
		for (int k = 0; k < 12 && fp && np < 14; k++) {
			uint64_t fr[2] = { 0, 0 }; vm_size_t got = 0;
			if (vm_read_overwrite(t, (vm_address_t)fp, 16, (vm_address_t)fr, &got) || got != 16) break;
			pcs[np++] = fr[1] & 0xFFFFFFFFFULL; fp = fr[0];
		}
		{ char a0[70]; sm_symof(pcs[0], a0, sizeof a0); if (nthreads > 3 && (strstr(a0, "__workq_kernreturn") || strstr(a0, "start_wqthread"))) continue; }   /* idle workers */
		for (int k = 0; k < np; k += 2) {
			char a[70], b[70];
			slog("SweetMTL: bootdiag %s T%u %d: %s < %s", nm, i, k, sm_symof(pcs[k], a, sizeof a), k + 1 < np ? sm_symof(pcs[k + 1], b, sizeof b) : "-");
		}
	}
}
static void sm_boot_diag(long sec)
{
	static int pids[1024]; int n = proc_listallpids(pids, sizeof pids) ; if (n > 1024) n = 1024;
	char line[140]; int L = snprintf(line, sizeof line, "bootdiag %lds %d procs:", sec, n); int sb = 0, sbd = 0;
	for (int i = n - 1; i >= 0; i--) {
		char nm[40] = "?"; proc_name(pids[i], nm, sizeof nm);
		if (!strcmp(nm, "SpringBoard")) sb = pids[i];
		if (!strcmp(nm, "backboardd")) sbd = pids[i];
		int k = snprintf(line + L, sizeof line - L, " %.14s", nm);
		if (L + k >= 128) { L = snprintf(line, sizeof line, "bootdiag +"); k = snprintf(line + L, sizeof line - L, " %.14s", nm); }
		L += k;
	}
	(void)line; (void)sbd;
	(void)sb;
	int seen = 0;
	for (int i = 0; i < n; i++) { char nm[40] = "?"; proc_name(pids[i], nm, sizeof nm);
		if (!strcmp(nm, "PosterBoard") || !strcmp(nm, "AegirPoster") || !strcmp(nm, "CollectionsPoster")) { sm_remote_stack(pids[i], nm, 14); seen |= 1; } }
	if (!(seen & 1)) slog("SweetMTL: bootdiag %lds: no PosterBoard/AegirPoster/CollectionsPoster running yet", sec);
}
static void sm_dump_threads(void)
{
	thread_act_array_t th; mach_msg_type_number_t nth = 0;
	if (task_threads(mach_task_self(), &th, &nth) != KERN_SUCCESS) return;
	thread_t me = mach_thread_self();
	for (mach_msg_type_number_t i = 0; i < nth && i < 40; i++) {
		if (th[i] == me) continue;
		if (thread_suspend(th[i]) != KERN_SUCCESS) continue;
		arm_thread_state64_t st; mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
		uint64_t pcs[8] = {0}; int np = 0;
		if (thread_get_state(th[i], ARM_THREAD_STATE64, (thread_state_t)&st, &cnt) == KERN_SUCCESS) {
			pcs[np++] = arm_thread_state64_get_pc(st);
			pcs[np++] = arm_thread_state64_get_lr(st);
			uint64_t *fp = (uint64_t *)arm_thread_state64_get_fp(st);
			for (int k = 0; k < 6 && fp && np < 8 && ((uint64_t)fp & 7) == 0; k++) { uint64_t ret = fp[1]; fp = (uint64_t *)fp[0]; pcs[np++] = ret & 0xFFFFFFFFFULL; }
		}
		thread_resume(th[i]);
		char a[48], b[48], c[48];
		slog("SweetMTL: T%u %s < %s < %s", i, sm_symof(pcs[0], a, sizeof a), sm_symof(pcs[1], b, sizeof b), sm_symof(pcs[2], c, sizeof c));
		slog("SweetMTL: T%u .. %s < %s < %s", i, sm_symof(pcs[3], a, sizeof a), sm_symof(pcs[4], b, sizeof b), sm_symof(pcs[5], c, sizeof c));
	}
}
/* synthetic touch through the kernel (SweetMali selector 10 -> sweet_hid_touch, panel pixels 1080x2400) */
static kern_return_t sm_touch(int down, int x, int y)
{
	uint64_t in[4] = { 0, (uint64_t)down, (uint64_t)x, (uint64_t)y };
	return IOConnectCallMethod(sm_conn, 10, in, 4, NULL, 0, NULL, NULL, NULL, NULL);
}
static kern_return_t sm_tap(int x, int y)
{
	kern_return_t k = sm_touch(1, x, y); usleep(90000); sm_touch(0, x, y);
	return k;
}
/* finger drag in n steps of ~12 ms */
static void sm_drag(int x0, int y0, int x1, int y1, int n)
{
	sm_touch(1, x0, y0);
	for (int i = 1; i <= n; i++) { usleep(12000); sm_touch(1, x0 + (x1 - x0) * i / n, y0 + (y1 - y0) * i / n); }
	usleep(20000); sm_touch(0, x1, y1);
}
static void sm_perf_reset(void)
{
	sm_pf_ns = sm_pf_gpu_ns = sm_pf_max_ns = 0; sm_pf_n = sm_pf_jobs = sm_pf_draws = 0;
	memset((void *)sm_pf_gap, 0, sizeof sm_pf_gap); sm_pf_win = sm_ns();
	sm_pf_pre_ns = sm_pf_job_ns = sm_pf_post_ns = sm_pf_lock_ns = 0;
}
static void sm_perf_report(const char *what, long now)
{
	uint64_t win = sm_pf_win ? sm_ns() - sm_pf_win : 0; uint32_t n = sm_pf_n ? sm_pf_n : 1;
	slog("SweetMTL: perf %s: %.1fs %u commits (%.1f/s) commit avg %.2fms max %.1fms gpu %.2fms/commit %u jobs %.0f draws/commit gaps<20:%u <40:%u <100:%u more:%u",
	    what, win / 1e9, sm_pf_n, win ? sm_pf_n * 1e9 / win : 0.0, sm_pf_ns / 1e6 / n, sm_pf_max_ns / 1e6, sm_pf_gpu_ns / 1e6 / n, sm_pf_jobs,
	    (double)sm_pf_draws / n, sm_pf_gap[0], sm_pf_gap[1], sm_pf_gap[2], sm_pf_gap[3]);
	slog("SweetMTL: perf %s kernel: flush-before %.1fms job %.1fms flush-after %.1fms lock-wait %.1fms per commit", what, sm_pf_pre_ns / 1e6 / n, sm_pf_job_ns / 1e6 / n, sm_pf_post_ns / 1e6 / n, sm_pf_lock_ns / 1e6 / n);
	(void)now;
}
static void sm_swipe_up(void)
{
	/* wake tap, then a home-indicator swipe from the bottom edge to mid screen */
	kern_return_t k0 = sm_touch(1, 540, 1400); usleep(60000); sm_touch(0, 540, 1400);
	usleep(700000);
	/* a full, fast flick to the top: the half swipe to y 952 could leave the lock screen card part-way (run134 theory) */
	kern_return_t k1 = sm_touch(1, 540, 2392);
	for (int i = 1; i <= 16; i++) { usleep(8000); sm_touch(1, 540, 2392 - i * 140); }
	usleep(8000); sm_touch(0, 540, 2392 - 16 * 140);
	slog("SweetMTL: swipe up sent kr=%x/%x", k0, k1);
}
static void *sm_watchdog(void *arg)
{
	uint32_t last = 0; int dumps = 0;
	for (int t = 1;; t++) {
		sleep(10);
		uint32_t c = sm_commits;
		{
			static int bd = -1, nd;
			if (bd < 0) { char ba[1024] = {0}; size_t bl = sizeof(ba) - 1; bd = sysctlbyname("kern.bootargs", ba, &bl, NULL, 0) == 0 && strstr(ba, "sweetbootdiag=1") && !strcmp(getprogname(), "backboardd") ? 1 : 0; }
			if (bd) {
				struct timespec bt; clock_gettime(CLOCK_MONOTONIC, &bt);
				if ((nd == 0 && bt.tv_sec >= 140) || (nd == 1 && bt.tv_sec >= 200) || (nd == 2 && bt.tv_sec >= 260)) { nd++; sm_boot_diag(bt.tv_sec); }
				else if (nd == 3 && bt.tv_sec >= 270) { nd++; slog("SweetMTL: bootdiag done, rebooting to recovery"); IOConnectCallMethod(sm_conn, 7, NULL, 0, NULL, 0, NULL, NULL, NULL, NULL); }
			}
		}
		if (t % (sm_is_poster(getprogname()) ? 30 : 3) == 0) {
			slog("SweetMTL: alive %ds commits=%u bo %lluMB/%u vfree %u%s%s", t * 10, c, sm_live_bytes >> 20, sm_live_n, sm_vfree_n,
			    sm_off_reason[0] ? " OFF: " : "", sm_off_reason);
			if (sm_fail_log[0]) slog("SweetMTL: fails: %s", sm_fail_log);
		}
		{
			/* test script after the lock screen (~15 min into the boot): each step reports the frame statistics of the
			 * window since the previous step, then acts (touches), small progress shots, a final full thumbnail */
			static int step;
			/* adaptive start: the lock screen is "ready" once enough frames were drawn and nothing changed for 20 s (was a
			 * fixed 1000 s from the days of 2 s frames); quick mode (default) ends after the home-screen shot, boot-arg
			 * sweetlong=1 runs the whole script (Settings, scroll, home, Safari) */
			static long due; static uint32_t rc; static int stable, longrun = -1;
			if (longrun < 0) { char ba[1024] = {0}; size_t bl = sizeof(ba) - 1; longrun = sysctlbyname("kern.bootargs", ba, &bl, NULL, 0) == 0 && strstr(ba, "sweetlong=1") ? 1 : 0; }
			/* idle = at most 3 commits over the last two 10 s ticks (the lock screen still redraws now and then) */
			{ static uint32_t h1, h2; stable = (c - h2 <= 3) ? 2 : 0; h2 = h1; h1 = c; (void)rc; }
			{ static const uint32_t mk[] = { 5, 20, 40, 50, 60 }; static int nmk; struct timespec t2; clock_gettime(CLOCK_MONOTONIC, &t2);
			  while (nmk < 5 && c >= mk[nmk]) { slog("SweetMTL: step mark commits>=%u at %lds (now %u) target %d", mk[nmk], (long)t2.tv_sec, c, sm_last_target != nil); nmk++; } }
			static const long gap[] = { 0, 90, 80, 90, 80, 100 };   /* home shot 90 s after the unlock: dock material and widgets load late after a fast boot */
			static const char *const what[] = { "boot", "home", "settings-open", "settings-idle", "home2", "safari" };
			struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
			id tg = sm_last_target;
			/* boot-arg sweetstay=1: interactive use, no scripted touches and no reboot to recovery */
			static int stay = -1; if (stay < 0) { char ba[1024] = {0}; size_t bl = sizeof(ba) - 1; stay = sysctlbyname("kern.bootargs", ba, &bl, NULL, 0) == 0 && strstr(ba, "sweetstay=1") ? 1 : 0; }
			if (stay) step = 6;
			/* boot-arg sweetminunlock=<s>: do not unlock before that uptime (late-loading UI test) */
			static long minul = -1; if (minul < 0) { char ba[1024] = {0}; size_t bl = sizeof(ba) - 1; minul = 0; if (sysctlbyname("kern.bootargs", ba, &bl, NULL, 0) == 0) { const char *q = strstr(ba, "sweetminunlock="); if (q) minul = atol(q + 15); } }
			bool fire = step == 0 ? (((c >= 50 && stable >= 2) && ts.tv_sec >= minul) || ts.tv_sec >= 1000) : ts.tv_sec >= due;
			if (step < 6 && fire && tg && !sm_is_poster(getprogname())) {
				sm_perf_report(what[step], ts.tv_sec);
				SweetMTLTexture *tx = tg;
				if (tx.bo) sm_flush_now(tx.bo->gpu, (uint64_t)tx.bytesPerRow * tx.height);   /* GPU-only target: invalidate before the CPU thumbnail */
				int st = step++;
				slog("SweetMTL: step %d at %lds commits=%u", st, (long)ts.tv_sec, c);
				if (!longrun && st == 1) { step = 5; due = ts.tv_sec + 5; } else due = ts.tv_sec + (step < 6 ? gap[step] : 0);
				if (st == 0) { sm_thumb(tx.bo->cpu, (uint32_t)tx.width, (uint32_t)tx.height, (uint32_t)tx.bytesPerRow, 0x100 | 16); sm_swipe_up(); sm_describe = 10; }   /* lock screen shot, unlock */
				else if (st == 1) {
					sm_thumb(tx.bo->cpu, (uint32_t)tx.width, (uint32_t)tx.height, (uint32_t)tx.bytesPerRow, 0x100 | 22);   /* home screen (wallpaper), full rgb565 */
					if (longrun) { kern_return_t k = sm_tap(174, 571); slog("SweetMTL: step tap Settings kr=%x", k); sm_describe = 4; } }
				else if (st == 2) {
					/* settings-open shot dropped: four deferred shots overflowed the pmsg ring (run113 lost the lock screen) */
					/* scroll the Settings list: three flicks up, then two back down, measured on their own */
					sm_perf_reset();
					for (int f = 0; f < 5; f++) { sm_drag(540, f < 3 ? 1900 : 900, 540, f < 3 ? 900 : 1900, 20); usleep(1200000); }
					usleep(1500000);
					sm_perf_report("scrolling", ts.tv_sec);
				} else if (st == 3) {
					/* settings-scrolled shot dropped (ring space) */
					sm_describe = 8;   /* the app-to-home transition faulted in run101/102: list its draws */
					sm_drag(540, 2392, 540, 1000, 24);   /* home indicator: back to the home screen */
					slog("SweetMTL: step home swipe");
				} else if (st == 4) {
					/* Safari in the dock (thumbnail run90: x 140/279, y 568/609) */
					kern_return_t k = sm_tap(542, 2238); slog("SweetMTL: step tap Safari kr=%x", k); sm_describe = 6;
				} else {
					slog("SweetMTL: late thumb at %lds commits=%u gpuoff=%d", (long)ts.tv_sec, c, sm_gpu_off);
					sm_thumb_flush();   /* the home shot (22) replaces the final Safari shot: two rgb565 shots overflow the ring */
					slog("SweetMTL: last thumb taken, rebooting to recovery");   /* the kernel replays the kept lines */
					IOConnectCallMethod(sm_conn, 7, NULL, 0, NULL, 0, NULL, NULL, NULL, NULL);
				}
				sm_perf_reset();
			}
		}
		if (c && c == last && dumps < 0) { slog("SweetMTL: STALL at commit %u, threads:", c); sm_dump_threads(); dumps++; }
		last = c;
	}
	return NULL;
}


/* ------------------------------------------------------------------ SpringBoard diagnostics
 * The home screen showed a black rectangle: backboardd received an opaque 1105x1160 image (and a 1271x1823 one) whose
 * shared-memory pixels were all zero, made by a client process (run131). SpringBoard gets no Metal device, but the
 * bundle is loaded there: log which layers get large image contents and whether those images are empty. */
static IMP sm_orig_setContents, sm_orig_renderInContext, sm_orig_drawHier, sm_orig_drawInContext, sm_orig_display;
static const char *sm_cls(id o);
/* big CPU-drawn layers (backing stores never go through -setContents:) */
static void sm_sb_drawInContext(id self, SEL _cmd, void *ctx)
{
	CGRect b = ((CGRect (*)(id, SEL))objc_msgSend)(self, @selector(bounds));
	double sc = ((double (*)(id, SEL))objc_msgSend)(self, @selector(contentsScale));
	((void (*)(id, SEL, void *))sm_orig_drawInContext)(self, _cmd, ctx);
	if (b.size.width * sc < 900 && b.size.height * sc < 900) return;
	BOOL op = ((BOOL (*)(id, SEL))objc_msgSend)(self, @selector(isOpaque));
	id dl = [self respondsToSelector:@selector(delegate)] ? [self performSelector:@selector(delegate)] : nil;
	static int nl; if (nl++ < 24) slog("SweetMTL: SB drawInContext %s delegate %s %.0fx%.0f@%.0f opaque %d", sm_cls(self), sm_cls(dl), b.size.width, b.size.height, sc, op);
}
static void sm_sb_display(id self, SEL _cmd)
{
	((void (*)(id, SEL))sm_orig_display)(self, _cmd);
	CGRect b = ((CGRect (*)(id, SEL))objc_msgSend)(self, @selector(bounds));
	double sc = ((double (*)(id, SEL))objc_msgSend)(self, @selector(contentsScale));
	if (b.size.width * sc < 900 && b.size.height * sc < 900) return;
	id dl = [self respondsToSelector:@selector(delegate)] ? [self performSelector:@selector(delegate)] : nil;
	BOOL op = ((BOOL (*)(id, SEL))objc_msgSend)(self, @selector(isOpaque));
	static int nl; if (nl++ < 24) slog("SweetMTL: SB display %s delegate %s %.0fx%.0f@%.0f opaque %d", sm_cls(self), sm_cls(dl), b.size.width, b.size.height, sc, op);
}
static const char *sm_cls(id o) { return o ? object_getClassName(o) : "-"; }
static void sm_sb_setContents(id self, SEL _cmd, id contents)
{
	((void (*)(id, SEL, id))sm_orig_setContents)(self, _cmd, contents);
	if (!contents) return;
	static unsigned long (*tid)(void); static size_t (*gw)(void *), (*gh)(void *), (*gbpr)(void *); static void *(*gdp)(void *); static CFDataRef (*cpy)(void *);
	static bool init;
	if (!init) { init = true; tid = dlsym(RTLD_DEFAULT, "CGImageGetTypeID"); gw = dlsym(RTLD_DEFAULT, "CGImageGetWidth"); gh = dlsym(RTLD_DEFAULT, "CGImageGetHeight");
		gbpr = dlsym(RTLD_DEFAULT, "CGImageGetBytesPerRow"); gdp = dlsym(RTLD_DEFAULT, "CGImageGetDataProvider"); cpy = dlsym(RTLD_DEFAULT, "CGDataProviderCopyData"); }
	CFTypeRef c = (__bridge CFTypeRef)contents;
	bool img = tid && CFGetTypeID(c) == tid();
	if (img && gw((void *)c) < 600 && gh((void *)c) < 600) return;   /* hot path: small images are not of interest */
	id dl = [self respondsToSelector:@selector(delegate)] ? [self performSelector:@selector(delegate)] : nil;
	id sup = [self respondsToSelector:@selector(superlayer)] ? [self performSelector:@selector(superlayer)] : nil;
	id sdl = sup && [sup respondsToSelector:@selector(delegate)] ? [sup performSelector:@selector(delegate)] : nil;
	NSString *nm = [self respondsToSelector:@selector(name)] ? [self performSelector:@selector(name)] : nil;
	if (img) {
		size_t w = gw((void *)c), h = gh((void *)c);
		int zero = -1; long nz = 0;
		CFDataRef d = cpy && gdp ? cpy(gdp((void *)c)) : NULL;
		if (d) { const uint8_t *b = CFDataGetBytePtr(d); CFIndex n = CFDataGetLength(d); for (CFIndex i = 0; i < n; i += 97) if (b[i]) nz++; zero = nz == 0; CFRelease(d); }
		static int nl; if (nl++ < 24) slog("SweetMTL: SB contents %zux%zu bpr %zu zero %d layer %s name %.30s delegate %s super %s/%s", w, h, gbpr ? gbpr((void *)c) : 0, zero,
		    sm_cls(self), nm ? nm.UTF8String : "-", sm_cls(dl), sm_cls(sup), sm_cls(sdl));
		if (zero == 1) { static int nb; if (nb++ < 2) { NSArray *st = [NSThread callStackSymbols]; for (NSUInteger i = 1; i < st.count && i < 16; i++) slog("SweetMTL: SB bt %.140s", [st[i] UTF8String]); } }
	} else {
		CGRect b = ((CGRect (*)(id, SEL))objc_msgSend)(self, @selector(bounds));
		double sc = ((double (*)(id, SEL))objc_msgSend)(self, @selector(contentsScale));
		if (b.size.width * sc < 600 && b.size.height * sc < 600) return;
		BOOL op = ((BOOL (*)(id, SEL))objc_msgSend)(self, @selector(isOpaque));
		static int nl; if (nl++ < 30) slog("SweetMTL: SB contents (%s) %.0fx%.0fpx opaque %d layer %.50s delegate %.50s super %.40s/%.40s", object_getClassName(contents),
		    b.size.width * sc, b.size.height * sc, op, sm_cls(self), sm_cls(dl), sm_cls(sup), sm_cls(sdl));
	}
}
static void sm_sb_renderInContext(id self, SEL _cmd, void *ctx)
{
	static int nl; if (nl++ < 16) { id dl = [self respondsToSelector:@selector(delegate)] ? [self performSelector:@selector(delegate)] : nil;
		slog("SweetMTL: SB renderInContext layer %s delegate %s", sm_cls(self), sm_cls(dl)); }
	((void (*)(id, SEL, void *))sm_orig_renderInContext)(self, _cmd, ctx);
}
static BOOL sm_sb_drawHier(id self, SEL _cmd, CGRect r, BOOL after)
{
	static int nl; if (nl++ < 16) slog("SweetMTL: SB drawViewHierarchy %s %.0fx%.0f after %d", sm_cls(self), r.size.width, r.size.height, after);
	return ((BOOL (*)(id, SEL, CGRect, BOOL))sm_orig_drawHier)(self, _cmd, r, after);
}
static void sm_sb_hooks(void)
{
	/* diagnostics only: boot-arg sweetdiag=1 */
	{ char ba[1024] = {0}; size_t bl = sizeof(ba) - 1; if (sysctlbyname("kern.bootargs", ba, &bl, NULL, 0) != 0 || !strstr(ba, "sweetdiag=1")) return; }
	Class L = NSClassFromString(@"CALayer"), V = NSClassFromString(@"UIView");
	Method m;
	if (L && (m = class_getInstanceMethod(L, @selector(setContents:)))) sm_orig_setContents = method_setImplementation(m, (IMP)sm_sb_setContents);
	if (L && (m = class_getInstanceMethod(L, NSSelectorFromString(@"renderInContext:")))) sm_orig_renderInContext = method_setImplementation(m, (IMP)sm_sb_renderInContext);
	if (V && (m = class_getInstanceMethod(V, NSSelectorFromString(@"drawViewHierarchyInRect:afterScreenUpdates:")))) sm_orig_drawHier = method_setImplementation(m, (IMP)sm_sb_drawHier);
	if (L && (m = class_getInstanceMethod(L, NSSelectorFromString(@"drawInContext:")))) sm_orig_drawInContext = method_setImplementation(m, (IMP)sm_sb_drawInContext);
	if (L && (m = class_getInstanceMethod(L, @selector(display)))) sm_orig_display = method_setImplementation(m, (IMP)sm_sb_display);
	slog("SweetMTL: SB hooks in %s: setContents %d renderInContext %d drawHier %d", getprogname(), sm_orig_setContents != NULL, sm_orig_renderInContext != NULL, sm_orig_drawHier != NULL);
}


/* ------------------------------------------------------------------ heaps
 * PosterBoard sizes heap textures with -newTextureLayoutWithDescriptor:isHeapOrBufferBacked: and allocates from MTLHeaps
 * (run136). Heap resources are plain independent allocations here (no aliasing); sizes are honest estimates. */
static uint64_t sm_tex_bytes(MTLTextureDescriptor *d)
{
	uint64_t bpr = ((uint64_t)d.width * sm_pf_bpp(d.pixelFormat) + 63) & ~63ULL, sz = bpr * (d.height ? d.height : 1);
	uint32_t bh = 0, bw = sm_astc(d.pixelFormat, &bh, NULL);
	if (bw) sz = (uint64_t)((d.width + bw - 1) / bw) * ((d.height + bh - 1) / bh) * 16;
	if (d.mipmapLevelCount > 1) sz = sz * 4 / 3;
	sz *= (d.arrayLength ? d.arrayLength : 1) * (d.depth ? d.depth : 1) * (d.textureType == MTLTextureTypeCube ? 6 : 1);
	return (sz + 0x3FFF) & ~0x3FFFULL;
}
@interface SweetMTLTextureLayout : SweetMTLObject
@property (nonatomic) NSUInteger size, alignment, watermark, rowBytes, pf, width, height;
@end
@implementation SweetMTLTextureLayout
/* PosterBoard decodes images on the CPU and lays them out into "texture memory" with these (run137); our textures are
 * linear with rowBytes = align64(width * bpp) (ASTC: block rows), so the layout is a row copy. */
- (void)initializeTextureMemory:(void *)m {}
- (void)finalizeTextureMemory:(void *)m {}
- (void)copyFromLinearBytes:(const void *)src linearOffset:(NSUInteger)lo linearBytesPerRow:(NSUInteger)lbpr linearBytesPerImage:(NSUInteger)lbpi
    toTextureMemory:(void *)dst textureSlice:(NSUInteger)sl textureLevel:(NSUInteger)lv textureRegion:(MTLRegion)r
{
	static int nl; if (nl++ < 6) slog("SweetMTL: texmem copy %lux%lu at %lu,%lu lbpr %lu -> rowBytes %lu slice %lu level %lu pf%lu", (unsigned long)r.size.width, (unsigned long)r.size.height,
	    (unsigned long)r.origin.x, (unsigned long)r.origin.y, (unsigned long)lbpr, (unsigned long)self.rowBytes, (unsigned long)sl, (unsigned long)lv, (unsigned long)self.pf);
	if (!src || !dst || sl || lv) return;
	uint32_t bh = 0, bw = sm_astc(self.pf, &bh, NULL);
	NSUInteger x0 = r.origin.x, y0 = r.origin.y, w = r.size.width, h = r.size.height, bpp = sm_pf_bpp(self.pf);
	if (bw) { x0 /= bw; y0 /= bh; w = (w + bw - 1) / bw; h = (h + bh - 1) / bh; bpp = 16; }
	NSUInteger n = w * bpp; if (n > lbpr && lbpr) n = lbpr;
	for (NSUInteger y = 0; y < h; y++) memcpy((uint8_t *)dst + (y0 + y) * self.rowBytes + x0 * bpp, (const uint8_t *)src + lo + y * lbpr, n);
}
- (void)forwardInvocation:(NSInvocation *)inv
{
	/* unknown selector on a layout: log its full name (selectors here are long) */
	const char *sn = sel_getName(inv.selector); size_t L = strlen(sn);
	static int nl; if (nl++ < 6) for (size_t o = 0; o < L; o += 100) slog("SweetMTL: texmem sel %.100s", sn + o);
	[super forwardInvocation:inv];
}
@end
@interface SweetMTLHeap : SweetMTLObject
@property (nonatomic) NSUInteger size, usedSize;
@property (nonatomic) MTLStorageMode storageMode;
@property (nonatomic) MTLCPUCacheMode cpuCacheMode;
@property (nonatomic) MTLHazardTrackingMode hazardTrackingMode;
@property (nonatomic) MTLResourceOptions resourceOptions;
@property (nonatomic) MTLHeapType type;
@property (nonatomic, weak) id dev;
@end
@implementation SweetMTLHeap
- (NSUInteger)currentAllocatedSize { return self.size; }
- (NSUInteger)maxAvailableSizeWithAlignment:(NSUInteger)a { return self.size > self.usedSize ? self.size - self.usedSize : 0; }
- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)d { self.usedSize += sm_tex_bytes(d); return [self.dev newTextureWithDescriptor:d]; }
- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)off { return [self newTextureWithDescriptor:d]; }
- (id)newBufferWithLength:(NSUInteger)len options:(MTLResourceOptions)o { self.usedSize += (len + 0x3FFF) & ~(NSUInteger)0x3FFF; return [self.dev newBufferWithLength:len options:o]; }
- (id)newBufferWithLength:(NSUInteger)len options:(MTLResourceOptions)o offset:(NSUInteger)off { return [self newBufferWithLength:len options:o]; }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)st { return MTLPurgeableStateNonVolatile; }
@end

@interface SweetMTLDevice : _MTLDevice <MTLDevice, MTLDeviceSPI>
@end

@implementation SweetMTLDevice {
	uint32_t _smPort;
}

/* Lock-screen poster extensions (AegirPoster = Astronomy) abort without a Metal device (run47). They get one,
 * but with the GPU switched off: their shaders are not translated yet and a GPU fault there would spend the
 * kernel's fault budget that backboardd needs. */
static bool sm_is_poster(const char *pn) { return pn && !strcmp(pn, "AegirPoster"); }   /* others (PridePoster: MPS) not yet */

/* Which processes get our Metal device. sweetmetal=2: the render server only (app content is composited by
 * backboardd; SpringBoard's own Metal users such as SiriUICore crashed on shaders we cannot translate, run44);
 * sweetmetal=4: every process. */
static bool sm_process_allowed(void)
{
	static int all = -1;
	if (all < 0) {
		char ba[1024] = {0}; size_t bl = sizeof(ba) - 1;
		bool ok = sysctlbyname("kern.bootargs", ba, &bl, NULL, 0) == 0;
		all = ok && strstr(ba, "sweetmetal=4") ? 2 : ok && strstr(ba, "sweetmetal=2") ? 1 : 0;
	}
	const char *pn = getprogname();
	/* PosterBoard: refused, it left the home screen's wallpaper images all zero (opaque black rectangle, runs 128-135) */
	return pn && (!strcmp(pn, "malitest") || (all >= 1 && (!strcmp(pn, "backboardd") || sm_is_poster(pn) || !strcmp(pn, "PosterBoard"))) || all == 2);
}

static IMP sm_orig_nextDrawable, sm_orig_setPF;
static id sm_nextDrawable(id self, SEL _cmd)
{
	id d = ((id (*)(id, SEL))sm_orig_nextDrawable)(self, _cmd);
	static int nl;
	if (nl++ < 6) {
		id t = d ? [d texture] : nil;
		slog("SweetMTL: layer nextDrawable -> %s tex %s %lux%lu pf%lu", d ? object_getClassName(d) : "nil", t ? object_getClassName(t) : "-",
		    t ? (unsigned long)[t width] : 0, t ? (unsigned long)[t height] : 0, t ? (unsigned long)[t pixelFormat] : 0);
	}
	return d;
}
static void sm_setPF(id self, SEL _cmd, NSUInteger pf)
{
	slog("SweetMTL: layer setPixelFormat %lu", (unsigned long)pf);
	((void (*)(id, SEL, NSUInteger))sm_orig_setPF)(self, _cmd, pf);
}
static void sm_layer_hooks(void)
{
	Class c = NSClassFromString(@"CAMetalLayer");
	if (!c) return;
	Method m = class_getInstanceMethod(c, @selector(nextDrawable));
	if (m) sm_orig_nextDrawable = method_setImplementation(m, (IMP)sm_nextDrawable);
	m = class_getInstanceMethod(c, @selector(setPixelFormat:));
	if (m) sm_orig_setPF = method_setImplementation(m, (IMP)sm_setPF);
}

+ (void)load
{
	/* refused processes stay silent: their crash reports filled the 128 KiB pmsg log (run47, AegirPoster) */
	if (!sm_process_allowed()) { if (getprogname()) sm_sb_hooks(); return; }   /* every refused process gets the layer diagnostics */
	if (sm_is_poster(getprogname())) sm_layer_hooks();
	if (strcmp(getprogname(), "backboardd") && strcmp(getprogname(), "malitest")) sm_sb_hooks();   /* who sets the empty 1105x1160 image */
	sm_fc_hook();
	if (getprogname() && strcmp(getprogname(), "malitest")) { sm_diag_install(); sm_trace_install(self); }
	slog("SweetMTL: +load in %s, super=%s", getprogname() ? getprogname() : "?", class_getName(class_getSuperclass(self)));
}

- (instancetype)initWithAcceleratorPort:(uint32_t)port
{
	const char *pn = getprogname();
	if (!sm_process_allowed()) {
		/* never let ARC release this half-built object: _MTLDevice -dealloc on an uninitialised device crashed
		 * inside Metal (run45, SpringBoard). One small leak per refused process. */
		(void)CFBridgingRetain(self);
		{ static int nl; if (!nl++) slog("SweetMTL: refused device for %s", pn ? pn : "?"); }   /* one line per refused process */
		return nil;
	}
	slog("SweetMTL: initWithAcceleratorPort:%u in %s avail %zuMB", port, pn ? pn : "?", sm_avail() >> 20);
	{
		/* no RTC driver: the calendar starts in 1969 (Astronomy then draws the night side). Set it once from the time
		 * the Mac wrote into the rootfs; backboardd runs as root. */
		static bool done; struct timeval now; gettimeofday(&now, NULL);
		if (!done && now.tv_sec < 1700000000L) {
			done = true;
			FILE *f = fopen("/usr/local/etc/sweet_epoch", "r"); long e = 0;
			if (f) { if (fscanf(f, "%ld", &e) != 1) e = 0; fclose(f); }
			int r = -2, er = 0;
			if (e > 1700000000L) { struct timeval tv = { e, 0 }; r = settimeofday(&tv, NULL); er = r ? errno : 0; }
			gettimeofday(&now, NULL);
			slog("SweetMTL: clock set to %ld by %s: %d errno %d, now %ld", e, pn ? pn : "?", r, er, (long)now.tv_sec);
		}
	}

	self = [super init];
	slog("SweetMTL: super init -> %p", self);
	if (self) {
		_smPort = port; sm_device = self;
		static dispatch_once_t wonce;
		if (pn && strcmp(pn, "malitest")) dispatch_once(&wonce, ^{ pthread_t t; pthread_create(&t, NULL, sm_watchdog, NULL); pthread_detach(t); });
	}
	return self;
}

- (instancetype)initWithAcceleratorPort:(uint32_t)port options:(id)options
{
	return [self initWithAcceleratorPort:port];
}

- (instancetype)initWithAcceleratorPort:(uint32_t)port simultaneousInstances:(BOOL)simul
{
	return [self initWithAcceleratorPort:port];
}

- (NSString *)name { return @"Sweet Mali-G78 MP14"; }
- (NSUInteger)maxBufferLength { return 256u << 20; }
- (NSUInteger)featureProfile { return 0; }
- (id)newCommandQueue { return [SweetMTLCommandQueue new]; }
- (id)newCommandQueueWithMaxCommandBufferCount:(NSUInteger)n { return [SweetMTLCommandQueue new]; }
- (id)newComputePipelineStateWithFunction:(id)f error:(NSError **)err
{
	if (err) *err = nil;
	SweetMTLComputePipelineState *ps = [SweetMTLComputePipelineState new];
	NSString *n = [f respondsToSelector:@selector(name)] ? [f name] : nil;
	ps.fnName = n ?: @"?"; ps.cs = sm_find(n);
	slog("SweetMTL: compute pipeline %s (%s, from %s)", ps.fnName.UTF8String, ps.cs ? "translated" : "NOT in pack", object_getClassName(f));
	return ps;
}
- (id)newComputePipelineStateWithFunction:(id)f options:(NSUInteger)o reflection:(id *)r error:(NSError **)err
{
	if (r) *r = nil;
	return [self newComputePipelineStateWithFunction:f error:err];
}
- (void)newComputePipelineStateWithFunction:(id)f completionHandler:(void (^)(id, NSError *))h
{
	id ps = [self newComputePipelineStateWithFunction:f error:NULL]; if (h) h(ps, nil);
}
- (void)newComputePipelineStateWithFunction:(id)f options:(NSUInteger)o completionHandler:(void (^)(id, id, NSError *))h
{
	id ps = [self newComputePipelineStateWithFunction:f error:NULL]; if (h) h(ps, nil, nil);
}
- (id)newComputePipelineStateWithDescriptor:(id)d options:(NSUInteger)o reflection:(id *)r error:(NSError **)err
{
	if (r) *r = nil;
	id f = [d respondsToSelector:@selector(computeFunction)] ? [d computeFunction] : nil;
	return [self newComputePipelineStateWithFunction:f error:err];
}
- (id)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d error:(NSError **)err
{
	if (err) *err = nil;
	SweetMTLRenderPipelineState *ps = [SweetMTLRenderPipelineState new];
	ps.vsName = d.vertexFunction.name; ps.fsName = d.fragmentFunction.name;
	ps.vs = sm_find(ps.vsName); ps.fs = sm_find(ps.fsName);
	for (id fobj in @[ d.vertexFunction ?: (id)[NSNull null], d.fragmentFunction ?: (id)[NSNull null] ]) {
		if (![fobj isKindOfClass:[SweetMTLFunction class]]) continue;
		bool isvs = fobj == (id)d.vertexFunction;   /* named constants: vertex function only for now (run40 hung with all) */
		[((SweetMTLFunction *)fobj).constants enumerateKeysAndObjectsUsingBlock:^(NSNumber *k, NSNumber *v, BOOL *stop) {
			NSUInteger i;
			if ([k isKindOfClass:[NSNumber class]]) i = k.unsignedIntegerValue;
			else if ([k isKindOfClass:[NSString class]]) { if (!isvs && !sm_is_poster(getprogname())) return; NSNumber *m = sm_fc_names()[k]; if (!m) return; i = m.unsignedIntegerValue; }
			else return;
			if (i < 64) { ps->_fc[i] = v.unsignedIntValue; ps->_fcdef |= 1ull << i; }
		}];
	}
	MTLRenderPipelineColorAttachmentDescriptor *ca0 = d.colorAttachments[0];
	ps->_blend[0] = ca0.blendingEnabled; ps->_blend[1] = (uint32_t)ca0.rgbBlendOperation; ps->_blend[2] = (uint32_t)ca0.alphaBlendOperation;
	ps->_blend[3] = (uint32_t)ca0.sourceRGBBlendFactor; ps->_blend[4] = (uint32_t)ca0.destinationRGBBlendFactor;
	ps->_blend[5] = (uint32_t)ca0.sourceAlphaBlendFactor; ps->_blend[6] = (uint32_t)ca0.destinationAlphaBlendFactor;
	ps->_blend[7] = (uint32_t)ca0.writeMask;
	MTLVertexDescriptor *vd = d.vertexDescriptor;
	for (int i = 0; i < 16 && vd; i++) {
		ps->_attr[i].fmt = (uint32_t)vd.attributes[i].format;
		ps->_attr[i].off = (uint32_t)vd.attributes[i].offset;
		ps->_attr[i].bidx = (uint32_t)vd.attributes[i].bufferIndex;
	}
	for (int i = 0; i < 31 && vd; i++) ps->_stride[i] = (uint32_t)vd.layouts[i].stride;
	slog("SweetMTL: pipeline vs=%s(%s) fs=%s(%s)", ps.vsName.UTF8String ?: "-", ps.vs ? "ok" : "missing",
	    ps.fsName.UTF8String ?: "-", ps.fs ? "ok" : "fallback");
	return ps;
}
- (id)newDepthStencilStateWithDescriptor:(id)d { return [SweetMTLObject new]; }
- (id)newSamplerStateWithDescriptor:(MTLSamplerDescriptor *)d
{
	SweetMTLSampler *smp = [SweetMTLSampler new];
	smp.nearest = d.minFilter == MTLSamplerMinMagFilterNearest;
	/* address modes as asked (always clamp-to-edge before: CA's ClampToZero layer edges drew a seam, run146+) */
	uint32_t (^wm)(MTLSamplerAddressMode) = ^uint32_t(MTLSamplerAddressMode m) {
		switch (m) {
		case MTLSamplerAddressModeRepeat: return MALI_WRAP_MODE_REPEAT;
		case MTLSamplerAddressModeMirrorRepeat: return MALI_WRAP_MODE_MIRRORED_REPEAT;
		case MTLSamplerAddressModeMirrorClampToEdge: return MALI_WRAP_MODE_MIRRORED_CLAMP_TO_EDGE;
		case MTLSamplerAddressModeClampToZero: case MTLSamplerAddressModeClampToBorderColor: return MALI_WRAP_MODE_CLAMP_TO_BORDER;
		default: return MALI_WRAP_MODE_CLAMP_TO_EDGE;
		}
	};
	bool white = d.sAddressMode == MTLSamplerAddressModeClampToBorderColor && d.borderColor == MTLSamplerBorderColorOpaqueWhite;
	smp.wrap = wm(d.sAddressMode) | wm(d.tAddressMode) << 8 | wm(d.rAddressMode) << 16 | (white ? 1u << 24 : 0);
	{ static int nl; if (smp.wrap != (MALI_WRAP_MODE_CLAMP_TO_EDGE * 0x10101u) && nl++ < 6) slog("SweetMTL: sampler wrap %x nearest %u", smp.wrap, smp.nearest); }
	return smp;
}
- (id)newBufferWithLength:(NSUInteger)len options:(MTLResourceOptions)o { return [[SweetMTLBuffer alloc] initWithLength:len bytes:NULL]; }
- (id)newBufferWithBytes:(const void *)p length:(NSUInteger)len options:(MTLResourceOptions)o { return [[SweetMTLBuffer alloc] initWithLength:len bytes:p]; }
- (id)newBufferWithBytesNoCopy:(void *)p length:(NSUInteger)len options:(MTLResourceOptions)o deallocator:(void (^)(void *, NSUInteger))d
{
	return [[SweetMTLBuffer alloc] initWithBytesNoCopy:p length:len deallocator:d];
}
/* CoreAnimation hands decoded CGImage bytes (the wallpaper snapshot among them) to the GPU this way (run91) */
- (id)newTextureWithBytesNoCopy:(void *)p length:(NSUInteger)len descriptor:(MTLTextureDescriptor *)d deallocator:(void (^)(void *, NSUInteger))dl
{
	uint32_t abh = 0, abw = sm_astc(d.pixelFormat, &abh, NULL);
	if (abw) {
		/* compressed (the wallpaper snapshot is ASTC 4x4, run92): decoded on the CPU like any ASTC upload, then the
		 * client memory is not needed any more */
		SweetMTLTexture *t = [self newTextureWithDescriptor:d];
		NSUInteger bbpr = (d.width + abw - 1) / abw * 16;
		if (t) { [t sm_setLazy:p length:len bytesPerRow:bbpr deallocator:dl]; dl = nil; }   /* decoded at draw time: CA fills the memory after this call */
		static int nl; if (nl++ < 8) slog("SweetMTL: buffer texture nocopy astc %lux%lu pf%lu len %lu -> %s", (unsigned long)d.width, (unsigned long)d.height,
		    (unsigned long)d.pixelFormat, (unsigned long)len, t ? "ok" : "FAILED");
		if (t && d.width >= 1000 && !sm_dbg_tex[1]) sm_dbg_tex[1] = t;
		if (dl) dl(p, len);
		return t;
	}
	NSUInteger h = d.height ? d.height : 1, bpr = len / h;
	NSUInteger minb = d.width * sm_pf_bpp(d.pixelFormat);
	if (bpr < minb || d.mipmapLevelCount > 1 || d.arrayLength > 1) bpr = minb;
	id b = [[SweetMTLBuffer alloc] initWithBytesNoCopy:p length:len deallocator:dl];
	id t = b ? [b newTextureWithDescriptor:d offset:0 bytesPerRow:bpr] : nil;
	static int nl; if (nl++ < 8) slog("SweetMTL: buffer texture nocopy %lux%lu pf%lu len %lu bpr %lu -> %s", (unsigned long)d.width, (unsigned long)d.height,
	    (unsigned long)d.pixelFormat, (unsigned long)len, (unsigned long)bpr, t ? "ok" : "FAILED");
	return t;
}
- (id)newLibraryWithURL:(NSURL *)url error:(NSError **)err { if (err) *err = nil; return [SweetMTLLibrary new]; }
- (id)newLibraryWithFile:(NSString *)path error:(NSError **)err { if (err) *err = nil; return [SweetMTLLibrary new]; }
- (id)newDefaultLibrary { return [SweetMTLLibrary new]; }
- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)d { return [[SweetMTLTexture alloc] initWithDevice:self descriptor:d]; }
- (id)newTextureLayoutWithDescriptor:(MTLTextureDescriptor *)d isHeapOrBufferBacked:(BOOL)hb
{
	static bool dumped;
	if (!dumped) {
		/* the texture-layout protocol is private: log its methods with type encodings (selectors split over lines) */
		dumped = true;
		{
			/* classes implementing the texture-memory methods (Metal / driver internals): full selectors + type encodings */
			unsigned nc = 0; Class *cl = objc_copyClassList(&nc); int nout = 0;
			for (unsigned i = 0; i < nc && nout < 40; i++) {
				unsigned nm = 0; Method *ml = class_copyMethodList(cl[i], &nm);
				for (unsigned k = 0; k < nm && nout < 40; k++) {
					const char *sn = sel_getName(method_getName(ml[k]));
					if (!strstr(sn, "TextureMemory") && !strstr(sn, "LinearBytes")) continue;
					nout++; size_t L = strlen(sn);
					for (size_t o = 0; o < L; o += 100) slog("SweetMTL: proto %s %.100s", class_getName(cl[i]), sn + o);
					slog("SweetMTL: proto types %.120s", method_getTypeEncoding(ml[k]) ? method_getTypeEncoding(ml[k]) : "-");
				}
				free(ml);
			}
			free(cl);
		}
		unsigned np = 0; Protocol * __unsafe_unretained *pl = objc_copyProtocolList(&np);
		for (unsigned i = 0; i < np; i++) {
			const char *pn = protocol_getName(pl[i]); if (!strstr(pn, "TextureLayout") && !strstr(pn, "TextureMemory")) continue;
			for (int req = 0; req < 2; req++) {
				unsigned nm = 0; struct objc_method_description *md = protocol_copyMethodDescriptionList(pl[i], req, YES, &nm);
				for (unsigned k = 0; k < nm; k++) {
					const char *sn = sel_getName(md[k].name); size_t L = strlen(sn);
					for (size_t o = 0; o < L; o += 100) slog("SweetMTL: proto %s %u.%zu %.100s", pn, k, o / 100, sn + o);
					slog("SweetMTL: proto %s %u types %.110s", pn, k, md[k].types ? md[k].types : "-");
				}
				free(md);
			}
		}
		free(pl);
	}
	SweetMTLTextureLayout *l = [SweetMTLTextureLayout new]; l.size = sm_tex_bytes(d); l.alignment = 0x4000; l.watermark = l.size;
	l.pf = d.pixelFormat; l.width = d.width; l.height = d.height;
	{ uint32_t bh = 0, bw = sm_astc(d.pixelFormat, &bh, NULL); l.rowBytes = bw ? (d.width + bw - 1) / bw * 16 : ((d.width * sm_pf_bpp(d.pixelFormat) + 63) & ~(NSUInteger)63); }
	static int nl; if (nl++ < 8) slog("SweetMTL: texmem layout %lux%lu pf%lu rowBytes %lu size %lu heap/buffer %d", (unsigned long)d.width, (unsigned long)d.height,
	    (unsigned long)d.pixelFormat, (unsigned long)l.rowBytes, (unsigned long)l.size, hb);
	return l;
}
- (MTLSizeAndAlign)heapTextureSizeAndAlignWithDescriptor:(MTLTextureDescriptor *)d { MTLSizeAndAlign r = { sm_tex_bytes(d), 0x4000 }; return r; }
- (MTLSizeAndAlign)heapBufferSizeAndAlignWithLength:(NSUInteger)len options:(MTLResourceOptions)o { MTLSizeAndAlign r = { (len + 0x3FFF) & ~(NSUInteger)0x3FFF, 0x4000 }; return r; }
- (id)newHeapWithDescriptor:(MTLHeapDescriptor *)hd
{
	SweetMTLHeap *h = [SweetMTLHeap new]; h.size = hd.size; h.storageMode = hd.storageMode; h.cpuCacheMode = hd.cpuCacheMode; h.type = MTLHeapTypeAutomatic; h.dev = self;
	h.resourceOptions = hd.resourceOptions; h.hazardTrackingMode = hd.hazardTrackingMode;
	static int nl; if (nl++ < 6) slog("SweetMTL: heap %lu bytes in %s", (unsigned long)hd.size, getprogname());
	return h;
}
- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)d iosurface:(IOSurfaceRef)ios plane:(NSUInteger)plane
{
	return [[SweetMTLTexture alloc] initWithDevice:self descriptor:d iosurface:ios plane:plane];
}
- (uint64_t)registryID { return 0x53574545; }
- (NSString *)vendorName { return @"ARM"; }
/* render targets are RGBA8/BGRA8 only for now: keep CoreAnimation off the 10-bit extended-range formats */
/* poster extensions draw into XR CAMetalLayers and throw "unsupported extended range format" otherwise (run61);
 * XR formats are stored as 8-bit BGRA here. backboardd keeps NO, as tested. */
- (BOOL)supportsExtendedXR10Formats { return sm_is_poster(getprogname()); }
- (BOOL)supportsPublicXR10Formats { return sm_is_poster(getprogname()); }
- (BOOL)supportsBGR10A2 { return NO; }
- (BOOL)supportsRGBA10A2Gamma { return NO; }
- (BOOL)supportsYCBCRPackedFormats12 { return NO; }
- (BOOL)supportsExtendedYUVFormats { return NO; }
- (BOOL)supportsCompressedTextureViewSPI { return NO; }
- (BOOL)supportsMemorylessRenderTargets { return NO; }
- (BOOL)supportsProgrammableBlending { return NO; }
- (BOOL)supportsImageBlocks { return NO; }
- (BOOL)supportsTileShaders { return NO; }
- (BOOL)supportsRasterOrderGroups { return NO; }
- (NSUInteger)maxTextureWidth2D { return 8192; }
- (NSUInteger)maxTextureHeight2D { return 8192; }
- (NSUInteger)maxTextureWidth3D { return 2048; }
- (NSUInteger)maxTextureHeight3D { return 2048; }
- (NSUInteger)maxTextureDepth3D { return 2048; }
- (NSUInteger)maxTextureDimensionCube { return 8192; }
- (NSUInteger)maxTextureArrayLayers { return 2048; }
- (NSUInteger)maxColorAttachments { return 8; }
- (NSUInteger)maxFragmentTextures { return 16; }
- (NSUInteger)maxVertexTextures { return 16; }
- (NSUInteger)maxFragmentSamplers { return 16; }
- (NSUInteger)maxVertexSamplers { return 16; }
- (NSUInteger)maxFragmentBuffers { return 16; }
- (NSUInteger)maxVertexBuffers { return 16; }
- (NSUInteger)maxVertexAttributes { return 16; }
- (NSUInteger)maxThreadgroupMemoryLength { return 16384; }
- (NSUInteger)minConstantBufferAlignmentBytes { return 16; }
- (NSUInteger)minBufferNoCopyAlignmentBytes { return 16384; }
- (NSUInteger)iosurfaceReadOnlyTextureAlignmentBytes { return 16; }
- (NSUInteger)iosurfaceTextureAlignmentBytes { return 16; }
- (NSUInteger)linearTextureAlignmentBytes { return 64; }
- (NSUInteger)minimumLinearTextureAlignmentForPixelFormat:(MTLPixelFormat)f { return 64; }
- (BOOL)sm_featureSet:(NSUInteger)fs
{
	/* iOS GPU families 1-3 (no imageblocks / tile shaders, which the translator cannot do yet) */
	return fs <= 14 && fs != 11;
}
- (BOOL)supportsFeatureSet:(NSUInteger)fs { return [self sm_featureSet:fs]; }
- (BOOL)deviceSupportsFeatureSet:(NSUInteger)fs { return [self sm_featureSet:fs]; }
- (BOOL)deviceOrFeatureProfileSupportsFeatureSet:(NSUInteger)fs { return [self sm_featureSet:fs]; }
- (BOOL)supportsFamily:(NSInteger)fam { return fam == 1001 || fam == 1002 || fam == 1003 || fam == 3001; }
- (BOOL)supportsTextureSampleCount:(NSUInteger)n { return n == 1 || n == 4; }
- (BOOL)isLowPower { return NO; }
- (BOOL)isHeadless { return NO; }
- (BOOL)isRemovable { return NO; }
- (uint32_t)acceleratorPort { return _smPort; }

- (BOOL)respondsToSelector:(SEL)sel
{
	BOOL r = sel == @selector(targetDeviceInfo) ? NO : [super respondsToSelector:sel];
	static int nlog;
	if (nlog < 120) { nlog++; slog("SweetMTL: responds %s -> %d", sel_getName(sel), r); }
	return r;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
	NSMethodSignature *m = [super methodSignatureForSelector:sel];
	return m ? m : [NSMethodSignature signatureWithObjCTypes:"@@:@@@@"];
}

- (void)forwardInvocation:(NSInvocation *)inv
{
	static NSMutableSet *seen; static dispatch_once_t once; dispatch_once(&once, ^{ seen = [NSMutableSet new]; });
	NSString *k = @(sel_getName(inv.selector)); BOOL first = NO;
	@synchronized (seen) { if (![seen containsObject:k]) { [seen addObject:k]; first = YES; } }
	Method sm = sm_super_cls ? class_getInstanceMethod(sm_super_cls, inv.selector) : NULL;
	if (sm) {
		(void)first;   /* inherited-method discovery done; these lines filled the pmsg log */
		[inv invokeUsingIMP:method_getImplementation(sm)];
		return;
	}
	if (first) slog("SweetMTL: unimplemented -%s", k.UTF8String);
	sm_zero_return(inv);
}

@end
