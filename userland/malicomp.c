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
#include "pan_pool.h"

#define BO_BYTES 32768
#define OFF_JOB   0x000
#define OFF_SP    0x400
#define OFF_TSD   0x500
#define OFF_SHDR  0x600
#define OFF_PUSH  0x700
#define OFF_OUT   0x1000

/* assembled with mesa asm.py:
 *   IADD_IMM.i32 r0, 0x0, #0x12345678 ; MOV.i32 r2, u0 ; MOV.i32 r3, u1 ;
 *   STORE.i32.slot0.end @r0, ^r2, offset:0 */
static const uint8_t SHADER[32] = {
	0xc0,0x78,0x56,0x34,0x12,0xc0,0x10,0x01, 0x80,0,0,0,0,0xc2,0x91,0x00,
	0x81,0,0,0,0,0xc3,0x91,0x00, 0x42,0,0,0x18,0x02,0x40,0x61,0x78 };

static int run(void)
{
	io_service_t s = 0;
	for (int i = 0; i < 30 && !s; i++) { s = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("SweetMali")); if (!s) sleep(2); }
	if (!s) { ulog("comp: no service"); return 1; }
	io_connect_t c = 0;
	kern_return_t kr = IOServiceOpen(s, mach_task_self(), 0, &c); gc = c;
	if (kr) { ulog("comp: open kr=%x", kr); return 2; }
	uint64_t in[3] = { BO_BYTES }, out[2]; uint32_t oc = 2;
	kr = IOConnectCallMethod(c, 1, in, 1, NULL, 0, out, &oc, NULL, NULL);
	if (kr) { ulog("comp: create kr=%x", kr); return 3; }
	uint64_t h = out[0];
	mach_vm_address_t ua = 0; mach_vm_size_t us = 0;
	kr = IOConnectMapMemory64(c, (uint32_t)h, mach_task_self(), &ua, &us, 1);
	if (kr) { ulog("comp: mmap kr=%x", kr); return 4; }
	in[0] = h; in[1] = VA_BASE; oc = 0;
	kr = IOConnectCallMethod(c, 2, in, 2, NULL, 0, NULL, &oc, NULL, NULL);
	ulog("comp: bo ua=%llx size=%llx gpumap kr=%x", ua, us, kr);
	uint8_t *cpu = (uint8_t *)ua;
	memset(cpu, 0, 0x2000);
	memcpy(cpu + OFF_SHDR, SHADER, sizeof SHADER);
	uint64_t outva = VA_BASE + OFF_OUT;
	((uint32_t *)(cpu + OFF_PUSH))[0] = (uint32_t)outva;
	((uint32_t *)(cpu + OFF_PUSH))[1] = (uint32_t)(outva >> 32);
	*(volatile uint32_t *)(cpu + OFF_OUT) = 0xDEADBEEF;

	pan_pack(cpu + OFF_SP, SHADER_PROGRAM, cfg) {
		cfg.stage = MALI_SHADER_STAGE_COMPUTE;
		cfg.register_allocation = MALI_SHADER_REGISTER_ALLOCATION_32_PER_THREAD;
		cfg.binary = VA_BASE + OFF_SHDR;
	}
	pan_pack(cpu + OFF_TSD, LOCAL_STORAGE, ls) {
		ls.wls_instances = MALI_LOCAL_STORAGE_NO_WORKGROUP_MEM;
	}
	void *job = cpu + OFF_JOB;
	pan_section_pack(job, COMPUTE_JOB, PAYLOAD, cfg) {
		cfg.workgroup_size_x = 1; cfg.workgroup_size_y = 1; cfg.workgroup_size_z = 1;
		cfg.workgroup_count_x = 1; cfg.workgroup_count_y = 1; cfg.workgroup_count_z = 1;
		cfg.compute.shader = VA_BASE + OFF_SP;
		cfg.compute.thread_storage = VA_BASE + OFF_TSD;
		cfg.compute.fau = VA_BASE + OFF_PUSH;
		cfg.compute.fau_count = 1;
		cfg.compute.resources = 0;
		cfg.allow_merging_workgroups = true;
		cfg.task_increment = 1;
		cfg.task_axis = MALI_TASK_AXIS_Z;
	}
	pan_section_pack(job, COMPUTE_JOB, HEADER, header) {
		header.type = MALI_JOB_TYPE_COMPUTE;
		header.index = 1;
	}
	in[0] = 1; in[1] = VA_BASE + OFF_JOB; in[2] = 500; oc = 1;
	kr = IOConnectCallMethod(c, 3, in, 3, NULL, 0, out, &oc, NULL, NULL);
	uint32_t v = *(volatile uint32_t *)(cpu + OFF_OUT);
	uint32_t exc = *(volatile uint32_t *)(cpu + OFF_JOB);
	ulog("comp: submit kr=%x status=%llx out=%08x exc=%08x %s", kr, out[0], v, exc,
	    v == 0x12345678U ? "VALHALL-SHADER-OK" : "FAIL");
	return v == 0x12345678U ? 0 : 5;
}

int main(void)
{
	int r = run();
	ulog("malicomp done rc=%d; killing launchd so the panic keeps the log", r);
	sleep(3);
	kill(1, SIGKILL);
	return r;
}
