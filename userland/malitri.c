/* iOS userland smoke test for the SweetMali user client (S21 Mali-G78). */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <signal.h>
#include <mach/mach.h>

typedef mach_port_t io_object_t, io_service_t, io_connect_t;
extern const mach_port_t kIOMasterPortDefault;
extern io_service_t IOServiceGetMatchingService(mach_port_t, void *);
extern void *IOServiceMatching(const char *);
extern kern_return_t IOServiceOpen(io_service_t, task_port_t, uint32_t, io_connect_t *);
extern kern_return_t IOConnectCallMethod(io_connect_t, uint32_t, const uint64_t *, uint32_t,
    const void *, size_t, uint64_t *, uint32_t *, void *, size_t *);
extern kern_return_t IOConnectMapMemory64(io_connect_t, uint32_t, task_port_t, mach_vm_address_t *,
    mach_vm_size_t *, uint32_t);

#define VA_BASE 0x30000000ULL
static io_connect_t gc;
static void ulog(const char *fmt, ...)
{
	char b[150]; va_list ap; va_start(ap, fmt); vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
	printf("%s\n", b); fflush(stdout);
	if (gc) IOConnectCallMethod(gc, 5, NULL, 0, b, strlen(b), NULL, NULL, NULL, NULL);
	extern char g_hist[16][150]; extern int g_nh;
	if (strncmp(b, "tri:", 4) == 0 || b[0] == 'W') { snprintf(g_hist[g_nh % 16], 150, "%s", b); g_nh++; }
}
char g_hist[16][150]; int g_nh;
#define PAN_ARCH 9
#include "genxml/gen_macros.h"

#define BO_BYTES 32768
#include "malitri_shaders.h"
#include "malitri_gen.h"

#define BO_BYTES 32768
#define HEAP_BYTES (4u << 20)
#define HEAP_VA  0x40000000ULL
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
#define OFF_MARK 0xB00
#define OFF_BPOS 0x800
#define OFF_BFRAG 0x900
#define OFF_VERT 0xA00
#define OFF_SAMP 0xC00
#define OFF_FB   0x1000
#ifndef VAR_FIRST
#define VAR_FIRST 7
#define VAR_LAST 8
#endif
#define W 64
#define H 64


static void enc(char *o, uint32_t v) { for (int i = 7; i >= 0; i--) { char c = 0x60 + ((v >> (4 * i)) & 15); *o++ = c; *o++ = c; *o++ = c; } *o = 0; }
static void edump(const char *tag, uint32_t a, uint32_t b, const volatile uint32_t *w)
{
	char x[40], y[40], z[40], q[40], r[40], t[40];
	enc(x, a); enc(y, b); enc(z, w[0]); enc(q, w[1]); enc(r, w[2]); enc(t, w[3]);
	ulog("E%s1 %s %s", tag, x, y);
	ulog("E%s2 %s %s", tag, z, q);
	ulog("E%s3 %s %s", tag, r, t);
}
static void dumpw(const char *tag, const volatile uint32_t *p, int n)
{
	for (int i = 0; i < n; i++) ulog("W%s%d=%08x/%08x/%08x", tag, i, p[i], p[i], p[i]);
}
static kern_return_t submit(io_connect_t c, uint64_t slot, uint64_t jc, uint64_t *st)
{
	uint64_t in[3] = { slot, jc, 1500 }, out[2]; uint32_t oc = 1;
	kern_return_t kr = IOConnectCallMethod(c, 3, in, 3, NULL, 0, out, &oc, NULL, NULL);
	*st = out[0];
	return kr;
}

static io_connect_t mkbo(io_connect_t c, uint64_t size, uint64_t va, uint8_t **cpu)
{
	uint64_t in[3] = { size }, out[2]; uint32_t oc = 2;
	kern_return_t kr = IOConnectCallMethod(c, 1, in, 1, NULL, 0, out, &oc, NULL, NULL);
	if (kr) { ulog("tri: create kr=%x size=%llx", kr, size); return 0; }
	uint64_t h = out[0];
	mach_vm_address_t ua = 0; mach_vm_size_t us = 0;
	kr = IOConnectMapMemory64(c, (uint32_t)h, mach_task_self(), &ua, &us, 1);
	if (kr) { ulog("tri: mmap kr=%x", kr); return 0; }
	in[0] = h; in[1] = va; oc = 0;
	kr = IOConnectCallMethod(c, 2, in, 2, NULL, 0, NULL, &oc, NULL, NULL);
	if (kr) { ulog("tri: gpumap kr=%x", kr); return 0; }
	*cpu = (uint8_t *)ua;
	return 1;
}

