#!/bin/bash
# S21: a stand-in for AppleM2ScalerCSCDriver, the iPhone's hardware scaler / colour converter.
# CoreAnimation (iOS 16.7, attach_surface_texture) calls IOSurfaceAcceleratorCreate for YCbCr surfaces ('420v'/'420f')
# and skips the image when it gets NULL (PixOS research 87 U1, MIT, ideas only). That is why Safari/YouTube video boxes
# stayed black here although WebKit played the clips and backboardd saw the decoded frames (runs 239-249: 180 YCbCr
# textures, 0 draws). This publishes the service (attached to IOResources by hand, like S21Battery) with a user client
# that accepts every call, answers zeros and logs the calls ("fb scaler ..." lines, kept by the display keep buffer)
# so the transfer protocol can be filled in. Boot-arg sweetscaler=0: not published.
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
	if (n <= 48) {
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
