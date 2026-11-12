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

/* ------------------------------------------------------------------ Metal objects (phase 2a) */
@interface SweetMTLTexture : NSObject
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

@interface SweetMTLCommandBuffer : NSObject
@property (nonatomic, strong) NSMutableArray *passes;
@property (nonatomic) NSUInteger status;
@property (nonatomic) uint32_t lastJobStatus;
@end

@interface SweetMTLRenderEncoder : NSObject
@property (nonatomic, strong) SweetMTLTexture *target;
@property (nonatomic) BOOL clear;
@property (nonatomic) uint32_t packed;
@end
@implementation SweetMTLRenderEncoder
- (void)endEncoding {}
- (void)setLabel:(NSString *)l {}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
	NSMethodSignature *m = [super methodSignatureForSelector:sel];
	return m ? m : [NSMethodSignature signatureWithObjCTypes:"@@:@@@@"];
}
- (void)forwardInvocation:(NSInvocation *)inv
{
	slog("SweetMTL: encoder unimplemented -%s", sel_getName(inv.selector));
	void *z = NULL; [inv setReturnValue:&z];
}
@end

@implementation SweetMTLCommandBuffer
- (instancetype)init { self = [super init]; _passes = [NSMutableArray array]; return self; }
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
	if (!have) have = sm_bo_alloc(&desc, 0x10000);
	_status = 4; /* MTLCommandBufferStatusCompleted */
	for (SweetMTLRenderEncoder *e in _passes) {
		if (!have || !e.target) { _status = 5; continue; }
		if (e.clear) {
			bool bgra = e.target.pixelFormat == MTLPixelFormatBGRA8Unorm;
			_lastJobStatus = sm_clear(&desc, e.target.bo->gpu, (uint32_t)e.target.width, (uint32_t)e.target.height,
			    (uint32_t)e.target.bytesPerRow, e.packed, bgra);
			uint32_t exc = *(volatile uint32_t *)desc.cpu;
			slog("SweetMTL: clear %lux%lu job status=%x exc=%x", (unsigned long)e.target.width, (unsigned long)e.target.height, _lastJobStatus, exc);
			if (_lastJobStatus != 0) _status = 5;
		}
	}
}
- (void)waitUntilCompleted {}
- (void)presentDrawable:(id)d {}
- (NSError *)error { return nil; }
- (void)setLabel:(NSString *)l {}
@end

@interface SweetMTLCommandQueue : NSObject
@end
@implementation SweetMTLCommandQueue
- (id)commandBuffer { return [SweetMTLCommandBuffer new]; }
- (void)setLabel:(NSString *)l {}
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

@interface SweetMTLDevice : _MTLDevice <MTLDevice, MTLDeviceSPI>
@end

@implementation SweetMTLDevice {
	uint32_t _smPort;
}

+ (void)load
{
	slog("SweetMTL: +load in %s, super=%s", getprogname() ? getprogname() : "?", class_getName(class_getSuperclass(self)));
}

- (instancetype)initWithAcceleratorPort:(uint32_t)port
{
	const char *pn = getprogname();
	slog("SweetMTL: initWithAcceleratorPort:%u in %s", port, pn ? pn : "?");
	if (pn == NULL || strcmp(pn, "malitest") != 0) {
		return nil;
	}
	self = [super init];
	slog("SweetMTL: super init -> %p", self);
	if (self) _smPort = port;
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
- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)d { return [[SweetMTLTexture alloc] initWithDevice:self descriptor:d]; }
- (uint64_t)registryID { return 0x53574545; }
- (BOOL)isLowPower { return NO; }
- (BOOL)isHeadless { return NO; }
- (BOOL)isRemovable { return NO; }
- (uint32_t)acceleratorPort { return _smPort; }

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
	NSMethodSignature *m = [super methodSignatureForSelector:sel];
	return m ? m : [NSMethodSignature signatureWithObjCTypes:"@@:@@@@"];
}

- (void)forwardInvocation:(NSInvocation *)inv
{
	slog("SweetMTL: unimplemented -%s", sel_getName(inv.selector));
	void *z = NULL;
	[inv setReturnValue:&z];
}

@end
