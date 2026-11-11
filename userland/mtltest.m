/* Phase-1 Metal check: does MTLCreateSystemDefaultDevice() reach the SweetMetal plugin? */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <mach/mach.h>
#include <signal.h>
#include <dlfcn.h>
#include <pthread.h>
#include <mach/thread_act.h>
#include <mach/arm/thread_status.h>
#include <unistd.h>
#include <stdarg.h>

typedef mach_port_t io_object_t, io_service_t, io_connect_t;
extern const mach_port_t kIOMasterPortDefault;
extern io_service_t IOServiceGetMatchingService(mach_port_t, CFDictionaryRef);
extern CFMutableDictionaryRef IOServiceMatching(const char *);
extern kern_return_t IOServiceOpen(io_service_t, task_port_t, uint32_t, io_connect_t *);
extern kern_return_t IOConnectCallMethod(io_connect_t, uint32_t, const uint64_t *, uint32_t,
    const void *, size_t, uint64_t *, uint32_t *, void *, size_t *);

static io_connect_t gc;
static char hist[12][150]; static int nh;
static void ulog(const char *fmt, ...)
{
	char b[150]; va_list ap; va_start(ap, fmt); vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
	printf("%s\n", b);
	if (gc) IOConnectCallMethod(gc, 5, NULL, 0, b, strlen(b), NULL, NULL, NULL, NULL);
	snprintf(hist[nh % 12], 150, "%s", b); nh++;
}


static mach_port_t g_main_thr;
static const char *symof(uint64_t a, char *buf, size_t n)
{
	Dl_info di;
	if (a && dladdr((void *)a, &di) && di.dli_sname) {
		const char *im = di.dli_fname ? strrchr(di.dli_fname, '/') : NULL;
		snprintf(buf, n, "%s:%s+%lx", im ? im + 1 : "?", di.dli_sname, (unsigned long)(a - (uint64_t)di.dli_saddr));
	} else if (a && dladdr((void *)a, &di)) {
		const char *im = di.dli_fname ? strrchr(di.dli_fname, '/') : NULL;
		snprintf(buf, n, "%s:+%lx", im ? im + 1 : "?", (unsigned long)(a - (uint64_t)di.dli_fbase));
	} else snprintf(buf, n, "%llx", (unsigned long long)a);
	return buf;
}
static void *watchdog(void *arg)
{
	for (int t = 1;; t++) {
		sleep(3);
		if (thread_suspend(g_main_thr) != KERN_SUCCESS) continue;
		arm_thread_state64_t st; mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
		uint64_t pcs[7] = {0}; int np = 0;
		if (thread_get_state(g_main_thr, ARM_THREAD_STATE64, (thread_state_t)&st, &cnt) == KERN_SUCCESS) {
			pcs[np++] = arm_thread_state64_get_pc(st);
			pcs[np++] = arm_thread_state64_get_lr(st);
			uint64_t *fp = (uint64_t *)arm_thread_state64_get_fp(st);
			for (int k = 0; k < 4 && fp && np < 7; k++) {
				uint64_t ret = fp[1]; fp = (uint64_t *)fp[0];
				pcs[np++] = ret;
			}
		}
		thread_resume(g_main_thr);
		char a[60], b[60], c[60], d[60];
		ulog("mtltest: wait%d %s < %s", t, symof(pcs[0], a, sizeof a), symof(pcs[1], b, sizeof b));
		ulog("mtltest: .. %s < %s < %s", symof(pcs[2], c, sizeof c), symof(pcs[3], d, sizeof d), symof(pcs[4], a, sizeof a));
	}
	return NULL;
}
static void onsig(int sg) { char b[40]; snprintf(b, sizeof b, "mtltest: CRASH signal %d", sg); if (gc) IOConnectCallMethod(gc, 5, NULL, 0, b, strlen(b), NULL, NULL, NULL, NULL); _exit(1); }
int main(void)
{
	signal(SIGSEGV, onsig); signal(SIGBUS, onsig); signal(SIGABRT, onsig); signal(SIGILL, onsig); signal(SIGTRAP, onsig);
	@autoreleasepool {
		io_service_t s = 0;
		for (int i = 0; i < 30 && !s; i++) { s = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("SweetMali")); if (!s) sleep(2); }
		if (s) IOServiceOpen(s, mach_task_self(), 0, &gc);
		io_service_t acc = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOAcceleratorES"));
		ulog("mtltest: SweetMali=%u IOAcceleratorES=%u", s, acc);
		g_main_thr = mach_thread_self();
		pthread_t wt; pthread_create(&wt, NULL, watchdog, NULL);
		ulog("mtltest: calling MTLCreateSystemDefaultDevice");
		id<MTLDevice> d = nil;
		@try { d = MTLCreateSystemDefaultDevice(); } @catch (NSException *e) { ulog("mtltest: exception %s", [[e description] UTF8String]); }
		ulog("mtltest: MTLCreateSystemDefaultDevice -> %p %s", d, d ? object_getClassName(d) : "nil");
		if (d) ulog("mtltest: name=%s", [[d name] UTF8String]);
		NSArray *all = MTLCopyAllDevices();
		ulog("mtltest: MTLCopyAllDevices count=%lu", (unsigned long)all.count);
		if (d) {
			id q = [d newCommandQueue];
			ulog("mtltest: newCommandQueue -> %p", q);
		}
		for (int n = 0;; n++) {
			if (gc) { char t[40]; snprintf(t, sizeof t, "== MTLTEST %d ==", n); IOConnectCallMethod(gc, 5, NULL, 0, t, strlen(t), NULL, NULL, NULL, NULL); }
			for (int i = (nh > 12 ? nh - 12 : 0); i < nh; i++) if (gc) IOConnectCallMethod(gc, 5, NULL, 0, hist[i % 12], strlen(hist[i % 12]), NULL, NULL, NULL, NULL);
			sleep(5);
		}
	}
	return 0;
}
