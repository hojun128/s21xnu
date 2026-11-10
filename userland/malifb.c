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
}
#define PAN_ARCH 9
#include "genxml/gen_macros.h"

#define BO_BYTES 32768
#define OFF_JOB  0x000
#define OFF_FBD  0x040
#define OFF_FB   0x1000
#define W 64
#define H 64

static int run(void)
{
	io_service_t s = 0;
	for (int i = 0; i < 30 && !s; i++) { s = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("SweetMali")); if (!s) sleep(2); }
	if (!s) { ulog("fb: no service"); return 1; }
	io_connect_t c = 0;
	kern_return_t kr = IOServiceOpen(s, mach_task_self(), 0, &c); gc = c;
	if (kr) { ulog("fb: open kr=%x", kr); return 2; }
	uint64_t in[3] = { BO_BYTES }, out[2]; uint32_t oc = 2;
	kr = IOConnectCallMethod(c, 1, in, 1, NULL, 0, out, &oc, NULL, NULL);
	if (kr) { ulog("fb: create kr=%x", kr); return 3; }
	uint64_t h = out[0];
	mach_vm_address_t ua = 0; mach_vm_size_t us = 0;
	kr = IOConnectMapMemory64(c, (uint32_t)h, mach_task_self(), &ua, &us, 1);
	if (kr) { ulog("fb: mmap kr=%x", kr); return 4; }
	in[0] = h; in[1] = VA_BASE; oc = 0;
	kr = IOConnectCallMethod(c, 2, in, 2, NULL, 0, NULL, &oc, NULL, NULL);
	ulog("fb: bo ua=%llx size=%llx gpumap kr=%x", ua, us, kr);
	uint8_t *cpu = (uint8_t *)ua;
	memset(cpu, 0, 0x1000);
	volatile uint32_t *px = (volatile uint32_t *)(cpu + OFF_FB);
	for (int i = 0; i < W * H; i++) px[i] = 0xDEADBEEF;

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
		cfg.tiler = 0;
	}
	pan_section_pack(fbd, FRAMEBUFFER, PADDING, padding) {}
	pan_pack((uint8_t *)fbd + pan_size(FRAMEBUFFER), RENDER_TARGET, rt) {
		rt.clean_pixel_write_enable = true;
		rt.internal_buffer_offset = 0;
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
		rt.rgb.surface_stride = 0;
	}
	void *job = cpu + OFF_JOB;
	pan_section_pack(job, FRAGMENT_JOB, PAYLOAD, cfg) {
		cfg.bound_min_x = 0; cfg.bound_min_y = 0;
		cfg.bound_max_x = W - 1; cfg.bound_max_y = H - 1;
		cfg.tile_render_order = MALI_TILE_RENDER_ORDER_Z_ORDER;
		cfg.framebuffer = VA_BASE + OFF_FBD;
	}
	pan_section_pack(job, FRAGMENT_JOB, HEADER, header) {
		header.type = MALI_JOB_TYPE_FRAGMENT;
		header.index = 1;
	}
	in[0] = 0; in[1] = VA_BASE + OFF_JOB; in[2] = 1000; oc = 1;
	kr = IOConnectCallMethod(c, 3, in, 3, NULL, 0, out, &oc, NULL, NULL);
	int good = 0;
	for (int i = 0; i < W * H; i++) if (px[i] == 0xFF0000FFu) good++;
	uint32_t exc = *(volatile uint32_t *)(cpu + OFF_JOB);
	ulog("fb: submit kr=%x status=%llx exc=%08x px0=%08x pxmid=%08x pxlast=%08x good=%d/%d %s", kr, out[0], exc,
	    px[0], px[W * H / 2], px[W * H - 1], good, W * H, good == W * H ? "GPU-FILLED-FRAMEBUFFER" : "FAIL");
	return good == W * H ? 0 : 5;
}

int main(void)
{
	int r = run();
	ulog("malifb done rc=%d", r);
	sleep(3);
	kill(1, SIGKILL);
	return r;
}
