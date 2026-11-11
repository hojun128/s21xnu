/*
 * SweetMetal.bundle: Metal driver plugin for the S21 Mali-G78 (phase 1 skeleton).
 * Loaded by Metal.framework through the kernel's IOAcceleratorES service
 * (MetalPluginName = SweetMetal, MetalPluginClassName = SweetMTLDevice).
 * Only hands out a device inside the test program (process "malitest") so that
 * CoreAnimation keeps its software renderer. Every selector Metal calls that is not
 * implemented yet is logged ("SweetMTL: unimplemented ...") and answered with 0/nil.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <mach/mach.h>
#include <stdarg.h>
#include <string.h>

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

/*
 * Metal requires the plugin class to be a subclass of _MTLDevice (private). It is created at
 * load time with the runtime API so the bundle links without private headers.
 * Everything Metal asks that is not implemented here is logged and answered with 0/nil.
 */
static NSString *sm_name(id self, SEL _cmd) { return @"Sweet Mali-G78 MP14"; }
static uint64_t sm_regid(id self, SEL _cmd) { return 0x53574545; }
static BOOL sm_no(id self, SEL _cmd) { return NO; }
static BOOL sm_yes(id self, SEL _cmd) { return YES; }
static uint32_t sm_port(id self, SEL _cmd) { return 0; }

static id sm_init(id self, SEL _cmd, uint32_t port)
{
	const char *pn = getprogname();
	slog("SweetMTL: initWithAcceleratorPort:%u in %s", port, pn ? pn : "?");
	if (pn == NULL || strcmp(pn, "malitest") != 0) {
		return nil;
	}
	return self;
}
static id sm_init2(id self, SEL _cmd, uint32_t port, id o) { return sm_init(self, _cmd, port); }
static id sm_init3(id self, SEL _cmd, uint32_t port, BOOL b) { return sm_init(self, _cmd, port); }

static NSMethodSignature *sm_sig(id self, SEL _cmd, SEL sel)
{
	struct objc_super sup = { self, class_getSuperclass(object_getClass(self)) };
	NSMethodSignature *m = ((NSMethodSignature *(*)(struct objc_super *, SEL, SEL))objc_msgSendSuper)(&sup, _cmd, sel);
	slog("SweetMTL: asked -%s (sig %s)", sel_getName(sel), m ? "yes" : "no");
	return m ? m : [NSMethodSignature signatureWithObjCTypes:"@@:@@@@"];
}
static void sm_fwd(id self, SEL _cmd, NSInvocation *inv)
{
	slog("SweetMTL: unimplemented -%s", sel_getName(inv.selector));
	void *z = NULL;
	[inv setReturnValue:&z];
}

__attribute__((constructor)) static void sm_register(void)
{
	Class base = NSClassFromString(@"_MTLDevice");
	slog("SweetMTL: bundle loaded, _MTLDevice=%p in %s", base, getprogname() ? getprogname() : "?");
	if (!base) return;
	Class c = objc_allocateClassPair(base, "SweetMTLDevice", 0);
	if (!c) { slog("SweetMTL: allocateClassPair failed"); return; }
	class_addMethod(c, @selector(initWithAcceleratorPort:), (IMP)sm_init, "@@:I");
	class_addMethod(c, @selector(initWithAcceleratorPort:options:), (IMP)sm_init2, "@@:I@");
	class_addMethod(c, @selector(initWithAcceleratorPort:simultaneousInstances:), (IMP)sm_init3, "@@:IB");
	class_addMethod(c, @selector(name), (IMP)sm_name, "@@:");
	class_addMethod(c, @selector(registryID), (IMP)sm_regid, "Q@:");
	class_addMethod(c, @selector(isLowPower), (IMP)sm_no, "B@:");
	class_addMethod(c, @selector(isHeadless), (IMP)sm_no, "B@:");
	class_addMethod(c, @selector(isRemovable), (IMP)sm_no, "B@:");
	class_addMethod(c, @selector(acceleratorPort), (IMP)sm_port, "I@:");
	class_addMethod(c, @selector(methodSignatureForSelector:), (IMP)sm_sig, "@@::");
	class_addMethod(c, @selector(forwardInvocation:), (IMP)sm_fwd, "v@:@");
	objc_registerClassPair(c);
	slog("SweetMTL: registered class SweetMTLDevice (super _MTLDevice) = %p", c);
}
