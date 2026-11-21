/* vtprobe: malinop's job (calendar clock from /usr/local/etc/sweet_epoch, then idle) plus, 100 s after start, a probe of
 * the video path YouTube needs: /usr/local/share/vt/test.mp4 (H.264 High + AAC, made on the Mac by push_rootfs.sh) through
 *   1. VTDecompressionSession (default decoder, then with hardware decode disabled),
 *   2. AVAssetReader with decoded output,
 *   3. AVPlayer + AVPlayerItemVideoOutput (does the clock run without an audio device? are frames delivered?),
 * and VTIsHardwareDecodeSupported for avc1/hvc1/av01. The iPhone X userland decodes H.264 with AppleD5500 hardware only
 * (H264H8.videodecoder), which the S21 does not have. Lines go to the kernel log via SweetMali selector 5 ("vt: ...").
 * Never prints file contents. */
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurfaceRef.h>
#include <TargetConditionals.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <unistd.h>
#include <mach/mach.h>

typedef mach_port_t io_connect_t, io_service_t, io_object_t;
extern const mach_port_t kIOMasterPortDefault;
extern io_service_t IOServiceGetMatchingService(mach_port_t, CFDictionaryRef);
extern CFMutableDictionaryRef IOServiceMatching(const char *);
extern kern_return_t IOServiceOpen(io_service_t, task_port_t, uint32_t, io_connect_t *);
extern kern_return_t IOConnectCallMethod(io_connect_t, uint32_t, const uint64_t *, uint32_t, const void *, size_t,
    uint64_t *, uint32_t *, void *, size_t *);

static io_connect_t gc;
/* user lines are not in the kernel's kept set and the 128 KiB ring loses them by the end of a run (run217): every line is
 * kept here and the whole set is said again every 20 s, so the last copy is near the end of the ring */
static char lines[40][160]; static int nlines;
static void say(const char *b) { if (gc) IOConnectCallMethod(gc, 5, NULL, 0, b, strlen(b), NULL, NULL, NULL, NULL); }
static void lg(const char *fmt, ...) __printflike(1, 2);
static void lg(const char *fmt, ...)
{
	char b[160] = "vt: ";
	va_list ap; va_start(ap, fmt); vsnprintf(b + 4, sizeof b - 4, fmt, ap); va_end(ap);
	fprintf(stderr, "%s\n", b);
	if (nlines < 40) strlcpy(lines[nlines++], b, sizeof lines[0]);
	say(b);
	/* the plugin in backboardd runs `vtprobe now` at the end of the test tour and logs this file (kept lines) */
	FILE *o = fopen("/private/var/tmp/vtprobe.txt", "a"); if (o) { fprintf(o, "%s\n", b); fclose(o); }
}
static const char *fcc(uint32_t c, char *b) { b[0] = c >> 24; b[1] = c >> 16; b[2] = c >> 8; b[3] = c; b[4] = 0; return b; }

static volatile int vt_frames, vt_errs; static volatile OSStatus vt_last;
static void vt_cb(void *ref, void *fref, OSStatus st, VTDecodeInfoFlags fl, CVImageBufferRef img, CMTime pts, CMTime dur)
{
	(void)ref; (void)fref; (void)fl; (void)pts; (void)dur;
	if (st == noErr && img) vt_frames++; else { vt_errs++; vt_last = st; }
}

