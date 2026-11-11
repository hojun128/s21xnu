/* Phase-1 Metal check: does MTLCreateSystemDefaultDevice() reach the SweetMetal plugin? */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <mach/mach.h>
#include <signal.h>
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
	if (nh < 12) snprintf(hist[nh++], 150, "%s", b);
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
			for (int i = 0; i < nh; i++) if (gc) IOConnectCallMethod(gc, 5, NULL, 0, hist[i], strlen(hist[i]), NULL, NULL, NULL, NULL);
			sleep(5);
		}
	}
	return 0;
}
