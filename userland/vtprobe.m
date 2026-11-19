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

static void vt_session(CMFormatDescriptionRef fd, AVAsset *asset, AVAssetTrack *tr, bool nohw)
{
	NSDictionary *dst = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
		(id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
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
	for (; fed < 60; fed++) {
		CMSampleBufferRef sb = [o copyNextSampleBuffer];
		if (!sb) break;
		VTDecodeInfoFlags inf = 0;
		if (fed == 0) lg("session: first decode call");
		dst2 = VTDecompressionSessionDecodeFrame(s, sb, 0, NULL, &inf);
		if (fed == 0) lg("session: first decode returned %d, frames %d", (int)dst2, vt_frames);
		CFRelease(sb);
		if (dst2 != noErr) break;
	}
	VTDecompressionSessionWaitForAsynchronousFrames(s);
	uint64_t ms = (clock_gettime_nsec_np(CLOCK_MONOTONIC) - t0) / 1000000;
	lg("session (%s): fed %d, decode %d, frames %d, errors %d (last %d), %llu ms", nohw ? "no hw" : "default", fed, (int)dst2,
	    vt_frames, vt_errs, (int)vt_last, (unsigned long long)ms);
	VTDecompressionSessionInvalidate(s); CFRelease(s);
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
	vt_session(fd, asset, tr, false);
	vt_session(fd, asset, tr, true);
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