static int vt_fmt;   /* 0: NV12 video range IOSurface, 1: no attributes, 2: BGRA IOSurface, 3: NV12 full range */
static void vt_session(CMFormatDescriptionRef fd, AVAsset *asset, AVAssetTrack *tr, bool nohw)
{
	uint32_t pf = vt_fmt == 2 ? kCVPixelFormatType_32BGRA : vt_fmt == 3 ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
	NSDictionary *dst = vt_fmt == 1 ? nil : @{ (id)kCVPixelBufferPixelFormatTypeKey: @(pf), (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
	lg("session fmt %d", vt_fmt);
	NSDictionary *spec = nohw ? @{ (id)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: @NO } : nil;
	VTDecompressionOutputCallbackRecord cb = { vt_cb, NULL };
	VTDecompressionSessionRef s = NULL;
	OSStatus st = VTDecompressionSessionCreate(NULL, fd, (__bridge CFDictionaryRef)spec, (__bridge CFDictionaryRef)dst, &cb, &s);
	lg("session (%s): create %d", nohw ? "no hw" : "default", (int)st);
	if (st != noErr || !s) return;
	lg("session: property");
	CFBooleanRef hw = NULL;
	if (VTSessionCopyProperty(s, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, NULL, &hw) == noErr && hw) {
		lg("session: hardware decoder %d", CFBooleanGetValue(hw)); CFRelease(hw);
	}
	lg("session: reader");
	NSError *e = nil;
	AVAssetReader *rd = [AVAssetReader assetReaderWithAsset:asset error:&e];
	AVAssetReaderTrackOutput *o = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:tr outputSettings:nil];
	[rd addOutput:o];
	if (![rd startReading]) { lg("reader start failed: %ld", (long)rd.error.code); VTDecompressionSessionInvalidate(s); CFRelease(s); return; }
	vt_frames = vt_errs = 0; vt_last = 0;
	int fed = 0; OSStatus dst2 = 0; uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC);
	for (; fed < 20; fed++) {
		CMSampleBufferRef sb = [o copyNextSampleBuffer];
		if (!sb) break;
		VTDecodeInfoFlags inf = 0;
		if (fed == 0) {
			/* run221-224: the first DecodeFrame returns -12902 (kVTParameterErr) at once: what the reader hands over */
			CMFormatDescriptionRef sfd = CMSampleBufferGetFormatDescription(sb);
			CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
			lg("session: sbuf samples %ld ready %d valid %d bytes %zu fd %s same-fd %d", (long)CMSampleBufferGetNumSamples(sb),
			    CMSampleBufferDataIsReady(sb), CMSampleBufferIsValid(sb), bb ? CMBlockBufferGetDataLength(bb) : 0,
			    sfd ? "yes" : "no", sfd ? CMFormatDescriptionEqual(sfd, fd) : -1);
			lg("session: first decode call");
		}
		if (CMSampleBufferGetNumSamples(sb) == 0) { CFRelease(sb); fed--; continue; }   /* marker buffers carry no frame */
		dst2 = VTDecompressionSessionDecodeFrame(s, sb, 0, NULL, &inf);
		if (fed == 0) lg("session: first decode returned %d, frames %d", (int)dst2, vt_frames);
		CFRelease(sb);
		if (dst2 != noErr) break;
	}
	if (dst2 == noErr) VTDecompressionSessionWaitForAsynchronousFrames(s);   /* after an error it never returned (run221) */
	uint64_t ms = (clock_gettime_nsec_np(CLOCK_MONOTONIC) - t0) / 1000000;
	lg("session (%s): fed %d, decode %d, frames %d, errors %d (last %d), %llu ms", nohw ? "no hw" : "default", fed, (int)dst2,
	    vt_frames, vt_errs, (int)vt_last, (unsigned long long)ms);
	VTDecompressionSessionInvalidate(s); CFRelease(s);
}


/* run222: mediaserverd died in H264SW writing a decoded row (SIGBUS, protection failure at a page start + 0x40): does
 * the IOSurface mapping of a video pixel buffer cover every plane? Plane ranges against the mapped region (vm_region). */
static void pb_layout(OSType pf, int w, int h)
{
	char a[5];
	CVPixelBufferRef pb = NULL;
	NSDictionary *at = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
	CVReturn cr = CVPixelBufferCreate(NULL, w, h, pf, (__bridge CFDictionaryRef)at, &pb);
	if (cr || !pb) { lg("pb %s %dx%d: create %d", fcc(pf, a), w, h, cr); return; }
	IOSurfaceRef sf = CVPixelBufferGetIOSurface(pb);
	CVPixelBufferLockBaseAddress(pb, 0);
	uint8_t *base = sf ? IOSurfaceGetBaseAddress(sf) : CVPixelBufferGetBaseAddress(pb);
	size_t alloc = sf ? IOSurfaceGetAllocSize(sf) : CVPixelBufferGetDataSize(pb);
	vm_address_t ra = (vm_address_t)base; vm_size_t rs = 0; vm_region_basic_info_data_64_t bi; mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t on;
	kern_return_t kr = vm_region_64(mach_task_self(), &ra, &rs, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&bi, &cnt, &on);
	lg("pb %s %dx%d: surf %d alloc %zu planes %zu, region +%lld size %llu prot %d (kr %d)", fcc(pf, a), w, h, sf != NULL, alloc,
	    CVPixelBufferGetPlaneCount(pb), (long long)((uint8_t *)ra - base), (unsigned long long)rs, kr ? -1 : bi.protection, kr);
	size_t np = CVPixelBufferGetPlaneCount(pb);
	for (size_t i = 0; i < np; i++) {
		uint8_t *pa = CVPixelBufferGetBaseAddressOfPlane(pb, i);
		size_t bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, i), ph = CVPixelBufferGetHeightOfPlane(pb, i), pw = CVPixelBufferGetWidthOfPlane(pb, i);
		long long off = (long long)(pa - base), end = off + (long long)(bpr * ph);
		lg("pb   plane %zu: off %lld %zux%zu bpr %zu end %lld%s sf(off %zu bpr %zu h %zu)", i, off, pw, ph, bpr, end,
		    end > (long long)rs ? " PAST MAPPING" : "", sf ? (size_t)((uint8_t *)IOSurfaceGetBaseAddressOfPlane(sf, i) - base) : 0,
		    sf ? IOSurfaceGetBytesPerRowOfPlane(sf, i) : 0, sf ? IOSurfaceGetHeightOfPlane(sf, i) : 0);
	}
	size_t el = 0, er = 0, et = 0, eb = 0; CVPixelBufferGetExtendedPixels(pb, &el, &er, &et, &eb);
	lg("pb   extended l%zu r%zu t%zu b%zu, data size %zu", el, er, et, eb, CVPixelBufferGetDataSize(pb));
	CVPixelBufferUnlockBaseAddress(pb, 0);
	CFRelease(pb);
}

