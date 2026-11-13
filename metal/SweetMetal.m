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

typedef struct { uint64_t handle, gpu; uint8_t *cpu; uint64_t size; } sm_bo;
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
	uint64_t buf[31];                /* GPU VA bound at each Metal buffer index */
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

/* A whole render pass: clear + N draws (one MALLOC_VERTEX job each, shared tiler context) + one FRAGMENT job. */
static uint32_t sm_pass(sm_bo *desc, sm_bo *heap, uint64_t target_va, uint32_t w, uint32_t h, uint32_t stride,
    uint32_t packed, bool bgra, const sm_drawrec *dr, uint32_t ndraw, uint32_t *vstatus)
{
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
		cfg.pre_frame_0 = MALI_PRE_POST_FRAME_SHADER_MODE_NEVER;
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
		/* push constants (see air2nir.py ABI) */
		uint8_t *push = P + 0x400;
		{
			uint64_t cv = PV + 0x600, cf = PV + 0x800, dv = havedummy ? dummy.gpu : 0;
			memcpy(push + SMP_FCDEF, &r->fc_defined, 8);
			memcpy(push + SMP_CDATA_VS, &cv, 8); memcpy(push + SMP_CDATA_FS, &cf, 8); memcpy(push + SMP_DUMMY, &dv, 8);
			memcpy(push + SMP_FC, r->fc, sizeof r->fc);
		}
		for (int k = 0; k < 8; k++) memcpy(push + SMP_BUF + 8 * k, &r->buf[k], 8);
		for (int L = 0; L < 8; L++) {
			uint32_t bi = r->attr[L].bidx;
			uint64_t va = bi < 31 && r->buf[bi] ? r->buf[bi] + r->attr[L].off : 0;
			uint32_t st = bi < 31 ? r->stride[bi] : 0;
			memcpy(push + SMP_ATTR + 16 * L, &va, 8); memcpy(push + SMP_ATTR + 16 * L + 8, &st, 4);
		}
		float vp[6] = { w * 0.5f, -(float)h * 0.5f, 1.0f, w * 0.5f, h * 0.5f, 0.0f };
		memcpy(push + SMP_VP, vp, sizeof vp);
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
				uint32_t tw = real ? r->tex[k].w : 1, th = real ? r->tex[k].h : 1, ts = real ? r->tex[k].stride : 4;
				uint32_t fmt = real ? r->tex[k].fmt : ((MALI_RGBA8_UNORM << 12) | MALI_RGB_COMPONENT_ORDER_RGBA);
				pan_pack(P + 0xD00 + 32 * k, PLANE, pl) {
					pl.plane_type = MALI_PLANE_TYPE_GENERIC;
					pl.clump_format = MALI_CLUMP_FORMAT_RAW32;
					pl.clump_ordering = MALI_CLUMP_ORDERING_LINEAR;
					pl.pointer = va; pl.row_stride = ts; pl.size = ts * th; pl.slice_stride = ts * th;
				}
				pan_pack(P + 0xC00 + 32 * k, TEXTURE, tx) {
					tx.dimension = is3d ? MALI_TEXTURE_DIMENSION_3D : MALI_TEXTURE_DIMENSION_2D;
					tx.format = fmt; tx.width = tw; tx.height = th;
					if (is3d) tx.depth = 1; else tx.sample_count = 1;
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
			cfg.draw_mode = MALI_DRAW_MODE_TRIANGLES; cfg.index_count = r->vcount; cfg.base_vertex_offset = r->vstart;
			cfg.allow_rotating_primitives = true; cfg.secondary_shader = sec;
		}
		pan_section_pack(vj, MALLOC_VERTEX_JOB, INSTANCE_COUNT, cfg) { cfg.count = 1; }
		pan_section_pack(vj, MALLOC_VERTEX_JOB, ALLOCATION, cfg) {
			cfg.vertex_attribute_stride = sec ? 16 * nvar : 0;
			cfg.vertex_packet_stride = 16 + (sec ? 16 * nvar : 0);
		}
		pan_section_pack(vj, MALLOC_VERTEX_JOB, TILER, cfg) { cfg.address = D + OFF_TCTX; }
		pan_section_pack(vj, MALLOC_VERTEX_JOB, SCISSOR, cfg) {
			cfg.scissor_minimum_x = 0; cfg.scissor_minimum_y = 0; cfg.scissor_maximum_x = w - 1; cfg.scissor_maximum_y = h - 1;
		}
		pan_section_pack(vj, MALLOC_VERTEX_JOB, PRIMITIVE_SIZE, cfg) {}
		pan_section_pack(vj, MALLOC_VERTEX_JOB, INDICES, cfg) { cfg.address = 0; }
		pan_section_pack(vj, MALLOC_VERTEX_JOB, DRAW, cfg) {
			cfg.allow_forward_pixel_to_kill = true; cfg.allow_forward_pixel_to_be_killed = true;
			cfg.pixel_kill_operation = MALI_PIXEL_KILL_FORCE_EARLY; cfg.zs_update_operation = MALI_PIXEL_KILL_FORCE_EARLY;
			cfg.sample_mask = 0xFFFF; cfg.single_sampled_lines = true; cfg.vertex_array.packet = true;
			cfg.minimum_z = 0.0f; cfg.maximum_z = 1.0f; cfg.depth_stencil = D + OFF_DS;
			cfg.render_target_mask = 1; cfg.blend = D + OFF_BLEND; cfg.blend_count = 1;
			cfg.overdraw_alpha0 = true; cfg.overdraw_alpha1 = true;
			cfg.shader.thread_storage = D + OFF_TLS; cfg.shader.shader = PV + 0x240;
			cfg.shader.fau = PV + 0x400; cfg.shader.fau_count = fs_fau ? fs_fau : 1;
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
@implementation SweetMTLFunction
- (MTLFunctionType)functionType
{
	const sm_shader *s = sm_find(_name);
	return s && s->stage == 4 ? MTLFunctionTypeFragment : MTLFunctionTypeVertex;
}
@end

@interface SweetMTLLibrary : SweetMTLObject
@end
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
	SweetMTLFunction *f = [SweetMTLFunction new]; f.name = use;
	f.constants = cv ? [sm_fc_dict(cv) copy] : @{};
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
	f.constants = cv ? [sm_fc_dict(cv) copy] : @{};
	slog("SweetMTL: function %s with %lu constants", name.UTF8String, (unsigned long)f.constants.count);
	return f;
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
static void sm_fc_hook(void)
{
	static bool done; if (done) return; done = true;
	Class c = NSClassFromString(@"MTLFunctionConstantValuesInternal");
	if (!c) { slog("SweetMTL: no MTLFunctionConstantValuesInternal"); return; }
	Method m1 = class_getInstanceMethod(c, @selector(setConstantValue:type:atIndex:));
	Method m2 = class_getInstanceMethod(c, @selector(setConstantValues:type:withRange:));
	if (m1) sm_orig_set1 = method_setImplementation(m1, (IMP)sm_set1);
	if (m2) sm_orig_setN = method_setImplementation(m2, (IMP)sm_setN);
}
/* ------------------------------------------------------------------ Metal objects (phase 2a) */
@interface SweetMTLTexture : SweetMTLObject
@property (nonatomic, readonly) NSUInteger width, height, pixelFormat, bytesPerRow;
@property (nonatomic, readonly) sm_bo *bo;
@property (nonatomic, weak) id device;
@end
@implementation SweetMTLTexture { sm_bo _store; }
- (instancetype)initWithDevice:(id)dev descriptor:(MTLTextureDescriptor *)d
{
	self = [super init];
	_device = dev; _width = d.width; _height = d.height; _pixelFormat = d.pixelFormat; _bytesPerRow = _width * 4;
	if (!sm_bo_alloc(&_store, _bytesPerRow * _height)) { slog("SweetMTL: texture bo alloc failed"); return nil; }
	_bo = &_store;
	return self;
}
- (uint32_t)maliFormat
{
	bool bgra = _pixelFormat == MTLPixelFormatBGRA8Unorm;
	return (MALI_RGBA8_UNORM << 12) | (bgra ? MALI_RGB_COMPONENT_ORDER_BGRA : MALI_RGB_COMPONENT_ORDER_RGBA);
}
- (NSUInteger)depth { return 1; }
- (NSUInteger)mipmapLevelCount { return 1; }
- (NSUInteger)sampleCount { return 1; }
- (NSUInteger)arrayLength { return 1; }
- (MTLTextureType)textureType { return MTLTextureType2D; }
- (void)getBytes:(void *)dst bytesPerRow:(NSUInteger)bpr fromRegion:(MTLRegion)r mipmapLevel:(NSUInteger)lvl
{
	for (NSUInteger y = 0; y < r.size.height; y++)
		memcpy((uint8_t *)dst + y * bpr, _store.cpu + (r.origin.y + y) * _bytesPerRow + r.origin.x * 4, r.size.width * 4);
}
- (void)replaceRegion:(MTLRegion)r mipmapLevel:(NSUInteger)lvl withBytes:(const void *)src bytesPerRow:(NSUInteger)bpr
{
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
}
- (instancetype)init { self = [super init]; _keep = [NSMutableArray array]; return self; }
- (void)endEncoding {}
- (void)setRenderPipelineState:(id)ps { _pipeline = ps; }
- (void)setViewport:(MTLViewport)vp {}
- (void)setCullMode:(MTLCullMode)m {}
- (void)setFrontFacingWinding:(MTLWinding)w {}
- (void)setVertexBuffer:(id)buf offset:(NSUInteger)off atIndex:(NSUInteger)i
{
	if (i < 31) { _buf[i] = buf ? [(SweetMTLBuffer *)buf gpuAddress] + off : 0; if (buf) [_keep addObject:buf]; }
}
- (void)setVertexBytes:(const void *)p length:(NSUInteger)len atIndex:(NSUInteger)i
{
	SweetMTLBuffer *b = [[SweetMTLBuffer alloc] initWithLength:len bytes:p];
	if (b) { [_keep addObject:b]; if (i < 31) _buf[i] = [b gpuAddress]; }
}
- (void)setFragmentTexture:(id)t atIndex:(NSUInteger)i
{
	if (i < 8) { _tex[i] = t; if (t) [_keep addObject:t]; }
}
- (void)setFragmentSamplerState:(id)smp atIndex:(NSUInteger)i
{
	if (i < 8) { _smp[i] = smp; if (smp) [_keep addObject:smp]; }
}
- (void)setFragmentBuffer:(id)buf offset:(NSUInteger)off atIndex:(NSUInteger)i { [self setVertexBuffer:buf offset:off atIndex:i]; }
- (void)setFragmentBytes:(const void *)p length:(NSUInteger)len atIndex:(NSUInteger)i { [self setVertexBytes:p length:len atIndex:i]; }
- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count
{
	if (type != MTLPrimitiveTypeTriangle) { slog("SweetMTL: draw type %lu not supported yet", (unsigned long)type); return; }
	if (_ndraw >= 32) { slog("SweetMTL: too many draws in one pass"); return; }
	sm_drawrec *r = &_draws[_ndraw];
	memset(r, 0, sizeof *r);
	r->vs = _pipeline.vs; r->fs = _pipeline.fs;
	r->vcount = (uint32_t)count; r->vstart = (uint32_t)start;
	memcpy(r->buf, _buf, sizeof _buf);
	if (_pipeline) {
		for (int k = 0; k < 16; k++) { r->attr[k].fmt = _pipeline->_attr[k].fmt; r->attr[k].off = _pipeline->_attr[k].off; r->attr[k].bidx = _pipeline->_attr[k].bidx; }
		memcpy(r->stride, _pipeline->_stride, sizeof r->stride);
		memcpy(r->fc, _pipeline->_fc, sizeof r->fc); r->fc_defined = _pipeline->_fcdef;
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
	_ndraw++;
}
@end

/* blit/compute encoders: accepted and dropped for now (logged once per selector by the base) */
@interface SweetMTLStubEncoder : SweetMTLObject
@end
@implementation SweetMTLStubEncoder
- (void)endEncoding {}
@end
@interface SweetMTLCommandQueue : SweetMTLObject
@property (nonatomic, strong) dispatch_queue_t submissionQueue, completionQueue;
@end
@implementation SweetMTLCommandBuffer
- (instancetype)init { self = [super init]; _passes = [NSMutableArray array]; _scheduled = [NSMutableArray array]; _completed = [NSMutableArray array]; return self; }
- (void)addScheduledHandler:(void (^)(id))h { if (h) [_scheduled addObject:[h copy]]; }
- (void)addCompletedHandler:(void (^)(id))h { if (h) [_completed addObject:[h copy]]; }
- (id)blitCommandEncoder { return [SweetMTLStubEncoder new]; }
- (id)blitCommandEncoderWithDescriptor:(id)d { return [SweetMTLStubEncoder new]; }
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
	for (SweetMTLRenderEncoder *e in _passes) {
		if (!have || !e.target) { _status = 5; continue; }
		bool bgra = e.target.pixelFormat == MTLPixelFormatBGRA8Unorm;
		if (e->_ndraw) {
			static sm_bo heap; static bool haveheap;
			if (!haveheap) haveheap = sm_bo_alloc(&heap, 4u << 20);
			if (!haveheap) { _status = 5; continue; }
			bool generic = true;
			for (uint32_t i = 0; i < e->_ndraw; i++) if (!e->_draws[i].vs) generic = false;
			uint32_t vs = 0;
			if (generic) {
				_lastJobStatus = sm_pass(&desc, &heap, e.target.bo->gpu, (uint32_t)e.target.width, (uint32_t)e.target.height,
				    (uint32_t)e.target.bytesPerRow, e.packed, bgra, e->_draws, e->_ndraw, &vs);
			} else {
				/* no translated vertex shader: fixed Mesa shaders (phase 2b) */
				uint32_t n = 0; for (uint32_t i = 0; i < e->_ndraw; i++) n += e->_draws[i].vcount;
				_lastJobStatus = sm_draw(&desc, &heap, e.target.bo->gpu, (uint32_t)e.target.width, (uint32_t)e.target.height,
				    (uint32_t)e.target.bytesPerRow, e.packed, bgra, n, &vs);
			}
			slog("SweetMTL: pass %u draws (%s) vertex=%x fragment=%x", e->_ndraw, generic ? "translated" : "fixed", vs, _lastJobStatus);
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
- (void)presentDrawable:(id)d {}
- (NSError *)error { return nil; }
@end

@implementation SweetMTLCommandQueue
- (id)commandBuffer { SweetMTLCommandBuffer *b = [SweetMTLCommandBuffer new]; b.commandQueue = self; return b; }
- (id)commandBufferWithUnretainedReferences { return [self commandBuffer]; }
- (id)commandBufferWithDescriptor:(id)d { return [self commandBuffer]; }
- (void)insertDebugCaptureBoundary {}
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

@interface SweetMTLDevice : _MTLDevice <MTLDevice, MTLDeviceSPI>
@end

@implementation SweetMTLDevice {
	uint32_t _smPort;
}

+ (void)load
{
	sm_fc_hook();
	if (getprogname() && strcmp(getprogname(), "malitest")) sm_diag_install();
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
	if (self) { _smPort = port; sm_device = self; }
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
			NSUInteger i = k.unsignedIntegerValue;
			if (i < 64) { ps->_fc[i] = v.unsignedIntValue; ps->_fcdef |= 1ull << i; }
		}];
	}
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
- (uint64_t)registryID { return 0x53574545; }
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
	if (first) slog("SweetMTL: unimplemented -%s", k.UTF8String);
	sm_zero_return(inv);
}

@end
