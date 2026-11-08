#!/bin/bash
# S21 Mali IOKit service + user client (registered by 0120-s21-mali-iokit.patch).
# dxb runs patches/*.sh from the XNU source root before applying *.patch.
set -euo pipefail

[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0
[[ -f iokit/conf/files.arm64 ]] || exit 1

cat > iokit/Kernel/arm/SweetMali.cpp <<'EOF_SWEET_SRC'
/*
 * S21 Mali-G78 IOKit layer: service "SweetMali" (matched through IOResources) and its
 * user client "SweetMaliUserClient". Thin: all hardware work is in bsd/dev/sweet_mali.c.
 *
 * User-client selectors (IOConnectCallMethod):
 *   0 GET_INFO     out struct: u32 gpu_id, shader_present, tiler_present, l2_present, as_present, js_present
 *   1 CREATE_BO    in scalar: size (bytes)                 out scalars: handle, phys of first page
 *   2 MAP_BO       in scalars: handle, gpu_va              maps the whole BO into this client's GPU address space
 *   3 SUBMIT       in scalars: slot, jc_va, timeout_ms     out scalar: status (0 = done)
 *   4 DESTROY_BO   in scalar: handle
 * IOConnectMapMemory64(type = handle) maps a BO into the caller (write-combined, GPU not coherent).
 * Enabled by boot-arg mali=1 (see sweet_mali.c).
 */
#include <pexpert/arm64/board_config.h>

#if defined(ARM64_BOARD_CONFIG_SWEET)

#include <IOKit/IOService.h>
#include <IOKit/IOUserClient.h>
#include <IOKit/IOKitKeys.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOLocks.h>
#include <IOKit/IOMemoryDescriptor.h>
#include <IOKit/IOBufferMemoryDescriptor.h>
#include <libkern/c++/OSString.h>
#include <pexpert/pexpert.h>
#include <libkern/libkern.h>

extern "C" {
void sweet_mali_boot(void);
int sweet_mali_up(void);
void sweet_mali_get_info(uint32_t out[6]);
int sweet_mali_ctx_create(void);
void sweet_mali_ctx_destroy(int id);
int sweet_mali_ctx_map(int id, uint64_t va, uint64_t pa);
void sweet_mali_ctx_unmap(int id, uint64_t va);
uint32_t sweet_mali_submit(int id, uint32_t slot, uint64_t jc_va, uint32_t timeout_ms);
void sweet_mali_log_str(const char *s);
}

#define SM_MAX_BO        64
#define SM_MAX_BO_BYTES  (64ULL << 20)
#define SM_MAX_TOTAL     (256ULL << 20)

enum {
	kSMGetInfo = 0,
	kSMCreateBO = 1,
	kSMMapBO = 2,
	kSMSubmit = 3,
	kSMDestroyBO = 4,
};

static IOLock *sm_lock;                 /* serializes all hardware / context calls */
static uint64_t sm_total;               /* bytes of BOs alive */

static void
sm_log(const char *fmt, uint64_t a, uint64_t b, uint64_t c)
{
	char line[160];
	snprintf(line, sizeof(line), fmt, a, b, c);
	sweet_mali_log_str(line);
}

/* ---------------------------------------------------------------- service */

class SweetMali : public IOService {
	OSDeclareDefaultStructors(SweetMali);

public:
	bool start(IOService *provider) APPLE_KEXT_OVERRIDE;
};

OSDefineMetaClassAndStructors(SweetMali, IOService);

/* bring-up check through the same paths the user client uses: BO -> physical pages -> GPU map -> job */
static void
sweet_mali_service_selftest(void)
{
	const uint64_t VA_JOB = 0x30000000ULL, VA_OUT = 0x30001000ULL;
	int ctx = sweet_mali_ctx_create();
	IOBufferMemoryDescriptor *md = IOBufferMemoryDescriptor::inTaskWithOptions(kernel_task,
	    kIODirectionInOut | kIOMapWriteCombineCache, 2 * page_size, page_size);
	if (ctx < 0 || md == NULL) {
		sm_log("service selftest: no ctx/bo (ctx=%llx md=%llx)", (uint64_t)(int64_t)ctx, (uint64_t)(uintptr_t)md, 0);
		OSSafeReleaseNULL(md);
		return;
	}
	volatile uint32_t *p = (volatile uint32_t *)md->getBytesNoCopy();
	for (uint32_t i = 0; i < (2 * page_size) / 4; i++) {
		p[i] = 0;
	}
	IOByteCount l0 = 0, l1 = 0;
	addr64_t pa0 = md->getPhysicalSegment(0, &l0, kIOMemoryMapperNone);
	addr64_t pa1 = md->getPhysicalSegment(page_size, &l1, kIOMemoryMapperNone);
	if (pa0 == 0 || pa1 == 0 || sweet_mali_ctx_map(ctx, VA_JOB, pa0) || sweet_mali_ctx_map(ctx, VA_OUT, pa1)) {
		sm_log("service selftest: map failed (pa0=%llx pa1=%llx)", pa0, pa1, 0);
		md->release();
		sweet_mali_ctx_destroy(ctx);
		return;
	}
	volatile uint32_t *j = p;
	volatile uint32_t *o = p + page_size / 4;
	j[4] = (2U << 1) | 1U;
	j[8] = (uint32_t)VA_OUT;
	j[9] = (uint32_t)(VA_OUT >> 32);
	j[10] = 6U;
	j[12] = 0xC0FFEE03U;
	o[0] = 0xDEADBEEFU;
	__asm__ volatile ("dsb sy" ::: "memory");
	uint32_t r = sweet_mali_submit(ctx, 1, VA_JOB, 100);
	__asm__ volatile ("dsb sy" ::: "memory");
	sm_log("service selftest: status=%llx out=%llx exc=%llx", r, o[0], j[0]);
	if (o[0] == 0xC0FFEE03U) {
		sweet_mali_log_str("service selftest: OK THE GPU WROTE A USER-CLIENT STYLE BO");
	}
	md->release();
	sweet_mali_ctx_destroy(ctx);
}

bool
SweetMali::start(IOService *provider)
{
	int on = 0;
	if (!PE_parse_boot_argn("mali", &on, sizeof(on)) || !on) {
		return false;
	}
	if (!IOService::start(provider)) {
		return false;
	}
	sm_lock = IOLockAlloc();
	sweet_mali_boot();
	if (sm_lock == NULL || !sweet_mali_up()) {
		sweet_mali_log_str("service: GPU core is not up, not registering");
		return false;
	}
	setProperty(kIOUserClientClassKey, "SweetMaliUserClient");
	IOLockLock(sm_lock);
	sweet_mali_service_selftest();
	IOLockUnlock(sm_lock);
	registerService();
	sweet_mali_log_str("service: SweetMali registered");
	return true;
}

/* ------------------------------------------------------------ user client */

struct SMBo {
	IOBufferMemoryDescriptor *md;
	uint64_t va;
	uint32_t pages;
	bool     mapped;
};

class SweetMaliUserClient : public IOUserClient {
	OSDeclareDefaultStructors(SweetMaliUserClient);

	task_t fTask;
	int    fCtx;
	SMBo   fBo[SM_MAX_BO];

	void   freeBo(uint32_t i);

public:
	bool initWithTask(task_t owningTask, void *securityID, UInt32 type) APPLE_KEXT_OVERRIDE;
	IOReturn clientClose(void) APPLE_KEXT_OVERRIDE;
	IOReturn clientMemoryForType(UInt32 type, IOOptionBits *options, IOMemoryDescriptor **memory) APPLE_KEXT_OVERRIDE;
	IOReturn externalMethod(uint32_t selector, IOExternalMethodArguments *args,
	    IOExternalMethodDispatch *dispatch, OSObject *target,
	    void *reference) APPLE_KEXT_OVERRIDE;
};

OSDefineMetaClassAndStructors(SweetMaliUserClient, IOUserClient);

bool
SweetMaliUserClient::initWithTask(task_t owningTask, void *securityID, UInt32 type)
{
	if (!IOUserClient::initWithTask(owningTask, securityID, type)) {
		return false;
	}
	fTask = owningTask;
	fCtx = -1;
	bzero(fBo, sizeof(fBo));
	return true;
}

/* lock held */
void
SweetMaliUserClient::freeBo(uint32_t i)
{
	SMBo *b = &fBo[i];
	if (b->md == NULL) {
		return;
	}
	if (b->mapped) {
		for (uint32_t k = 0; k < b->pages; k++) {
			sweet_mali_ctx_unmap(fCtx, b->va + ((uint64_t)k << 12));
		}
	}
	sm_total -= (uint64_t)b->pages << 12;
	b->md->release();
	bzero(b, sizeof(*b));
}

IOReturn
SweetMaliUserClient::clientClose(void)
{
	IOLockLock(sm_lock);
	for (uint32_t i = 0; i < SM_MAX_BO; i++) {
		freeBo(i);
	}
	if (fCtx >= 0) {
		sweet_mali_ctx_destroy(fCtx);
		fCtx = -1;
	}
	IOLockUnlock(sm_lock);
	terminate();
	return kIOReturnSuccess;
}

IOReturn
SweetMaliUserClient::clientMemoryForType(UInt32 type, IOOptionBits *options, IOMemoryDescriptor **memory)
{
	IOReturn ret = kIOReturnBadArgument;
	IOLockLock(sm_lock);
	if (type >= 1 && type <= SM_MAX_BO && fBo[type - 1].md != NULL) {
		*options = 0;
		fBo[type - 1].md->retain();
		*memory = fBo[type - 1].md;
		ret = kIOReturnSuccess;
	}
	IOLockUnlock(sm_lock);
	return ret;
}

IOReturn
SweetMaliUserClient::externalMethod(uint32_t selector, IOExternalMethodArguments *args,
    __unused IOExternalMethodDispatch *dispatch, __unused OSObject *target, __unused void *reference)
{
	IOReturn ret = kIOReturnUnsupported;
	uint32_t ins = args->scalarInputCount, outs = args->scalarOutputCount;

	IOLockLock(sm_lock);
	switch (selector) {
	case kSMGetInfo: {
		uint32_t info[6];
		if (args->structureOutput == NULL || args->structureOutputSize < sizeof(info)) {
			ret = kIOReturnNoSpace;
			break;
		}
		sweet_mali_get_info(info);
		memcpy(args->structureOutput, info, sizeof(info));
		args->structureOutputSize = sizeof(info);
		ret = kIOReturnSuccess;
		break;
	}
	case kSMCreateBO: {
		if (ins < 1 || outs < 2) {
			ret = kIOReturnBadArgument;
			break;
		}
		uint64_t size = (args->scalarInput[0] + page_size - 1) & ~((uint64_t)page_size - 1);
		if (size == 0 || size > SM_MAX_BO_BYTES || sm_total + size > SM_MAX_TOTAL) {
			ret = kIOReturnNoSpace;
			break;
		}
		uint32_t slot = SM_MAX_BO;
		for (uint32_t i = 0; i < SM_MAX_BO; i++) {
			if (fBo[i].md == NULL) {
				slot = i;
				break;
			}
		}
		if (slot == SM_MAX_BO) {
			ret = kIOReturnNoResources;
			break;
		}
		IOBufferMemoryDescriptor *md = IOBufferMemoryDescriptor::inTaskWithOptions(kernel_task,
		    kIODirectionInOut | kIOMapWriteCombineCache, (vm_size_t)size, page_size);
		if (md == NULL) {
			ret = kIOReturnNoMemory;
			break;
		}
		bzero(md->getBytesNoCopy(), (size_t)size);
		IOByteCount len = 0;
		addr64_t pa = md->getPhysicalSegment(0, &len, kIOMemoryMapperNone);
		fBo[slot].md = md;
		fBo[slot].pages = (uint32_t)(size >> 12);
		fBo[slot].mapped = false;
		sm_total += size;
		args->scalarOutput[0] = slot + 1;
		args->scalarOutput[1] = pa;
		args->scalarOutputCount = 2;
		ret = kIOReturnSuccess;
		break;
	}
	case kSMMapBO: {
		if (ins < 2) {
			ret = kIOReturnBadArgument;
			break;
		}
		uint64_t h = args->scalarInput[0], va = args->scalarInput[1];
		if (h < 1 || h > SM_MAX_BO || fBo[h - 1].md == NULL || fBo[h - 1].mapped || (va & 0xFFF) ||
		    va >= (1ULL << 47)) {
			ret = kIOReturnBadArgument;
			break;
		}
		SMBo *b = &fBo[h - 1];
		if (fCtx < 0) {
			fCtx = sweet_mali_ctx_create();
			if (fCtx < 0) {
				ret = kIOReturnNoResources;
				break;
			}
		}
		ret = kIOReturnSuccess;
		for (uint32_t k = 0; k < b->pages; k++) {
			IOByteCount len = 0;
			addr64_t pa = b->md->getPhysicalSegment((IOByteCount)k << 12, &len, kIOMemoryMapperNone);
			if (pa == 0 || sweet_mali_ctx_map(fCtx, va + ((uint64_t)k << 12), pa)) {
				ret = kIOReturnNoMemory;
				break;
			}
		}
		if (ret == kIOReturnSuccess) {
			b->va = va;
			b->mapped = true;
		}
		break;
	}
	case kSMSubmit: {
		if (ins < 3 || outs < 1 || fCtx < 0) {
			ret = kIOReturnBadArgument;
			break;
		}
		uint32_t tmo = (uint32_t)args->scalarInput[2];
		if (tmo > 5000) {
			tmo = 5000;
		}
		args->scalarOutput[0] = sweet_mali_submit(fCtx, (uint32_t)args->scalarInput[0], args->scalarInput[1], tmo);
		args->scalarOutputCount = 1;
		ret = kIOReturnSuccess;
		break;
	}
	case kSMDestroyBO: {
		uint64_t h = ins > 0 ? args->scalarInput[0] : 0;
		if (h < 1 || h > SM_MAX_BO || fBo[h - 1].md == NULL) {
			ret = kIOReturnBadArgument;
			break;
		}
		freeBo((uint32_t)(h - 1));
		ret = kIOReturnSuccess;
		break;
	}
	default:
		break;
	}
	IOLockUnlock(sm_lock);
	return ret;
}

#endif /* ARM64_BOARD_CONFIG_SWEET */
EOF_SWEET_SRC