static void probe(void)
{
	NSURL *u = [NSURL fileURLWithPath:@"/usr/local/share/vt/test.mp4"];
	if (![[NSFileManager defaultManager] fileExistsAtPath:u.path]) { lg("no test.mp4"); return; }
	char a[5], b[5], c[5];
	lg("hw decode supported: avc1 %d hvc1 %d av01 %d", VTIsHardwareDecodeSupported('avc1'), VTIsHardwareDecodeSupported('hvc1'),
	    VTIsHardwareDecodeSupported('av01'));
	(void)b; (void)c;
	AVURLAsset *asset = [AVURLAsset URLAssetWithURL:u options:nil];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	AVAssetTrack *tr = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
	AVAssetTrack *au = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
	NSArray *fds = tr.formatDescriptions;
#pragma clang diagnostic pop
	if (!tr || !fds.count) { lg("no video track"); return; }
	CMFormatDescriptionRef fd = (__bridge CMFormatDescriptionRef)fds[0];
	CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions(fd);
	lg("video %s %dx%d, audio track %s", fcc(CMFormatDescriptionGetMediaSubType(fd), a), d.width, d.height, au ? "yes" : "no");
	pb_layout(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 640, 360);
	pb_layout(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 1280, 720);
	pb_layout(kCVPixelFormatType_32BGRA, 640, 360);
	for (vt_fmt = 0; vt_fmt < 4; vt_fmt++) vt_session(fd, asset, tr, false);
	vt_fmt = 1; vt_session(fd, asset, tr, true);
	{
		NSError *e = nil;
		AVAssetReader *rd = [AVAssetReader assetReaderWithAsset:asset error:&e];
		AVAssetReaderTrackOutput *o = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:tr
			outputSettings:@{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) }];
		[rd addOutput:o];
		int n = 0;
		if ([rd startReading]) { CMSampleBufferRef sb; while (n < 30 && (sb = [o copyNextSampleBuffer])) { n++; CFRelease(sb); } }
		lg("asset reader decoded: %d frames, status %ld, error %ld", n, (long)rd.status, (long)rd.error.code);
	}
	{
		AVPlayerItem *it = [AVPlayerItem playerItemWithAsset:asset];
		AVPlayerItemVideoOutput *vo = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:
			@{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) }];
		[it addOutput:vo];
		AVPlayer *p = [AVPlayer playerWithPlayerItem:it];
		p.muted = YES;
		[p play];
		int got = 0;
		for (int i = 0; i < 40; i++) {
			[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
			CMTime t = [vo itemTimeForHostTime:CACurrentMediaTime()];
			if ([vo hasNewPixelBufferForItemTime:t]) { CVPixelBufferRef pb = [vo copyPixelBufferForItemTime:t itemTimeForDisplay:NULL]; if (pb) { got++; CFRelease(pb); } }
		}
		lg("player: item status %ld error %ld (%s), time %.2f s, rate %.2f, frames %d, timeControl %ld wait %s", (long)it.status,
		    (long)it.error.code, it.error ? it.error.domain.UTF8String : "-", CMTimeGetSeconds(it.currentTime), p.rate, got,
		    (long)p.timeControlStatus, p.reasonForWaitingToPlay ? p.reasonForWaitingToPlay.UTF8String : "-");
#if TARGET_OS_IOS
		AVAudioSession *as = [AVAudioSession sharedInstance];
		lg("audio session: route outputs %lu, sample rate %.0f", (unsigned long)as.currentRoute.outputs.count, as.sampleRate);
#endif
		[p pause];
	}
}

int main(int argc, char **argv)
{
	if (argc > 1 && !strcmp(argv[1], "now")) {   /* spawned by the plugin: probe at once, then exit */
		@autoreleasepool { lg("probe start (now)"); probe(); lg("probe done"); }
		return 0;
	}
	@autoreleasepool {
		FILE *f = fopen("/usr/local/etc/sweet_epoch", "r");
		long ep = 0;
		if (f) { if (fscanf(f, "%ld", &ep) != 1) ep = 0; fclose(f); }
		struct timeval now; gettimeofday(&now, NULL);
		if (ep > 1700000000L && now.tv_sec < ep) { struct timeval tv = { ep, 0 }; settimeofday(&tv, NULL); }
		for (int i = 0; i < 30 && !gc; i++) {
			io_service_t s = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("SweetMali"));
			if (s) IOServiceOpen(s, mach_task_self(), 0, &gc); else sleep(2);
		}
		sleep(60);
		lg("probe start");
		probe();
		lg("probe done");
	}
	for (int r = 0;; r++) { sleep(20); if (r < 60) for (int i = 0; i < nlines; i++) say(lines[i]); }
	return 0;
}
