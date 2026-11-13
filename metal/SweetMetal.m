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

typedef mach_port_t io_object_t, io_service_t, io_connect_t;
extern const mach_port_t kIOMasterPortDefault;
extern io_service_t IOServiceGetMatchingService(mach_port_t, CFDictionaryRef);
extern CFMutableDictionaryRef IOServiceMatching(const char *);
extern kern_return_t IOServiceOpen(io_service_t, task_port_t, uint32_t, io_connect_t *);
extern kern_return_t IOConnectCallMethod(io_connect_t, uint32_t, const uint64_t *, uint32_t,
    const void *, size_t, uint64_t *, uint32_t *, void *, size_t *);

static io_connect_t sm_conn;

static void slog(const char *fmt, ...)
{
	char b[150];
	va_list ap; va_start(ap, fmt); vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
	fprintf(stderr, "%s\n", b);
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

typedef struct { uint64_t handle, gpu; uint8_t *cpu; uint64_t size; uint32_t imported; } sm_bo;
/* BGRA8 and the 32-bit BGR10 XR display formats CoreAnimation renders into: everything is stored as 8-bit BGRA here,
 * consistently for rendering, sampling and the kernel's copy to the panel */
static inline bool sm_is_bgra(NSUInteger f) { return f == 80 || f == 81 || (f >= 550 && f <= 555); }
static volatile uint32_t sm_commits;
static uint64_t sm_next_va = 0x30000000ULL;

static bool sm_bo_alloc(sm_bo *bo, uint64_t size)
{
	if (!sm_conn) slog("SweetMTL: gpu connect");
	if (!sm_conn) return false;
	size = (size + 0xFFFF) & ~0xFFFFULL;
	uint64_t in[2] = { size }, out[2] = { 0 }; uint32_t oc = 2;
	if (IOConnectCallMethod(sm_conn, 1, in, 1, NULL, 0, out, &oc, NULL, NULL)) return false;
	mach_vm_address_t ua = 0; mach_vm_size_t us = 0;
	if (IOConnectMapMemory64(sm_conn, (uint32_t)out[0], mach_task_self(), &ua, &us, 1)) return false;
	in[0] = out[0]; in[1] = sm_next_va; oc = 0;
	if (IOConnectCallMethod(sm_conn, 2, in, 2, NULL, 0, NULL, &oc, NULL, NULL)) return false;
	bo->handle = out[0]; bo->gpu = sm_next_va; bo->cpu = (uint8_t *)ua; bo->size = size;
	sm_next_va += size + 0x10000;
	return true;
}

extern kern_return_t IOConnectUnmapMemory64(io_connect_t, uint32_t, task_port_t, mach_vm_address_t);
static void sm_bo_free(sm_bo *bo)
{
	if (!sm_conn || !bo->handle) return;
	if (!bo->imported && bo->cpu) IOConnectUnmapMemory64(sm_conn, (uint32_t)bo->handle, mach_task_self(), (mach_vm_address_t)bo->cpu);
	uint64_t in[1] = { bo->handle }; uint32_t oc = 0;
	IOConnectCallMethod(sm_conn, 4, in, 1, NULL, 0, NULL, &oc, NULL, NULL);
	memset(bo, 0, sizeof *bo);
}
/* Wire a range of this process's memory (an IOSurface) and map it into the GPU address space. */
static bool sm_bo_import(sm_bo *bo, void *uva, uint64_t len)
{
	if (!sm_conn) return false;
	uint64_t a0 = (uint64_t)uva & ~0x3FFFULL, a1 = ((uint64_t)uva + len + 0x3FFF) & ~0x3FFFULL;
	uint64_t in[3] = { a0, a1 - a0, sm_next_va }, out[1] = { 0 }; uint32_t oc = 1;
	kern_return_t kr = IOConnectCallMethod(sm_conn, 8, in, 3, NULL, 0, out, &oc, NULL, NULL);
	if (kr) { static int nl; if (nl++ < 6) slog("SweetMTL: import %llx+%llx failed %x", a0, a1 - a0, kr); return false; }
	bo->handle = out[0]; bo->gpu = sm_next_va + ((uint64_t)uva - a0); bo->cpu = uva; bo->size = len; bo->imported = 1;
	sm_next_va += (a1 - a0) + 0x10000;
	return true;
}
/* transient bytes (setVertexBytes & co): one ring, reused every pass */
static uint64_t sm_ring_put(const void *p, uint64_t len, uint8_t **cpu_out)
{
	static sm_bo ring; static bool have; static uint64_t off;
	if (!have) have = sm_bo_alloc(&ring, 8u << 20);
	if (!have || len > ring.size) return 0;
	off = (off + 255) & ~255ULL;
	if (off + len > ring.size) off = 0;
	if (p) memcpy(ring.cpu + off, p, len);
	if (cpu_out) *cpu_out = ring.cpu + off;
	uint64_t va = ring.gpu + off; off += len;
	return va;
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
static void sm_thumb(const uint8_t *c, uint32_t W, uint32_t H, uint32_t bpr, uint32_t id)
{
	if (!c) return;
	const uint32_t S = 12, w = W / S, h = H / S;
	uint32_t n = w * h; uint8_t *px = malloc(n);
	for (uint32_t y = 0; y < h; y++)
		for (uint32_t x = 0; x < w; x++) {
			uint32_t r = 0, g = 0, b = 0;
			for (uint32_t k = 0; k < 4; k++) {   /* average 4 samples in the cell */
				const uint8_t *q = c + (size_t)(y * S + (k >> 1) * 6) * bpr + (size_t)(x * S + (k & 1) * 6) * 4;
				b += q[0]; g += q[1]; r += q[2];
			}
			r >>= 2; g >>= 2; b >>= 2;
			px[y * w + x] = (uint8_t)((r & 0xE0) | ((g & 0xE0) >> 3) | (b >> 6));
		}
	slog("SweetMTL: THUMB %u %ux%u rgb332 %u bytes", id, w, h, n);
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
	free(px);
}

static uint32_t sm_submit(uint32_t slot, uint64_t jc)
{
	uint64_t in[3] = { slot, jc, 2000 }, out[1] = { 0xdead }; uint32_t oc = 1;
	kern_return_t kr = IOConnectCallMethod(sm_conn, 3, in, 3, NULL, 0, out, &oc, NULL, NULL);
	return kr ? 0xffff0000u | (uint32_t)kr : (uint32_t)out[0];
}

/* Clear a w x h RGBA8/BGRA8 colour target with one FRAGMENT job (no tiler). Returns the job status. */
static uint32_t sm_clear(sm_bo *desc, uint64_t target_va, uint32_t w, uint32_t h, uint32_t stride, uint32_t packed, bool bgra)
{
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
} sm_shader;
static sm_shader *sm_pack; static uint32_t sm_pack_n;

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
	uint64_t index_va; uint32_t index_type; int32_t base_vertex;
	uint32_t sc_x0, sc_y0, sc_x1, sc_y1, has_scissor;
	uint32_t blend_on, rgb_op, a_op, rgb_sf, rgb_df, a_sf, a_df, wmask;
	uint64_t buf[31];                /* GPU VA bound at each Metal vertex-stage buffer index */
	uint64_t fbuf[31];               /* fragment-stage buffers (separate push block) */
	struct { uint32_t fmt, off, bidx; } attr[16];
	uint32_t stride[31];
	struct { uint64_t va; uint32_t w, h, stride, fmt; } tex[8];
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
static uint32_t sm_pass(sm_bo *desc, sm_bo *heap, uint64_t target_va, uint32_t w, uint32_t h, uint32_t stride,
    uint32_t packed, bool bgra, const sm_drawrec *dr, uint32_t ndraw, uint32_t *vstatus, bool preload)
{
	if (preload) { const sm_shader *rs = sm_find(@"read_surf_frag"); if (!rs || rs->size > 0x300) preload = false; }
	uint8_t *cpu = desc->cpu;
	uint64_t D = desc->gpu;
	memset(cpu, 0, 0x1000);
	memset(heap->cpu, 0, heap->size);
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
		rt.writeback_format = MALI_COLOR_FORMAT_R8G8B8A8;
		rt.writeback_block_format = MALI_BLOCK_FORMAT_LINEAR; rt.writeback_msaa = MALI_MSAA_SINGLE;
		rt.swizzle = bgra ? (2 | (1 << 3) | (0 << 6) | (3 << 9)) : (0 | (1 << 3) | (2 << 6) | (3 << 9));
		rt.rgb.base = target_va; rt.rgb.row_stride = stride;
	}
	pan_pack(cpu + OFF_TLS, LOCAL_STORAGE, tl) { tl.wls_instances = MALI_LOCAL_STORAGE_NO_WORKGROUP_MEM; }
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
	if (!havedummy) havedummy = sm_bo_alloc(&dummy, 0x10000);
	if (preload) {
		/* loadAction = load: a pre-frame DCD runs read_surf_frag (texture 0 at the fragment position) over every tile */
		const sm_shader *ps = sm_find(@"read_surf_frag");
		uint8_t *Q = cpu + 0x1000; uint64_t QV = D + 0x1000;
		memset(Q, 0, 0x800);
		if (ps && ps->size <= 0x300) {
			memcpy(Q + 0x400, ps->bin, ps->size);
			sm_shader_desc(Q + 0x180, ps, MALI_SHADER_STAGE_FRAGMENT, QV + 0x400, ps->preload, ps->work_regs);
			uint32_t fmt = (MALI_RGBA8_UNORM << 12) | (bgra ? MALI_RGB_COMPONENT_ORDER_BGRA : MALI_RGB_COMPONENT_ORDER_RGBA);
			pan_pack(Q + 0x260, PLANE, pl) {
				pl.plane_type = MALI_PLANE_TYPE_GENERIC; pl.clump_format = MALI_CLUMP_FORMAT_RAW32; pl.clump_ordering = MALI_CLUMP_ORDERING_LINEAR;
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
	for (uint32_t i = 0; i < ndraw; i++) {
		const sm_drawrec *r = &dr[i];
		uint32_t base = 0x10000 + i * SM_DRAW_STRIDE;
		uint8_t *P = cpu + base; uint64_t PV = D + base;
		memset(P, 0, 0x1000);
		const sm_shader *vs = r->vs, *fs = r->fs;
		if (vs->size > 0x5000 || (fs && fs->size > 0xA000) || vs->cdata_size > 0x200 || (fs && fs->cdata_size > 0x200)) {
			slog("SweetMTL: shader too large for the draw slot (vs %u fs %u)", vs->size, fs ? fs->size : 0);
			continue;
		}
		uint64_t vs_bin = PV + 0x1000, fs_bin = PV + 0x6000;
		memcpy(P + 0x1000, vs->bin, vs->size);
		if (vs->cdata_size) memcpy(P + 0x600, vs->cdata, vs->cdata_size);
		if (fs && fs->cdata_size) memcpy(P + 0x800, fs->cdata, fs->cdata_size);
		uint32_t fs_preload_hi, fs_wr, fs_push;
		if (fs) { memcpy(P + 0x6000, fs->bin, fs->size); fs_preload_hi = 0; fs_wr = fs->work_regs; fs_push = fs->push_words; }
		else { memcpy(P + 0x6000, FS_GREEN, sizeof FS_GREEN); fs_wr = 32; fs_push = 0; }
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
			uint64_t va = bi < 31 && r->buf[bi] ? r->buf[bi] + r->attr[L].off : 0;
			uint32_t st = bi < 31 ? r->stride[bi] : 0;
			memcpy(push + SMP_ATTR + 16 * L, &va, 8); memcpy(push + SMP_ATTR + 16 * L + 8, &st, 4);
		}
		float vp[6] = { w * 0.5f, -(float)h * 0.5f, 1.0f, w * 0.5f, h * 0.5f, 0.0f };
		memcpy(push + SMP_VP, vp, sizeof vp);
		/* fragment stage: same push block but its own buffer table */
		memcpy(P + 0xE00, push, SMP_BYTES);
		/* unbound fragment buffers point at the zeroed dummy page instead of address 0 */
		for (int k = 0; k < 8; k++) { uint64_t v = r->fbuf[k] ? r->fbuf[k] : (havedummy ? dummy.gpu : 0); memcpy(P + 0xE00 + SMP_BUF + 8 * k, &v, 8); }
		/* fragment resources: SAMPLER table (3) x16 at 0xA00 (slot 15 = constexpr sampler), TEXTURE table (4) x8 at 0xC00
		 * (slot 7 = 1x1 null 2D, slot 6 = 1x1x1 null 3D, both pointing at the zeroed dummy page) */
		uint64_t res_va = 0;
		{
			for (uint32_t k = 0; k < 16; k++) {
				bool nearest = k < r->nsmp ? r->smp[k].nearest : false;
				pan_pack(P + 0xA00 + 32 * k, SAMPLER, sc) {
					sc.minify_nearest = nearest; sc.magnify_nearest = nearest;
					sc.normalized_coordinates = true;
					sc.wrap_mode_s = sc.wrap_mode_t = sc.wrap_mode_r = MALI_WRAP_MODE_CLAMP_TO_EDGE;
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
				pan_pack(P + 0xD00 + 32 * k, PLANE, pl) {
					pl.plane_type = MALI_PLANE_TYPE_GENERIC;
					pl.clump_format = MALI_CLUMP_FORMAT_RAW32;
					pl.clump_ordering = MALI_CLUMP_ORDERING_LINEAR;
					pl.pointer = va; pl.row_stride = ts; pl.size = real ? ts * th : 0x10000; pl.slice_stride = ts * th;
				}
				pan_pack(P + 0xC00 + 32 * k, TEXTURE, tx) {
					tx.dimension = is3d ? MALI_TEXTURE_DIMENSION_3D : MALI_TEXTURE_DIMENSION_2D;
					tx.format = fmt; tx.width = tw; tx.height = th;
					if (is3d) tx.depth = 16; else tx.sample_count = 1;
					tx.swizzle = 0 | (1 << 3) | (2 << 6) | (3 << 9);
					tx.levels = 1; tx.array_size = 1;
					tx.surfaces = PV + 0xD00 + 32 * k;
					tx.minimum_lod = 0; tx.maximum_lod = 0;
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
			cfg.draw_mode = MALI_DRAW_MODE_TRIANGLES; cfg.index_count = r->vcount;
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
		pan_section_pack(vj, MALLOC_VERTEX_JOB, DRAW, cfg) {
			cfg.allow_forward_pixel_to_kill = true; cfg.allow_forward_pixel_to_be_killed = true;
			cfg.pixel_kill_operation = MALI_PIXEL_KILL_FORCE_EARLY; cfg.zs_update_operation = MALI_PIXEL_KILL_FORCE_EARLY;
			cfg.sample_mask = 0xFFFF; cfg.single_sampled_lines = true; cfg.vertex_array.packet = true;
			cfg.minimum_z = 0.0f; cfg.maximum_z = 1.0f; cfg.depth_stencil = D + OFF_DS;
			cfg.render_target_mask = 1; cfg.blend = PV + 0x300; cfg.blend_count = 1;
			cfg.overdraw_alpha0 = true; cfg.overdraw_alpha1 = true;
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
		pan_section_pack(vj, MALLOC_VERTEX_JOB, HEADER, header) { header.type = MALI_JOB_TYPE_MALLOC_VERTEX; header.index = 1; }
		uint32_t vst = sm_submit(1, PV);
		uint32_t vexc = *(volatile uint32_t *)P;
		slog("SweetMTL: draw%u vs=%s fs=%s n=%u sec=%d nvar=%u job=%x exc=%x", i, vs->name, fs ? fs->name : "(FS_GREEN)",
		    r->vcount, sec, nvar, vst, vexc);
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
	if (vstatus) *vstatus = vs_all;
	pan_section_pack(cpu + OFF_FJOB, FRAGMENT_JOB, PAYLOAD, cfg) {
		cfg.bound_min_x = 0; cfg.bound_min_y = 0; cfg.bound_max_x = (w - 1) >> 4; cfg.bound_max_y = (h - 1) >> 4;
		cfg.tile_render_order = MALI_TILE_RENDER_ORDER_Z_ORDER; cfg.framebuffer = D + OFF_FBD;
	}
	pan_section_pack(cpu + OFF_FJOB, FRAGMENT_JOB, HEADER, header) { header.type = MALI_JOB_TYPE_FRAGMENT; header.index = 1; }
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

@interface SweetMTLBuffer : SweetMTLObject
@property (nonatomic, readonly) NSUInteger length;
@end
@implementation SweetMTLBuffer { sm_bo _bo; }
- (instancetype)initWithLength:(NSUInteger)len bytes:(const void *)p
{
	self = [super init];
	if (!sm_bo_alloc(&_bo, len ? len : 16)) return nil;
	_length = len;
	if (p) memcpy(_bo.cpu, p, len);
	return self;
}
- (void)dealloc { sm_bo_free(&_bo); }
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
@interface SweetMTLTexture : SweetMTLObject
@property (nonatomic, readonly) NSUInteger width, height, pixelFormat, bytesPerRow;
@property (nonatomic, readonly) sm_bo *bo;
@property (nonatomic, weak) id device;
@end
@implementation SweetMTLTexture { sm_bo _store; IOSurfaceRef _surface; }
- (instancetype)initWithDevice:(id)dev descriptor:(MTLTextureDescriptor *)d
{
	self = [super init];
	_device = dev; _width = d.width; _height = d.height; _pixelFormat = d.pixelFormat; _bytesPerRow = _width * 4;
	if (!sm_bo_alloc(&_store, _bytesPerRow * _height)) {
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
	if (!base || !sm_bo_import(&_store, base, (uint64_t)_bytesPerRow * _height)) return nil;
	_surface = ios; CFRetain(ios);
	_bo = &_store;
	static int nl; if (nl++ < 8) slog("SweetMTL: iosurface %u %lux%lu bpr %lu fmt %lu -> gpu %llx", IOSurfaceGetID(ios),
	    (unsigned long)_width, (unsigned long)_height, (unsigned long)_bytesPerRow, (unsigned long)_pixelFormat, _store.gpu);
	return self;
}
- (void)dealloc { sm_bo_free(&_store); if (_surface) CFRelease(_surface); }
- (IOSurfaceRef)iosurface { return _surface; }
- (NSUInteger)iosurfacePlane { return 0; }
- (MTLStorageMode)storageMode { return MTLStorageModeShared; }
- (MTLTextureUsage)usage { return MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget; }
- (uint32_t)maliFormat
{
	bool bgra = sm_is_bgra(_pixelFormat);
	return (MALI_RGBA8_UNORM << 12) | (bgra ? MALI_RGB_COMPONENT_ORDER_BGRA : MALI_RGB_COMPONENT_ORDER_RGBA);
}
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
- (uint8_t *)sm_cpu { return _store.cpu; }
- (void)getBytes:(void *)dst bytesPerRow:(NSUInteger)bpr fromRegion:(MTLRegion)r mipmapLevel:(NSUInteger)lvl
{
	if (![self sm_inRegion:r level:lvl]) return;
	for (NSUInteger y = 0; y < r.size.height; y++)
		memcpy((uint8_t *)dst + y * bpr, _store.cpu + (r.origin.y + y) * _bytesPerRow + r.origin.x * 4, r.size.width * 4);
}
- (void)replaceRegion:(MTLRegion)r mipmapLevel:(NSUInteger)lvl withBytes:(const void *)src bytesPerRow:(NSUInteger)bpr
{
	if (![self sm_inRegion:r level:lvl] || !src) return;
	for (NSUInteger y = 0; y < r.size.height; y++)
		memcpy(_store.cpu + (r.origin.y + y) * _bytesPerRow + r.origin.x * 4, (const uint8_t *)src + y * bpr, r.size.width * 4);
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
@end
@implementation SweetMTLSampler
@end

@interface SweetMTLCommandBuffer : SweetMTLObject
@property (nonatomic, strong) NSMutableArray *passes;
@property (nonatomic) NSUInteger status;
@property (nonatomic) uint32_t lastJobStatus;
@property (nonatomic, weak) id commandQueue;
@property (nonatomic, strong) NSMutableArray *scheduled, *completed;
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
	uint32_t _ndraw;
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
	if (i < 8) { _tex[i] = t; if (t) [_keep addObject:t]; }
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
	if (type != MTLPrimitiveTypeTriangle) {
		static int nl; if (nl++ < 4) slog("SweetMTL: draw type %lu not supported yet", (unsigned long)type);
		return NULL;
	}
	if (_ndraw >= 32) { static int nl; if (nl++ < 4) slog("SweetMTL: too many draws in one pass"); return NULL; }
	sm_drawrec *r = &_draws[_ndraw];
	memset(r, 0, sizeof *r);
	if (_hasScissor && _target) {
		uint32_t W = (uint32_t)_target.width, H = (uint32_t)_target.height;
		uint32_t x0 = (uint32_t)_scissor.x, y0 = (uint32_t)_scissor.y;
		uint32_t x1 = (uint32_t)(_scissor.x + _scissor.width), y1 = (uint32_t)(_scissor.y + _scissor.height);
		if (x1 > W) x1 = W;
		if (y1 > H) y1 = H;
		if (x0 >= x1 || y0 >= y1) return NULL;  /* empty scissor: nothing to draw */
		r->has_scissor = 1; r->sc_x0 = x0; r->sc_y0 = y0; r->sc_x1 = x1 - 1; r->sc_y1 = y1 - 1;
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
		if (t) {
			r->tex[k].va = t.bo->gpu; r->tex[k].w = (uint32_t)t.width; r->tex[k].h = (uint32_t)t.height;
			r->tex[k].stride = (uint32_t)t.bytesPerRow; r->tex[k].fmt = [t maliFormat];
			r->ntex = k + 1;
		}
		if (_smp[k]) { r->smp[k].nearest = _smp[k].nearest; r->nsmp = k + 1; }
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
@interface SweetMTLBlitEncoder : SweetMTLStubEncoder
@end
@implementation SweetMTLBlitEncoder
- (void)copyFromTexture:(id)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)sz
    toTexture:(id)dst destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)dO
{
	if (![src isKindOfClass:NSClassFromString(@"SweetMTLTexture")] || ![dst isKindOfClass:NSClassFromString(@"SweetMTLTexture")]) return;
	if (ss || sl || ds || dl) return;
	NSUInteger sw = [src width], sh = [src height], dw = [dst width], dh = [dst height];
	if (so.x + sz.width > sw || so.y + sz.height > sh || dO.x + sz.width > dw || dO.y + sz.height > dh) return;
	uint8_t *sp = [src sm_cpu], *dp = [dst sm_cpu];
	NSUInteger sb = [src bytesPerRow], db = [dst bytesPerRow];
	if (!sp || !dp) return;
	for (NSUInteger y = 0; y < sz.height; y++)
		memmove(dp + (dO.y + y) * db + dO.x * 4, sp + (so.y + y) * sb + so.x * 4, sz.width * 4);
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
	if ([b respondsToSelector:@selector(contents)] && [b length] >= NSMaxRange(r)) memset((uint8_t *)[b contents] + r.location, v, r.length);
}
- (void)copyFromBuffer:(id)s sourceOffset:(NSUInteger)so toBuffer:(id)d destinationOffset:(NSUInteger)dof size:(NSUInteger)n
{
	if ([s length] >= so + n && [d length] >= dof + n) memmove((uint8_t *)[d contents] + dof, (uint8_t *)[s contents] + so, n);
}
@end
@interface SweetMTLCommandQueue : SweetMTLObject
@property (nonatomic, strong) dispatch_queue_t submissionQueue, completionQueue;
@end
@implementation SweetMTLCommandBuffer
- (instancetype)init { self = [super init]; _passes = [NSMutableArray array]; _scheduled = [NSMutableArray array]; _completed = [NSMutableArray array]; return self; }
- (void)addScheduledHandler:(void (^)(id))h { if (h) [_scheduled addObject:[h copy]]; }
- (void)addCompletedHandler:(void (^)(id))h { if (h) [_completed addObject:[h copy]]; }
- (id)blitCommandEncoder { return [SweetMTLBlitEncoder new]; }
- (id)blitCommandEncoderWithDescriptor:(id)d { return [SweetMTLBlitEncoder new]; }
- (id)computeCommandEncoder { return [SweetMTLStubEncoder new]; }
- (id)computeCommandEncoderWithDispatchType:(NSUInteger)t { return [SweetMTLStubEncoder new]; }
- (id)computeCommandEncoderWithDescriptor:(id)d { return [SweetMTLStubEncoder new]; }
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
	[_passes addObject:e];
	return e;
}
- (void)commit
{
	static sm_bo desc; static bool have;
	if (!have) have = sm_bo_alloc(&desc, 0x10000 + 32 * SM_DRAW_STRIDE);
	_status = 4; /* MTLCommandBufferStatusCompleted */
	sm_commits++;
	for (SweetMTLRenderEncoder *e in _passes) {
		if (!have || !e.target) { _status = 5; continue; }
		bool bgra = sm_is_bgra(e.target.pixelFormat);
		if (e->_ndraw) {
			static sm_bo heap; static bool haveheap;
			if (!haveheap) haveheap = sm_bo_alloc(&heap, 4u << 20);
			if (!haveheap) { _status = 5; continue; }
			bool generic = true;
			for (uint32_t i = 0; i < e->_ndraw; i++) if (!e->_draws[i].vs) generic = false;
			uint32_t vs = 0;
			if (generic) {
				_lastJobStatus = sm_pass(&desc, &heap, e.target.bo->gpu, (uint32_t)e.target.width, (uint32_t)e.target.height,
				    (uint32_t)e.target.bytesPerRow, e.packed, bgra, e->_draws, e->_ndraw, &vs, e.load);
			} else {
				/* no translated vertex shader: fixed Mesa shaders (phase 2b) */
				uint32_t n = 0; for (uint32_t i = 0; i < e->_ndraw; i++) n += e->_draws[i].vcount;
				_lastJobStatus = sm_draw(&desc, &heap, e.target.bo->gpu, (uint32_t)e.target.width, (uint32_t)e.target.height,
				    (uint32_t)e.target.bytesPerRow, e.packed, bgra, n, &vs);
			}
			slog("SweetMTL: pass %u draws (%s) load=%d clear=%d blend0=%u vertex=%x fragment=%x", e->_ndraw, generic ? "translated" : "fixed", e.load, e.clear, e->_draws[0].blend_on ? (e->_draws[0].rgb_sf << 8 | e->_draws[0].rgb_df) : 0, vs, _lastJobStatus);
			static int nbis;
			if (generic && _lastJobStatus && nbis++ < 3) {
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
				}
				uint32_t v0 = 0;
				uint32_t f0 = sm_pass(&desc, &heap, e.target.bo->gpu, (uint32_t)e.target.width, (uint32_t)e.target.height,
				    (uint32_t)e.target.bytesPerRow, e.packed, bgra, e->_draws, e->_ndraw, &v0, e.load);
				slog("SweetMTL: bisect pass%d full replay %x/%x", nbis, v0, f0);
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
				if (nsamp == 1 || nsamp == 3) sm_thumb(c, W, H, bpr, (uint32_t)nsamp);
				slog("SweetMTL: target %ux%u fmt %lu nz=%u/16 hash=%08x diag %08x %08x %08x %08x", W, H, (unsigned long)e.target.pixelFormat, nz, hsh, px[0], px[1], px[2], px[3]);
			}
			if (_lastJobStatus != 0 || vs != 0) _status = 5;
		} else if (e.clear) {
			_lastJobStatus = sm_clear(&desc, e.target.bo->gpu, (uint32_t)e.target.width, (uint32_t)e.target.height,
			    (uint32_t)e.target.bytesPerRow, e.packed, bgra);
			slog("SweetMTL: clear %lux%lu job status=%x", (unsigned long)e.target.width, (unsigned long)e.target.height, _lastJobStatus);
			if (_lastJobStatus != 0) _status = 5;
		}
	}
	[self sm_runHandlers];
}
- (void)waitUntilCompleted {}
- (void)commitAndWaitUntilSubmitted { [self commit]; }
- (void)setProtectionOptions:(uint64_t)o {}
- (uint64_t)protectionOptions { return 0; }
- (void)presentDrawable:(id)d {}
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
static void *sm_watchdog(void *arg)
{
	uint32_t last = 0; int dumps = 0;
	for (int t = 1;; t++) {
		sleep(10);
		uint32_t c = sm_commits;
		if (t % 3 == 0) slog("SweetMTL: alive %ds commits=%u", t * 10, c);
		if (c && c == last && dumps < 2) { slog("SweetMTL: STALL at commit %u, threads:", c); sm_dump_threads(); dumps++; }
		last = c;
	}
	return NULL;
}

@interface SweetMTLDevice : _MTLDevice <MTLDevice, MTLDeviceSPI>
@end

@implementation SweetMTLDevice {
	uint32_t _smPort;
}

+ (void)load
{
	sm_fc_hook();
	if (getprogname() && strcmp(getprogname(), "malitest")) { sm_diag_install(); sm_trace_install(self); }
	slog("SweetMTL: +load in %s, super=%s", getprogname() ? getprogname() : "?", class_getName(class_getSuperclass(self)));
}

- (instancetype)initWithAcceleratorPort:(uint32_t)port
{
	const char *pn = getprogname();
	slog("SweetMTL: initWithAcceleratorPort:%u in %s", port, pn ? pn : "?");
	static int all = -1;
	if (all < 0) {
		char ba[1024] = {0}; size_t bl = sizeof(ba) - 1;
		all = (sysctlbyname("kern.bootargs", ba, &bl, NULL, 0) == 0 && strstr(ba, "sweetmetal=2")) ? 1 : 0;
	}
	if (!all && (pn == NULL || strcmp(pn, "malitest") != 0)) {
		return nil;
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
- (id)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d error:(NSError **)err
{
	if (err) *err = nil;
	SweetMTLRenderPipelineState *ps = [SweetMTLRenderPipelineState new];
	ps.vsName = d.vertexFunction.name; ps.fsName = d.fragmentFunction.name;
	ps.vs = sm_find(ps.vsName); ps.fs = sm_find(ps.fsName);
	for (id fobj in @[ d.vertexFunction ?: (id)[NSNull null], d.fragmentFunction ?: (id)[NSNull null] ]) {
		if (![fobj isKindOfClass:[SweetMTLFunction class]]) continue;
		[((SweetMTLFunction *)fobj).constants enumerateKeysAndObjectsUsingBlock:^(NSNumber *k, NSNumber *v, BOOL *stop) {
			if (![k isKindOfClass:[NSNumber class]]) return;
			NSUInteger i = k.unsignedIntegerValue;
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
	return smp;
}
- (id)newBufferWithLength:(NSUInteger)len options:(MTLResourceOptions)o { return [[SweetMTLBuffer alloc] initWithLength:len bytes:NULL]; }
- (id)newBufferWithBytes:(const void *)p length:(NSUInteger)len options:(MTLResourceOptions)o { return [[SweetMTLBuffer alloc] initWithLength:len bytes:p]; }
- (id)newLibraryWithURL:(NSURL *)url error:(NSError **)err { if (err) *err = nil; return [SweetMTLLibrary new]; }
- (id)newLibraryWithFile:(NSString *)path error:(NSError **)err { if (err) *err = nil; return [SweetMTLLibrary new]; }
- (id)newDefaultLibrary { return [SweetMTLLibrary new]; }
- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)d { return [[SweetMTLTexture alloc] initWithDevice:self descriptor:d]; }
- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)d iosurface:(IOSurfaceRef)ios plane:(NSUInteger)plane
{
	return [[SweetMTLTexture alloc] initWithDevice:self descriptor:d iosurface:ios plane:plane];
}
- (uint64_t)registryID { return 0x53574545; }
- (NSString *)vendorName { return @"ARM"; }
/* render targets are RGBA8/BGRA8 only for now: keep CoreAnimation off the 10-bit extended-range formats */
- (BOOL)supportsExtendedXR10Formats { return NO; }
- (BOOL)supportsPublicXR10Formats { return NO; }
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
		if (first) slog("SweetMTL: inherited -%s", k.UTF8String);
		[inv invokeUsingIMP:method_getImplementation(sm)];
		return;
	}
	if (first) slog("SweetMTL: unimplemented -%s", k.UTF8String);
	sm_zero_return(inv);
}

@end
