#!/bin/bash
# S21 battery for iOS: an IOPMPowerSource fed by the MAX77705 fuel gauge (0123), boot-arg sweetbattery=2.
# The old SweetBattery (0062) never applied on the S21 tree (patch skipped), so iOS had no battery at all.
# dxb runs patches/*.sh from the XNU source root before applying *.patch.
set -euo pipefail

[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0
[[ -f iokit/conf/files.arm64 ]] || exit 1

cat > iokit/Kernel/arm/S21Battery.cpp <<'EOF_SWEET_SRC'
/*
 * S21 battery service. Created by sweet_s21_battery_start() (called from the S21 Mali core boot,
 * i.e. from SweetMali::start on the IOKit matching thread) and attached to IOResources by hand,
 * so no KernelConfigTables personality is needed. powerd matches IOPMPowerSource services.
 *
 * Values: sweet_max77705_get() (0123): RepSOC, VCELL, current, CHGIN and charger state. Capacity in
 * mAh against the S21 battery's nominal 4000 mAh (SM-G991 EB-BG991ABY), so CurrentCapacity *
 * 100 / MaxCapacity is the gauge's percentage.
 */
#if defined(ARM64_BOARD_CONFIG_SWEET)
#include <device/device_types.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/IOTimerEventSource.h>
#include <IOKit/pwr_mgt/IOPMPowerSource.h>
#include <pexpert/pexpert.h>

struct sweet_batt_info {
	int      valid;
	unsigned soc_x10;
	unsigned mv;
	int      ma;
	int      chgin;
	int      charging;
	int      full;
	unsigned dtls01, mode;
};
extern "C" int sweet_max77705_start(void);
extern "C" void sweet_max77705_get(struct sweet_batt_info *o);
extern "C" void sweet_mali_log_str(const char *s);
extern "C" int sweet_s21_battery_start(void);

#define S21_BATT_MAH 4000u

class S21Battery : public IOPMPowerSource {
	OSDeclareDefaultStructors(S21Battery);
public:
	bool start(IOService *provider) APPLE_KEXT_OVERRIDE;
private:
	IOWorkLoop *fLoop;
	IOTimerEventSource *fTimer;
	int fLastPct, fLastChg;
	void putNumber(const char *key, UInt32 value);
	void putBool(const char *key, bool value);
	void poll(void);
	static void timerFired(OSObject *owner, IOTimerEventSource *sender);
};
OSDefineMetaClassAndStructors(S21Battery, IOPMPowerSource);

void
S21Battery::putNumber(const char *key, UInt32 value)
{
	const OSSymbol *symbol = OSSymbol::withCString(key);
	OSNumber *number = OSNumber::withNumber(value, 32);
	if (symbol && number) {
		setPSProperty(symbol, number);
	}
	OSSafeReleaseNULL(number);
	OSSafeReleaseNULL(symbol);
}

void
S21Battery::putBool(const char *key, bool value)
{
	const OSSymbol *symbol = OSSymbol::withCString(key);
	if (symbol) {
		setPSProperty(symbol, value ? kOSBooleanTrue : kOSBooleanFalse);
		symbol->release();
	}
}

void
S21Battery::poll(void)
{
	struct sweet_batt_info b;
	sweet_max77705_get(&b);
	unsigned pct = 100, mv = 4200;
	int ma = 0;
	bool ext = true, chg = false, full = true;
	if (b.valid) {
		pct = (b.soc_x10 + 5u) / 10u;
		if (pct > 100) {
			pct = 100;
		}
		if (b.full) {
			pct = 100;
		}
		mv = b.mv;
		ma = b.ma;
		ext = b.chgin != 0;
		chg = b.charging != 0 && !b.full;
		full = b.full != 0;
	}
	const unsigned cap = (S21_BATT_MAH * pct + 50u) / 100u;
	setBatteryInstalled(true);
	setCurrentCapacity(cap);
	setMaxCapacity(S21_BATT_MAH);
	setExternalConnected(ext);
	setExternalChargeCapable(ext);
	setIsCharging(chg);
	setAtWarnLevel(false);
	setAtCriticalLevel(false);   /* never let iOS shut down on our numbers */
	setVoltage(mv);
	setAmperage(ma);
	setTimeRemaining(-1);
	setCycleCount(0);
	putBool("FullyCharged", full);
	putBool("AppleRawExternalConnected", ext);
	putNumber("AppleRawCurrentCapacity", cap);
	putNumber("AppleRawMaxCapacity", S21_BATT_MAH);
	putNumber("DesignCapacity", S21_BATT_MAH);
	putNumber("NominalChargeCapacity", S21_BATT_MAH);
	putNumber("InstantAmperage", (UInt32)ma);
	putNumber("Temperature", 2500);
	putBool("S21BatteryMeasured", b.valid != 0);
	OSDictionary *legacy = OSDictionary::withCapacity(7);
	if (legacy) {
		const char *keys[] = {kIOBatteryCurrentChargeKey, kIOBatteryCapacityKey,
		    kIOBatteryVoltageKey, kIOBatteryAmperageKey, kIOBatteryCycleCountKey, kIOBatteryFlagsKey};
		UInt32 values[] = {cap, S21_BATT_MAH, mv, (UInt32)ma, 0,
		    (UInt32)(kIOBatteryInstalled | (ext ? kIOBatteryChargerConnect : 0) | (chg ? kIOBatteryCharge : 0))};
		for (unsigned i = 0; i < sizeof(values) / sizeof(values[0]); ++i) {
			OSNumber *number = OSNumber::withNumber(values[i], 32);
			if (number) {
				legacy->setObject(keys[i], number);
				number->release();
			}
		}
		setLegacyIOBatteryInfo(legacy);
		legacy->release();
	}
	updateStatus();
	if ((int)pct != fLastPct || (int)chg != fLastChg) {
		char ln[120];
		snprintf(ln, sizeof(ln), "chg: ios battery %u%% %u mV %d mA ext %d charging %d full %d%s",
		    pct, mv, ma, ext, chg, full, b.valid ? "" : " (no gauge: fallback)");
		if (fLastPct < 0 || (fLastPct / 10) != (int)(pct / 10) || (int)chg != fLastChg) {
			sweet_mali_log_str(ln);
		}
		fLastPct = (int)pct;
		fLastChg = (int)chg;
	}
}

void
S21Battery::timerFired(OSObject *owner, IOTimerEventSource *sender)
{
	S21Battery *self = OSDynamicCast(S21Battery, owner);
	if (self) {
		self->poll();
		sender->setTimeoutMS(20000);
	}
}

bool
S21Battery::start(IOService *provider)
{
	if (!IOPMPowerSource::start(provider)) {
		return false;
	}
	fLastPct = -1;
	fLastChg = -1;
	poll();   /* complete source before registerService wakes powerd */
	fLoop = IOWorkLoop::workLoop();
	fTimer = IOTimerEventSource::timerEventSource(this, &S21Battery::timerFired);
	if (fLoop && fTimer && fLoop->addEventSource(fTimer) == kIOReturnSuccess) {
		fTimer->setTimeoutMS(20000);
	} else {
		sweet_mali_log_str("chg: battery timer unavailable");
	}
	registerService();
	return true;
}

extern "C" int
sweet_s21_battery_start(void)
{
	static bool started;
	int mode = 0;
	if (started) {
		return 0;
	}
	started = true;
	PE_parse_boot_argn("sweetbattery", &mode, sizeof(mode));
	if (mode != 2) {
		return -1;
	}
	(void)sweet_max77705_start();   /* polls (and services the charger) every 10 s on its own */
	IOService *res = IOService::getResourceService();
	S21Battery *b = OSTypeAlloc(S21Battery);
	if (!res || !b || !b->init()) {
		OSSafeReleaseNULL(b);
		sweet_mali_log_str("chg: battery service alloc failed");
		return -1;
	}
	if (!b->attach(res)) {
		b->release();
		sweet_mali_log_str("chg: battery service attach failed");
		return -1;
	}
	if (!b->start(res)) {
		b->detach(res);
		b->release();
		sweet_mali_log_str("chg: battery service start failed");
		return -1;
	}
	b->release();   /* the registry keeps it */
	sweet_mali_log_str("chg: ios battery service registered");
	return 0;
}
#endif /* ARM64_BOARD_CONFIG_SWEET */
EOF_SWEET_SRC

# build list entry: 0128-s21-battery-files.patch (appending here broke every later files.arm64 patch)