static void repack(uint8_t *cpu, uint32_t mask, uint64_t tiler, uint64_t samp)
{
	pan_pack(cpu + OFF_THEAP, TILER_HEAP, heap_d) {
		heap_d.size = HEAP_BYTES;
		heap_d.base = HEAP_VA;
		heap_d.bottom = HEAP_VA;
		heap_d.top = HEAP_VA + HEAP_BYTES;
	}
	pan_pack(cpu + OFF_TCTX, TILER_CONTEXT, t) {
		t.hierarchy_mask = mask;
		t.fb_width = W;
		t.fb_height = H;
		t.heap = VA_BASE + OFF_THEAP;
		t.sample_pattern = MALI_SAMPLE_PATTERN_SINGLE_SAMPLED;
		t.first_provoking_vertex = true;
	}
	void *fbd = cpu + OFF_FBD;
	pan_section_pack(fbd, FRAMEBUFFER, PARAMETERS, cfg) {
		cfg.pre_frame_0 = MALI_PRE_POST_FRAME_SHADER_MODE_NEVER;
		cfg.pre_frame_1 = MALI_PRE_POST_FRAME_SHADER_MODE_NEVER;
		cfg.post_frame = MALI_PRE_POST_FRAME_SHADER_MODE_NEVER;
		cfg.width = W; cfg.height = H;
		cfg.bound_max_x = W - 1; cfg.bound_max_y = H - 1;
		cfg.effective_tile_size = 256;
		cfg.tie_break_rule = MALI_TIE_BREAK_RULE_MINUS_180_IN_0_OUT;
		cfg.render_target_count = 1;
		cfg.z_internal_format = MALI_Z_INTERNAL_FORMAT_D24;
		cfg.color_buffer_allocation = 1024;
		cfg.sample_count = 1;
		cfg.sample_pattern = MALI_SAMPLE_PATTERN_SINGLE_SAMPLED;
		cfg.tiler = tiler;
		cfg.sample_locations = samp;
		cfg.first_provoking_vertex = true;
	}
	pan_section_pack(fbd, FRAMEBUFFER, PADDING, padding) {}
	pan_pack((uint8_t *)fbd + pan_size(FRAMEBUFFER), RENDER_TARGET, rt) {
		rt.clean_pixel_write_enable = true;
		rt.clear.color_0 = rt.clear.color_1 = rt.clear.color_2 = rt.clear.color_3 = 0xFF0000FFu;
		rt.write_enable = true;
		rt.dithering_enable = true;
		rt.internal_format = MALI_COLOR_BUFFER_INTERNAL_FORMAT_R8G8B8A8;
		rt.writeback_format = MALI_COLOR_FORMAT_R8G8B8A8;
		rt.writeback_block_format = MALI_BLOCK_FORMAT_LINEAR;
		rt.writeback_msaa = MALI_MSAA_SINGLE;
		rt.swizzle = 0 | (1 << 3) | (2 << 6) | (3 << 9);
		rt.rgb.base = VA_BASE + OFF_FB;
		rt.rgb.row_stride = W * 4;
	}
}

