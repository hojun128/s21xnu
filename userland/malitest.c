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
static int run(void)
{
	io_service_t s = 0;
	for (int i = 0; i < 30 && !s; i++) { s = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("SweetMali")); if (!s) sleep(2); }
	printf("service=%u\n", s);
	if (!s) return 1;
	io_connect_t c = 0;
	kern_return_t kr = IOServiceOpen(s, mach_task_self(), 0, &c); gc = c;
	ulog("open kr=%x conn=%u", kr, c);
	if (kr) return 2;
	uint32_t info[6]; size_t isz = sizeof info;
	kr = IOConnectCallMethod(c, 0, NULL, 0, NULL, 0, NULL, NULL, info, &isz);
	ulog("info kr=%x id=%08x shader=%08x tiler=%x l2=%x as=%x js=%x", kr, info[0], info[1], info[2], info[3], info[4], info[5]);
	uint64_t in[3] = { 32768 }, out[2]; uint32_t oc = 2;
	kr = IOConnectCallMethod(c, 1, in, 1, NULL, 0, out, &oc, NULL, NULL);
	ulog("create kr=%x handle=%llu pa=%llx", kr, out[0], out[1]);
	if (kr) return 3;
	uint64_t h = out[0];
	mach_vm_address_t ua = 0; mach_vm_size_t us = 0;
	kr = IOConnectMapMemory64(c, (uint32_t)h, mach_task_self(), &ua, &us, 1 /*kIOMapAnywhere*/);
	ulog("map kr=%x ua=%llx size=%llx", kr, ua, us);
	if (kr) return 4;
	in[0] = h; in[1] = VA_BASE; oc = 0;
	kr = IOConnectCallMethod(c, 2, in, 2, NULL, 0, NULL, &oc, NULL, NULL);
	ulog("gpu-map kr=%x", kr);
	volatile uint32_t *j = (volatile uint32_t *)ua;
	volatile uint32_t *o = (volatile uint32_t *)(ua + 4096);
	j[4] = (2U << 1) | 1U;
	j[8] = (uint32_t)(VA_BASE + 4096);
	j[9] = (uint32_t)((VA_BASE + 4096) >> 32);
	j[10] = 6U;
	j[12] = 0xA11CE5E1U;
	o[0] = 0xDEADBEEFU;
	in[0] = 1; in[1] = VA_BASE; in[2] = 200; oc = 1;
	kr = IOConnectCallMethod(c, 3, in, 3, NULL, 0, out, &oc, NULL, NULL);
	ulog("submit kr=%x status=%llx out=%08x exc=%x %s", kr, out[0], o[0], j[0],
	    o[0] == 0xA11CE5E1U ? "GPU-FROM-USERLAND-OK" : "FAIL");
	return o[0] == 0xA11CE5E1U ? 0 : 5;
}

int main(void)
{
	int r = run();
	ulog("malitest done rc=%d; killing launchd so the panic keeps the log", r);
	sleep(3);
	kill(1, SIGKILL);
	return r;
}
