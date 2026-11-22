#!/bin/bash
# S21: a stand-in for AppleM2ScalerCSCDriver, the iPhone's hardware scaler / colour converter.
# CoreAnimation (iOS 16.7, attach_surface_texture) calls IOSurfaceAcceleratorCreate for YCbCr surfaces ('420v'/'420f')
# and skips the image when it gets NULL (PixOS research 87 U1, MIT, ideas only). That is why Safari/YouTube video boxes
# stayed black here although WebKit played the clips and backboardd saw the decoded frames (runs 239-249: 180 YCbCr
# textures, 0 draws). This publishes the service (attached to IOResources by hand, like S21Battery) with a user client
# that accepts every call and answers zeros; selector 1 (transfer, run250: source and destination IOSurface ids) is done
# on the CPU (BGRA / 420v / 420f, nearest-neighbour scaling). Calls and transfers are logged ("fb scaler ..." lines,
# kept by the display keep buffer). Boot-args: sweetscaler=0 not published, sweetscalerxfer=0 transfers left undone.
# Compiled as part of SweetMali.cpp (adding a line to files.arm64 breaks every later patch of that list, see 0127).
set -euo pipefail

[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0
[[ -f iokit/Kernel/arm/SweetMali.cpp ]] || exit 1   # 0112 runs first

cat >> iokit/Kernel/arm/SweetMali.cpp <<'EOF_SWEET_SRC'

/* ---- 0145-s21-scaler-standin.sh: AppleM2ScalerCSCDriver stand-in ---- */
#include <sys/proc.h>
class AppleM2ScalerCSCDriver : public IOService {
	OSDeclareDefaultStructors(AppleM2ScalerCSCDriver);
};
OSDefineMetaClassAndStructors(AppleM2ScalerCSCDriver, IOService);

class AppleM2ScalerCSCDriverUserClient : public IOUserClient {
	OSDeclareDefaultStructors(AppleM2ScalerCSCDriverUserClient);
	task_t fTask;
public:
	bool initWithTask(task_t owningTask, void *securityID, UInt32 type) APPLE_KEXT_OVERRIDE;
	IOReturn clientClose(void) APPLE_KEXT_OVERRIDE;
	IOReturn externalMethod(uint32_t selector, IOExternalMethodArguments *args, IOExternalMethodDispatch *dispatch,
	    OSObject *target, void *reference) APPLE_KEXT_OVERRIDE;
};
OSDefineMetaClassAndStructors(AppleM2ScalerCSCDriverUserClient, IOUserClient);

static uint32_t sweet_scaler_calls;

/*
 * Selector 1 (seen run250): IOSurfaceAcceleratorTransferSurface. Struct in 368 bytes: +0 source IOSurface id,
 * +4 destination id, +0x20 flags (0x3000), the rest zero so far (whole surface to whole surface). Callers:
 * mediaserverd (each video frame '420v' -> the layer's display surface) and SpringBoard (snapshots). Done on the
 * CPU here: nearest-neighbour scale between BGRA and 4:2:0 two-plane YCbCr in any direction.
 */
#include "SweetSurface.h"
enum { SC_NONE, SC_BGRA, SC_YUV_V, SC_YUV_F };
static int
sc_kind(SweetSurface *s)
{
	if (s->planeCount == 2 && s->pixelFormat == 0x34323076U) {
		return SC_YUV_V;
	}
	if (s->planeCount == 2 && s->pixelFormat == 0x34323066U) {
		return SC_YUV_F;
	}
	if (s->planeCount <= 1 && (s->bytesPerElement == 4 || s->bytesPerElement == 0) &&
	    (s->pixelFormat == 0x42475241U || s->pixelFormat == 0x41524742U || s->pixelFormat == 0)) {   /* 'BGRA', 'ARGB' layout as BGRA */
		return SC_BGRA;
	}
	return SC_NONE;
}
static inline uint8_t
sc_c8(int v)
{
	return v < 0 ? 0 : v > 255 ? 255 : (uint8_t)v;
}
static void
sc_dcache(const void *p, uint64_t len, bool invalidate)
{
	uintptr_t a = (uintptr_t)p & ~(uintptr_t)63, e = (uintptr_t)p + len;
	for (; a < e; a += 64) {
		if (invalidate) {
			__asm__ volatile ("dc civac, %0" :: "r"(a) : "memory");
		} else {
			__asm__ volatile ("dc cvac, %0" :: "r"(a) : "memory");
		}
	}
	__asm__ volatile ("dsb sy" ::: "memory");
}
struct sc_plane {
	uint8_t *p;
	uint32_t w, h, bpr;
};
static bool
sc_planes(SweetSurface *s, int kind, struct sc_plane pl[2], uint64_t *span_lo, uint64_t *span_len)
{
	uintptr_t base = s->kernelAddress();
	uint64_t len = s->memory != NULL ? s->memory->getLength() : 0;
	if (base == 0) {
		return false;
	}
	if (kind == SC_BGRA) {
		pl[0].p = (uint8_t *)base + s->offset;
		pl[0].w = s->width;
		pl[0].h = s->height;
		pl[0].bpr = s->bytesPerRow;
		if ((uint64_t)s->offset + (uint64_t)s->bytesPerRow * s->height > len || s->bytesPerRow < s->width * 4) {
			return false;
		}
		*span_lo = s->offset;
		*span_len = (uint64_t)s->bytesPerRow * s->height;
		return true;
	}
	for (int i = 0; i < 2; i++) {
		const struct sweet_surface_plane *q = &s->planes[i];
		pl[i].p = (uint8_t *)base + q->offset;
		pl[i].w = q->width;
		pl[i].h = q->height;
		pl[i].bpr = q->bytesPerRow;
		if ((uint64_t)q->offset + (uint64_t)q->bytesPerRow * q->height > len) {
			return false;
		}
	}
	if (pl[1].w * 2 < pl[0].w || pl[1].h * 2 < pl[0].h || pl[1].bpr < pl[1].w * 2) {
		return false;
	}
	*span_lo = s->planes[0].offset < s->planes[1].offset ? s->planes[0].offset : s->planes[1].offset;
	uint64_t e0 = (uint64_t)s->planes[0].offset + (uint64_t)pl[0].bpr * pl[0].h, e1 = (uint64_t)s->planes[1].offset + (uint64_t)pl[1].bpr * pl[1].h;
	*span_len = (e0 > e1 ? e0 : e1) - *span_lo;
	return true;
}
/* x256 matrix for the source YCbCr: BT.601 below 720 lines, BT.709 from 720 */
struct sc_mat { int ky, yo, crr, cbg, crg, cbb; };
static void
sc_matrix(int kind, uint32_t lines, struct sc_mat *m)
{
	bool full = kind == SC_YUV_F, hd = lines >= 720;
	m->ky = full ? 256 : 298;
	m->yo = full ? 0 : 16;
	m->crr = hd ? (full ? 403 : 459) : (full ? 359 : 409);
	m->cbg = hd ? (full ? 48 : 55) : (full ? 88 : 100);
	m->crg = hd ? (full ? 120 : 136) : (full ? 183 : 208);
	m->cbb = hd ? (full ? 475 : 541) : (full ? 454 : 516);
}
static int
sc_transfer(uint32_t sid, uint32_t did, char *why, size_t whylen)
{
	SweetSurface *s = sweet_surface_copy(sid), *d = sweet_surface_copy(did);
	int ret = -1;
	int sk = s ? sc_kind(s) : SC_NONE, dk = d ? sc_kind(d) : SC_NONE;
	struct sc_plane sp[2], dp[2];
	uint64_t slo = 0, slen = 0, dlo = 0, dlen = 0;
	if (s == NULL || d == NULL) {
		snprintf(why, whylen, "surface %u/%u not found", sid, did);
	} else if (sk == SC_NONE || dk == SC_NONE) {
		snprintf(why, whylen, "format %c%c%c%c(%u planes, bpe %u) -> %c%c%c%c(%u planes, bpe %u) not handled",
		    (char)(s->pixelFormat >> 24), (char)(s->pixelFormat >> 16), (char)(s->pixelFormat >> 8), (char)s->pixelFormat, s->planeCount, s->bytesPerElement,
		    (char)(d->pixelFormat >> 24), (char)(d->pixelFormat >> 16), (char)(d->pixelFormat >> 8), (char)d->pixelFormat, d->planeCount, d->bytesPerElement);
	} else if (!sc_planes(s, sk, sp, &slo, &slen) || !sc_planes(d, dk, dp, &dlo, &dlen)) {
		snprintf(why, whylen, "plane layout out of range");
	} else {
		sc_dcache((uint8_t *)s->kernelAddress() + slo, slen, true);   /* GPU-written sources (snapshots) */
		uint32_t sw = sp[0].w, sh = sp[0].h, dw = dp[0].w, dh = dp[0].h;
		uint32_t xs = (uint32_t)(((uint64_t)sw << 16) / (dw ? dw : 1)), ys = (uint32_t)(((uint64_t)sh << 16) / (dh ? dh : 1));
		struct sc_mat m;
		sc_matrix(sk, sh, &m);
		bool dfull = dk == SC_YUV_F;
		for (uint32_t y = 0; y < dh; y++) {
			uint32_t sy = (uint32_t)(((uint64_t)y * ys) >> 16);
			if (sy >= sh) {
				sy = sh - 1;
			}
			const uint8_t *s0 = sp[0].p + (uint64_t)sy * sp[0].bpr;
			const uint8_t *s1 = sk == SC_BGRA ? NULL : sp[1].p + (uint64_t)(sy >> 1) * sp[1].bpr;
			uint8_t *d0 = dp[0].p + (uint64_t)y * dp[0].bpr;
			uint8_t *d1 = dk == SC_BGRA ? NULL : dp[1].p + (uint64_t)(y >> 1) * dp[1].bpr;
			uint32_t fx = 0;
			for (uint32_t x = 0; x < dw; x++, fx += xs) {
				uint32_t sx = fx >> 16;
				if (sx >= sw) {
					sx = sw - 1;
				}
				int R, G, B;
				if (sk == SC_BGRA) {
					B = s0[sx * 4];
					G = s0[sx * 4 + 1];
					R = s0[sx * 4 + 2];
				} else if (dk != SC_BGRA) {
					/* YCbCr -> YCbCr: planes copied as they are (no matrix change between 420v and 420f) */
					d0[x] = s0[sx];
					if (d1 && !(y & 1) && !(x & 1)) {
						d1[x] = s1[sx & ~1U];
						d1[x + 1] = s1[(sx & ~1U) + 1];
					}
					continue;
				} else {
					int Y = ((int)s0[sx] - m.yo) * m.ky, U = (int)s1[sx & ~1U] - 128, V = (int)s1[(sx & ~1U) + 1] - 128;
					R = (Y + m.crr * V + 128) >> 8;
					G = (Y - m.cbg * U - m.crg * V + 128) >> 8;
					B = (Y + m.cbb * U + 128) >> 8;
				}
				if (dk == SC_BGRA) {
					uint32_t v = 0xFF000000U | ((uint32_t)sc_c8(R) << 16) | ((uint32_t)sc_c8(G) << 8) | sc_c8(B);
					if (sk == SC_BGRA) {
						v = (v & 0x00FFFFFFU) | ((uint32_t)s0[sx * 4 + 3] << 24);
					}
					*(uint32_t *)(d0 + (uint64_t)x * 4) = v;
				} else {
					/* RGB -> YCbCr (BT.601) */
					int Yv = dfull ? (77 * R + 150 * G + 29 * B + 128) >> 8 : ((66 * R + 129 * G + 25 * B + 128) >> 8) + 16;
					d0[x] = sc_c8(Yv);
					if (d1 && !(y & 1) && !(x & 1)) {
						int Cb = dfull ? ((-43 * R - 85 * G + 128 * B + 128) >> 8) + 128 : ((-38 * R - 74 * G + 112 * B + 128) >> 8) + 128;
						int Cr = dfull ? ((128 * R - 107 * G - 21 * B + 128) >> 8) + 128 : ((112 * R - 94 * G - 18 * B + 128) >> 8) + 128;
						d1[x] = sc_c8(Cb);
						d1[x + 1] = sc_c8(Cr);
					}
				}
			}
		}
		sc_dcache((uint8_t *)d->kernelAddress() + dlo, dlen, false);
		snprintf(why, whylen, "%c%c%c%c %ux%u -> %c%c%c%c %ux%u",
		    (char)(s->pixelFormat >> 24), (char)(s->pixelFormat >> 16), (char)(s->pixelFormat >> 8), (char)s->pixelFormat, sw, sh,
		    (char)(d->pixelFormat >> 24), (char)(d->pixelFormat >> 16), (char)(d->pixelFormat >> 8), (char)d->pixelFormat, dw, dh);
		ret = 0;
	}
	OSSafeReleaseNULL(s);
	OSSafeReleaseNULL(d);
	return ret;
}

bool
AppleM2ScalerCSCDriverUserClient::initWithTask(task_t owningTask, void *securityID, UInt32 type)
{
	if (!IOUserClient::initWithTask(owningTask, securityID, type)) {
		return false;
	}
	fTask = owningTask;
	char line[96];
	char name[20] = "?";
	proc_selfname(name, sizeof(name));   /* the opening process (IOServiceOpen runs in its context) */
	snprintf(line, sizeof(line), "fb scaler open by %s type %u", name, (unsigned)type);
	sweet_mali_log_str(line);
	return true;
}

IOReturn
AppleM2ScalerCSCDriverUserClient::clientClose(void)
{
	terminate();
	return kIOReturnSuccess;
}

IOReturn
AppleM2ScalerCSCDriverUserClient::externalMethod(uint32_t selector, IOExternalMethodArguments *args,
    __unused IOExternalMethodDispatch *dispatch, __unused OSObject *target, __unused void *reference)
{
	uint32_t n = ++sweet_scaler_calls;
	static int do_transfer = -1;
	if (do_transfer < 0) {
		int v = 1;
		PE_parse_boot_argn("sweetscalerxfer", &v, sizeof(v));
		do_transfer = v != 0;
	}
	if (selector == 1 && do_transfer && args->structureInput != NULL && args->structureInputSize >= 8) {
		const uint32_t *w = (const uint32_t *)args->structureInput;
		char why[128];
		uint64_t t0 = mach_absolute_time();
		int r = sc_transfer(w[0], w[1], why, sizeof(why));
		static uint32_t nt, nfail;
		nt++;
		if (r) {
			nfail++;
		}
		/* the first 8 transfers of each calling process (run251: SpringBoard's snapshots used up a global budget) */
		char pn[20] = "?";
		proc_selfname(pn, sizeof(pn));
		static char pnames[6][20];
		static uint32_t pcount[6];
		int slot = -1;
		for (int i = 0; i < 6; i++) {
			if (pnames[i][0] && !strncmp(pnames[i], pn, sizeof(pn))) {
				slot = i;
				break;
			}
			if (!pnames[i][0]) {
				strlcpy(pnames[i], pn, sizeof(pnames[i]));
				slot = i;
				break;
			}
		}
		bool say = slot >= 0 && ++pcount[slot] <= 8;
		if (say || (r && nfail <= 12) || (nt % 1000) == 0) {
			uint64_t ns = 0;
			absolutetime_to_nanoseconds(mach_absolute_time() - t0, &ns);
			char line[176];
			snprintf(line, sizeof(line), "fb scaler xfer %u %.12s: %u -> %u %s (%s) %llu us, %u failed, flags %x", nt, pn, w[0], w[1], r ? "FAILED" : "done", why, ns / 1000, nfail,
			    args->structureInputSize >= 0x24 ? w[8] : 0);
			sweet_mali_log_str(line);
			if (say && pcount[slot] <= 2) {
				/* every non-zero word of the request (rects, options) */
				int L = snprintf(line, sizeof(line), "fb scaler req %.12s:", pn);
				for (uint32_t o = 8; o + 4 <= args->structureInputSize; o += 4) {
					uint32_t v = w[o / 4];
					if (!v) {
						continue;
					}
					if (L > 150) {
						sweet_mali_log_str(line);
						L = snprintf(line, sizeof(line), "fb scaler req +");
					}
					L += snprintf(line + L, sizeof(line) - (size_t)L, " %03x=%x", o, v);
				}
				sweet_mali_log_str(line);
			}
		}
		for (uint32_t i = 0; i < args->scalarOutputCount; i++) {
			args->scalarOutput[i] = 0;
		}
		if (args->structureOutput != NULL && args->structureOutputSize) {
			bzero(args->structureOutput, args->structureOutputSize);
		}
		return kIOReturnSuccess;
	}
	if (n <= 24) {
		/* selector, scalar/struct sizes, first scalars and the first 24 words of the struct input */
		char line[176];
		int L = snprintf(line, sizeof(line), "fb scaler sel %u in %u/%u out %u/%u", selector, args->scalarInputCount,
		    args->structureInputSize, args->scalarOutputCount, args->structureOutputSize);
		for (uint32_t i = 0; i < args->scalarInputCount && i < 4 && L < 150; i++) {
			L += snprintf(line + L, sizeof(line) - (size_t)L, " s%u=%llx", i, args->scalarInput[i]);
		}
		sweet_mali_log_str(line);
		if (args->structureInput != NULL && args->structureInputSize >= 4) {
			const uint32_t *w = (const uint32_t *)args->structureInput;
			uint32_t nw = args->structureInputSize / 4;
			for (uint32_t base = 0; base < nw && base < 48; base += 12) {
				L = snprintf(line, sizeof(line), "fb scaler sel %u +%03x:", selector, base * 4);
				for (uint32_t i = base; i < nw && i < base + 12; i++) {
					L += snprintf(line + L, sizeof(line) - (size_t)L, " %x", w[i]);
				}
				sweet_mali_log_str(line);
			}
		}
	}
	for (uint32_t i = 0; i < args->scalarOutputCount; i++) {
		args->scalarOutput[i] = 0;
	}
	if (args->structureOutput != NULL && args->structureOutputSize) {
		bzero(args->structureOutput, args->structureOutputSize);
	}
	return kIOReturnSuccess;
}

extern "C" int sweet_scaler_start(void);
extern "C" int
sweet_scaler_start(void)
{
	static bool started;
	int on = 1;
	if (started) {
		return 0;
	}
	started = true;
	PE_parse_boot_argn("sweetscaler", &on, sizeof(on));
	if (!on) {
		return -1;
	}
	IOService *res = IOService::getResourceService();
	AppleM2ScalerCSCDriver *s = OSTypeAlloc(AppleM2ScalerCSCDriver);
	if (!res || !s || !s->init()) {
		OSSafeReleaseNULL(s);
		sweet_mali_log_str("fb scaler: alloc failed");
		return -1;
	}
	s->setProperty(kIOUserClientClassKey, "AppleM2ScalerCSCDriverUserClient");
	if (!s->attach(res) || !s->start(res)) {
		s->release();
		sweet_mali_log_str("fb scaler: attach/start failed");
		return -1;
	}
	s->registerService();
	s->release();
	sweet_mali_log_str("fb scaler: AppleM2ScalerCSCDriver stand-in published");
	return 0;
}
EOF_SWEET_SRC
