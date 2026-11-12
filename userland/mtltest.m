/* Phase-1 Metal check: does MTLCreateSystemDefaultDevice() reach the SweetMetal plugin? */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <mach/mach.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <dlfcn.h>
#include <execinfo.h>
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
static void rawlog(const char *b) { if (gc) IOConnectCallMethod(gc, 5, NULL, 0, b, strlen(b), NULL, NULL, NULL, NULL); }
static void onsig(int sg)
{
	char b[150], t[70];
	snprintf(b, sizeof b, "mtltest: CRASH signal %d", sg); rawlog(b);
	void *fr[24]; int n = backtrace(fr, 24);
	for (int i = 0; i < n; i++) { snprintf(b, sizeof b, "mtltest: bt%d %s", i, symof((uint64_t)fr[i], t, sizeof t)); rawlog(b); }
	_exit(1);
}
static void onexc(NSException *e)
{
	char b[150];
	snprintf(b, sizeof b, "mtltest: EXC %s", [[e name] UTF8String]); rawlog(b);
	const char *r = [[e reason] UTF8String];
	for (size_t o = 0; r && o < strlen(r) && o < 420; o += 120) { snprintf(b, sizeof b, "mtltest: EXC: %.120s", r + o); rawlog(b); }
	NSArray *st = [e callStackSymbols];
	for (NSUInteger i = 0; i < st.count && i < 14; i++) { snprintf(b, sizeof b, "mtltest: ebt %.130s", [st[i] UTF8String]); rawlog(b); }
}
extern char **environ;
static void open_gc(void)
{
	io_service_t s = 0;
	for (int i = 0; i < 30 && !s; i++) { s = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("SweetMali")); if (!s) sleep(2); }
	if (s) IOServiceOpen(s, mach_task_self(), 0, &gc);
}
/* Guardian: runs the real test as a child, reports how it ended, then sends the phone to the recovery. */
static int guardian(char *self)
{
	open_gc();
	char *av[] = { self, "child", NULL };
	pid_t pid = 0;
	int rc = posix_spawn(&pid, self, NULL, NULL, av, environ);
	ulog("guardian: spawn rc=%d pid=%d", rc, pid);
	int st = 0, done = 0;
	for (int t = 0; rc == 0 && t < 45; t++) {
		if (waitpid(pid, &st, WNOHANG) == pid) { done = 1; break; }
		sleep(1);
	}
	if (done) ulog("guardian: child ended raw=%x exited=%d code=%d signaled=%d sig=%d", st, WIFEXITED(st), WEXITSTATUS(st), WIFSIGNALED(st), WTERMSIG(st));
	else ulog("guardian: child still running after 45s");
	sleep(2);
	if (gc) IOConnectCallMethod(gc, 7, NULL, 0, NULL, 0, NULL, NULL, NULL, NULL);
	for (;;) pause();
	return 0;
}