static int run(void)
{
	io_service_t s = 0;
	for (int i = 0; i < 30 && !s; i++) { s = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("SweetMali")); if (!s) sleep(2); }
	if (!s) { ulog("tri: no service"); return 1; }
	io_connect_t c = 0;
	kern_return_t kr = IOServiceOpen(s, mach_task_self(), 0, &c); gc = c;
	if (kr) { ulog("tri: open kr=%x", kr); return 2; }
	uint8_t *cpu = 0, *heap = 0;
	if (!mkbo(c, BO_BYTES, VA_BASE, &cpu)) return 3;
	int have_heap = mkbo(c, HEAP_BYTES, HEAP_VA, &heap) ? 1 : 0;
	ulog("tri: build19 bo ok heap=%d", have_heap);
	if (!have_heap) return 4;
	memset(cpu, 0, 0x1000);
	volatile uint32_t *px = (volatile uint32_t *)(cpu + OFF_FB);
	for (int i = 0; i < W * H; i++) px[i] = 0xDEADBEEF;
	memcpy(cpu + OFF_BPOS, POS_BIN, sizeof POS_BIN);
	memcpy(cpu + OFF_BFRAG, FRAG_BIN, sizeof FRAG_BIN);
	float *v = (float *)(cpu + OFF_VERT);
	float tv[12] = { 4, 4, 0.5f, 1, 60, 4, 0.5f, 1, 4, 60, 0.5f, 1 };
	memcpy(v, tv, sizeof tv);
	((uint64_t *)(cpu + OFF_FAU))[0] = VA_BASE + OFF_VERT;
	((uint64_t *)(cpu + OFF_FAU2))[0] = VA_BASE + OFF_MARK;

	repack(cpu, 0x28, VA_BASE + OFF_TCTX, VA_BASE + OFF_SAMP);
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
		sp.binary = VA_BASE + OFF_BPOS;
		sp.preload.r59 = true;
		sp.preload.r60 = true;
	}
	pan_pack(cpu + OFF_SFRAG, SHADER_PROGRAM, sp) {
		sp.stage = MALI_SHADER_STAGE_FRAGMENT;
		sp.register_allocation = MALI_SHADER_REGISTER_ALLOCATION_32_PER_THREAD;
		sp.binary = VA_BASE + OFF_BFRAG;
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
		cfg.index_count = 3;
		cfg.base_vertex_offset = 0;
		cfg.allow_rotating_primitives = true;
	}
	pan_section_pack(vj, MALLOC_VERTEX_JOB, INSTANCE_COUNT, cfg) { cfg.count = 1; }
	pan_section_pack(vj, MALLOC_VERTEX_JOB, ALLOCATION, cfg) {
		cfg.vertex_packet_stride = 16;
		cfg.vertex_attribute_stride = 0;
	}
	pan_section_pack(vj, MALLOC_VERTEX_JOB, TILER, cfg) { cfg.address = VA_BASE + OFF_TCTX; }
	pan_section_pack(vj, MALLOC_VERTEX_JOB, SCISSOR, cfg) {
		cfg.scissor_minimum_x = 0; cfg.scissor_minimum_y = 0;
		cfg.scissor_maximum_x = W - 1; cfg.scissor_maximum_y = H - 1;
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
		cfg.depth_stencil = VA_BASE + OFF_DS;
		cfg.render_target_mask = 1;
		cfg.blend = VA_BASE + OFF_BLEND;
		cfg.blend_count = 1;
		cfg.overdraw_alpha0 = true;
		cfg.overdraw_alpha1 = true;
		cfg.shader.thread_storage = VA_BASE + OFF_TLS;
		cfg.shader.shader = VA_BASE + OFF_SFRAG;
		cfg.shader.fau = VA_BASE + OFF_FAU2;
		cfg.shader.fau_count = 1;
	}
	pan_section_pack(vj, MALLOC_VERTEX_JOB, POSITION, cfg) {
		cfg.thread_storage = VA_BASE + OFF_TLS;
		cfg.shader = VA_BASE + OFF_SPOS;
		cfg.fau = VA_BASE + OFF_FAU;
		cfg.fau_count = 1;
	}
	pan_section_pack(vj, MALLOC_VERTEX_JOB, HEADER, header) {
		header.type = MALI_JOB_TYPE_MALLOC_VERTEX;
		header.index = 1;
	}
	void *job = cpu + OFF_FJOB;
	pan_section_pack(job, FRAGMENT_JOB, PAYLOAD, cfg) {
		cfg.bound_min_x = 0; cfg.bound_min_y = 0;
		cfg.bound_max_x = (W - 1) >> 4; cfg.bound_max_y = (H - 1) >> 4;
		cfg.tile_render_order = MALI_TILE_RENDER_ORDER_Z_ORDER;
		cfg.framebuffer = VA_BASE + OFF_FBD;
	}
	pan_section_pack(job, FRAGMENT_JOB, HEADER, header) {
		header.type = MALI_JOB_TYPE_FRAGMENT;
		header.index = 1;
	}

	uint64_t st;
	memset(cpu + OFF_BPOS, 0, 0x100);
	memcpy(cpu + OFF_BPOS, POS_BIN, sizeof POS_BIN);
	int tri = 0, bg = 0;
	{
		static const struct { uint32_t mask; int usetiler; int usesamp; int fs; } V[9] = { {0x28,1,1,0}, {0x28,1,1,2}, {0x28,1,1,1}, {0x28,1,1,3}, {0x28,1,1,4}, {0x28,1,1,5}, {0x28,1,1,6}, {0x28,1,1,7}, {0x28,1,1,0} };
		for (int v = VAR_FIRST; v < VAR_LAST; v++) {
			ulog("tri: about var%d", v);
			memset(cpu + OFF_BFRAG, 0, 0x100);
			if (V[v].fs == 1) memcpy(cpu + OFF_BFRAG, FRAGN_BIN, sizeof FRAGN_BIN);
			else if (V[v].fs == 2) memcpy(cpu + OFF_BFRAG, FRAGA_BIN, sizeof FRAGA_BIN);
			else if (V[v].fs == 7) memcpy(cpu + OFF_BFRAG, FS_GREEN, sizeof FS_GREEN);
			else if (V[v].fs == 4) memcpy(cpu + OFF_BFRAG, FRAGB_BIN, sizeof FRAGB_BIN);
			else if (V[v].fs == 5) memcpy(cpu + OFF_BFRAG, FRAGW_BIN, sizeof FRAGW_BIN);
			else if (V[v].fs == 6) memcpy(cpu + OFF_BFRAG, FRAGX_BIN, sizeof FRAGX_BIN);
			else if (V[v].fs == 3) memcpy(cpu + OFF_BFRAG, FRAGM_BIN, sizeof FRAGM_BIN);
			else memcpy(cpu + OFF_BFRAG, FRAG_BIN, sizeof FRAG_BIN);
			memset(cpu + OFF_BPOS, 0, 0x100);
			if (V[v].fs == 7) memcpy(cpu + OFF_BPOS, VS_TRI, sizeof VS_TRI); else memcpy(cpu + OFF_BPOS, POS_BIN, sizeof POS_BIN);
			repack(cpu, V[v].mask, V[v].usetiler ? VA_BASE + OFF_TCTX : 0, V[v].usesamp ? VA_BASE + OFF_SAMP : 0);
			for (int i = 0; i < W * H; i++) px[i] = 0xDEADBEEF;
			for (int q = 0; q < 4; q++) ((volatile uint32_t *)(cpu + OFF_VJOB))[q] = 0;
			for (int q = 0; q < 4; q++) ((volatile uint32_t *)(cpu + OFF_FJOB))[q] = 0;
			kr = submit(c, 1, VA_BASE + OFF_VJOB, &st);
			uint32_t vexc = *(volatile uint32_t *)(cpu + OFF_VJOB);
			kr = submit(c, 0, VA_BASE + OFF_FJOB, &st);
			uint32_t fexc = *(volatile uint32_t *)(cpu + OFF_FJOB);
			tri = bg = 0;
			for (int i = 0; i < W * H; i++) { if (px[i] == 0xFF00FF00u) tri++; else if (px[i] == 0xFF0000FFu) bg++; }
			
			
			
			char e1[40], e2[40]; enc(e1, vexc); enc(e2, fexc);
			ulog("EW%d %s %s", v, e1, e2);
			ulog("tri: var%d mark=%08x vexc=%08x fexc=%08x tri=%d bg=%d p(10,10)=%08x p(50,50)=%08x %s", v, *(volatile uint32_t *)(cpu + OFF_MARK), vexc, fexc, tri, bg,
			    px[10 * W + 10], px[50 * W + 50], tri > 1000 ? "GPU-DREW-TRIANGLE" : "TRI-FAIL");
			if (tri > 1000) break;
		}
	}
	return tri > 1000 ? 0 : 5;
}

int main(void)
{
	int r = run();
	ulog("malitri done rc=%d", r);
	sleep(3);
	for (int n = 0;; n++) {
		int st = g_nh > 16 ? g_nh - 16 : 0;
		ulog("==== MALITRI RESULT (repeat %d) ====", n);
		for (int i = st; i < g_nh; i++) {
			char t[150]; snprintf(t, sizeof t, "R%d %s", i, g_hist[i % 16]);
			if (gc) IOConnectCallMethod(gc, 5, NULL, 0, t, strlen(t), NULL, NULL, NULL, NULL);
		}
		sleep(5);
	}
	return r;
}