int main(int argc, char **argv)
{
	if (argc < 2) return guardian(argv[0]);
	NSSetUncaughtExceptionHandler(onexc);
	signal(SIGSEGV, onsig); signal(SIGBUS, onsig); signal(SIGABRT, onsig); signal(SIGILL, onsig); signal(SIGTRAP, onsig);
	@autoreleasepool {
		open_gc();
		io_service_t s = gc;
		io_service_t acc = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOAcceleratorES"));
		ulog("mtltest: SweetMali=%u IOAcceleratorES=%u", s, acc);
		g_main_thr = mach_thread_self();
		pthread_t wt; pthread_create(&wt, NULL, watchdog, NULL);
		ulog("mtltest: calling MTLCreateSystemDefaultDevice");
		id<MTLDevice> d = nil;
		@try { d = MTLCreateSystemDefaultDevice(); } @catch (NSException *e) { ulog("mtltest: exception %s", [[e description] UTF8String]); }
		ulog("mtltest: MTLCreateSystemDefaultDevice -> %p %s", d, d ? object_getClassName(d) : "nil");
		if (d) ulog("mtltest: name=%s", [[d name] UTF8String]);
		if (d) {
			id<MTLCommandQueue> q = [d newCommandQueue];
			ulog("mtltest: newCommandQueue -> %p", q);
			MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
			td.usage = MTLTextureUsageRenderTarget;
			id<MTLTexture> tex = [d newTextureWithDescriptor:td];
			ulog("mtltest: newTexture -> %p", tex);
			if (q && tex) {
				static uint32_t px[64 * 64];
				for (int i = 0; i < 64 * 64; i++) px[i] = 0xDEADBEEF;
				[tex replaceRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0 withBytes:px bytesPerRow:256];
				MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
				rp.colorAttachments[0].texture = tex;
				rp.colorAttachments[0].loadAction = MTLLoadActionClear;
				rp.colorAttachments[0].storeAction = MTLStoreActionStore;
				rp.colorAttachments[0].clearColor = MTLClearColorMake(1.0, 0.5, 0.0, 1.0);
				id<MTLCommandBuffer> cb = [q commandBuffer];
				id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
				[enc endEncoding];
				[cb commit];
				[cb waitUntilCompleted];
				[tex getBytes:px bytesPerRow:256 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
				int good = 0;
				for (int i = 0; i < 64 * 64; i++) if (px[i] == 0xFF0080FFu) good++;
				ulog("mtltest: metal clear status=%lu px0=%08x good=%d/4096 %s", (unsigned long)cb.status, px[0], good,
				    good == 4096 ? "METAL-CLEAR-ON-MALI-OK" : "METAL-CLEAR-FAIL");
				/* phase 2b: clear to blue and draw one triangle through the Metal draw API */
				MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
				pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
				NSError *perr = nil;
				id<MTLRenderPipelineState> ps = [d newRenderPipelineStateWithDescriptor:pd error:&perr];
				ulog("mtltest: pipeline -> %p", ps);
				rp.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 1.0, 1.0);
				cb = [q commandBuffer];
				enc = [cb renderCommandEncoderWithDescriptor:rp];
				[enc setRenderPipelineState:ps];
				[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
				[enc endEncoding];
				[cb commit];
				[cb waitUntilCompleted];
				[tex getBytes:px bytesPerRow:256 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
				int tri = 0, bg = 0;
				for (int i = 0; i < 64 * 64; i++) { if (px[i] == 0xFF00FF00u) tri++; else if (px[i] == 0xFFFF0000u) bg++; }
				ulog("mtltest: metal draw status=%lu tri=%d bg=%d p(10,10)=%08x p(50,50)=%08x %s", (unsigned long)cb.status, tri, bg,
				    px[10 * 64 + 10], px[50 * 64 + 50], tri > 1000 ? "METAL-TRIANGLE-ON-MALI-OK" : "METAL-TRIANGLE-FAIL");

				/* phase 2c: CoreAnimation's own vertex shader (std_vert0_lpf), translated AIR -> NIR -> Valhall */
				NSError *lerr = nil;
				id<MTLLibrary> lib = [d newLibraryWithURL:[NSURL fileURLWithPath:@"/System/Library/Frameworks/QuartzCore.framework/default.metallib"] error:&lerr];
				id<MTLFunction> vf = [lib newFunctionWithName:@"std_vert0_lpf"];
				id<MTLFunction> ff = [lib newFunctionWithName:@"no_fragment_yet"];
				MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
				vd.attributes[0].format = MTLVertexFormatFloat4; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0;
				vd.attributes[3].format = MTLVertexFormatFloat4; vd.attributes[3].offset = 16; vd.attributes[3].bufferIndex = 0;
				vd.layouts[0].stride = 32;
				MTLRenderPipelineDescriptor *pd2 = [MTLRenderPipelineDescriptor new];
				pd2.vertexFunction = vf; pd2.fragmentFunction = ff; pd2.vertexDescriptor = vd;
				pd2.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
				id<MTLRenderPipelineState> ps2 = [d newRenderPipelineStateWithDescriptor:pd2 error:&perr];
				/* clip-space triangle that maps to window (4,4) (60,4) (4,60) on 64x64; w = 2 to exercise the divide */
				static const float vtx[3 * 8] = {
					-1.75f,  1.75f, 1.0f, 2.0f,   1, 0, 0, 1,
					 1.75f,  1.75f, 1.0f, 2.0f,   0, 1, 0, 1,
					-1.75f, -1.75f, 1.0f, 2.0f,   0, 0, 1, 1 };
				static const float mvp[16] = { 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1 };
				id<MTLBuffer> vb = [d newBufferWithBytes:vtx length:sizeof vtx options:0];
				rp.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 1.0, 1.0);
				cb = [q commandBuffer];
				enc = [cb renderCommandEncoderWithDescriptor:rp];
				[enc setRenderPipelineState:ps2];
				[enc setVertexBuffer:vb offset:0 atIndex:0];
				[enc setVertexBytes:mvp length:sizeof mvp atIndex:2];
				[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
				[enc endEncoding];
				[cb commit];
				[cb waitUntilCompleted];
				[tex getBytes:px bytesPerRow:256 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
				tri = 0; bg = 0;
				for (int i = 0; i < 64 * 64; i++) { if (px[i] == 0xFF00FF00u) tri++; else if (px[i] == 0xFFFF0000u) bg++; }
				ulog("mtltest: AIR vs status=%lu tri=%d bg=%d p(10,10)=%08x p(50,50)=%08x %s", (unsigned long)cb.status, tri, bg,
				    px[10 * 64 + 10], px[50 * 64 + 50], tri > 1000 ? "APPLE-VS-ON-MALI-OK" : "APPLE-VS-FAIL");

				/* phase 2d: CoreAnimation's read_surf_frag (texture fetch at the pixel) + std_vert0_lpf full-screen quad */
				id<MTLFunction> ff2 = [lib newFunctionWithName:@"read_surf_frag"];
				MTLRenderPipelineDescriptor *pd3 = [MTLRenderPipelineDescriptor new];
				pd3.vertexFunction = vf; pd3.fragmentFunction = ff2; pd3.vertexDescriptor = vd;
				pd3.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
				id<MTLRenderPipelineState> ps3 = [d newRenderPipelineStateWithDescriptor:pd3 error:&perr];
				id<MTLTexture> src = [d newTextureWithDescriptor:td];
				static uint32_t pat[64 * 64];
				for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) pat[y * 64 + x] = 0xFF000000u | (x * 4) | ((y * 4) << 8) | (((x ^ y) & 1) ? 0xC00000u : 0x300000u);
				[src replaceRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0 withBytes:pat bytesPerRow:256];
				static const float quad[6 * 8] = {
					-1, 1, 0.5f, 1,  1,1,1,1,   1, 1, 0.5f, 1,  1,1,1,1,   -1,-1, 0.5f, 1,  1,1,1,1,
					 1, 1, 0.5f, 1,  1,1,1,1,   1,-1, 0.5f, 1,  1,1,1,1,   -1,-1, 0.5f, 1,  1,1,1,1 };
				id<MTLBuffer> qb = [d newBufferWithBytes:quad length:sizeof quad options:0];
				cb = [q commandBuffer];
				enc = [cb renderCommandEncoderWithDescriptor:rp];
				[enc setRenderPipelineState:ps3];
				[enc setVertexBuffer:qb offset:0 atIndex:0];
				[enc setVertexBytes:mvp length:sizeof mvp atIndex:2];
				[enc setFragmentTexture:src atIndex:0];
				[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
				[enc endEncoding];
				[cb commit];
				[cb waitUntilCompleted];
				[tex getBytes:px bytesPerRow:256 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
				int same = 0, firstbad = -1;
				for (int i = 0; i < 64 * 64; i++) { if (px[i] == pat[i]) same++; else if (firstbad < 0) firstbad = i; }
				ulog("mtltest: AIR fs status=%lu same=%d/4096 px0=%08x want=%08x px(33,17)=%08x want=%08x bad@%d %s", (unsigned long)cb.status,
				    same, px[0], pat[0], px[17 * 64 + 33], pat[17 * 64 + 33], firstbad, same == 4096 ? "APPLE-FS-TEXTURE-OK" : "APPLE-FS-TEXTURE-FAIL");
				/* debug fragment shaders through the same path */
				NSArray *dbg = @[ @"dbg_const16", @"dbg_fragxy", @"dbg_txf55", @"dbg_tex", @"read_surf_frag" ];
				MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
				sd.minFilter = MTLSamplerMinMagFilterNearest; sd.magFilter = MTLSamplerMinMagFilterNearest;
				id<MTLSamplerState> smp = [d newSamplerStateWithDescriptor:sd];
				for (NSString *fn in dbg) {
					MTLRenderPipelineDescriptor *pdx = [MTLRenderPipelineDescriptor new];
					pdx.vertexFunction = vf; pdx.fragmentFunction = [lib newFunctionWithName:fn]; pdx.vertexDescriptor = vd;
					pdx.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
					id<MTLRenderPipelineState> psx = [d newRenderPipelineStateWithDescriptor:pdx error:&perr];
					cb = [q commandBuffer];
					enc = [cb renderCommandEncoderWithDescriptor:rp];
					[enc setRenderPipelineState:psx];
					[enc setVertexBuffer:qb offset:0 atIndex:0];
					[enc setVertexBytes:mvp length:sizeof mvp atIndex:2];
					[enc setFragmentTexture:src atIndex:0];
					[enc setFragmentSamplerState:smp atIndex:0];
					[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
					[enc endEncoding];
					[cb commit];
					[cb waitUntilCompleted];
					[tex getBytes:px bytesPerRow:256 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
					ulog("mtltest: DBG %s st=%lu p(0,0)=%08x p(5,5)=%08x p(33,17)=%08x p(63,63)=%08x", fn.UTF8String, (unsigned long)cb.status,
					    px[0], px[5 * 64 + 5], px[17 * 64 + 33], px[63 * 64 + 63]);
				}
				ulog("mtltest: DBG src p(5,5)=%08x p(33,17)=%08x", pat[5 * 64 + 5], pat[17 * 64 + 33]);
			}
		}
		for (int n = 0;; n++) {
			if (gc) { char t[40]; snprintf(t, sizeof t, "== MTLTEST %d ==", n); IOConnectCallMethod(gc, 5, NULL, 0, t, strlen(t), NULL, NULL, NULL, NULL); }
			for (int i = (nh > 12 ? nh - 12 : 0); i < nh; i++) if (gc) IOConnectCallMethod(gc, 5, NULL, 0, hist[i % 12], strlen(hist[i % 12]), NULL, NULL, NULL, NULL);
			sleep(5);
		}
	}
	return 0;
}
