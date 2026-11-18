#!/bin/bash
# S21 MAX77705 charger + fuel gauge (bit-banged hsi2c_2) for SweetBattery (boot-arg sweetbattery=2).
# dxb runs patches/*.sh from the XNU source root before applying *.patch.
set -euo pipefail

[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0
[[ -f bsd/conf/files ]] || exit 1

cat > bsd/dev/sweet_max77705.c <<'EOF_SWEET_SRC'
/*
 * S21 (SM-G991, board o1s) MAX77705 PMIC: charger (I2C 0x69) and fuel gauge (0x36).
 *
 * Bus: hsi2c_2 = gpp1-0 SCL / gpp1-1 SDA in pinctrl@10430000 (PERIC0, bank +0x20), board pull-ups
 * (DT pin-pud 0). S-Boot talks to the PMIC through the HSI2C controller and leaves both pins in
 * function 2; we bit-bang them as GPIOs like the touch driver does (no USI/HSI2C driver in XNU).
 *
 * Register map and formulas: Samsung SM-G991B kernel drivers/battery/{charger,fuelgauge}/max77705_*
 *   CHG_INT_OK 0xB2 (bit6 CHGIN ok), DETAILS_00 0xB3, DETAILS_01 0xB4 (low nibble 0-2 charging,
 *   3-4 full), CNFG_00 0xB7 (MODE[3:0], 5 = buck + charger; WDTEN bit4), CNFG_02 0xB9 (CHG_CC 50 mA
 *   steps), CNFG_06 0xBD (WDTCLR[1:0] = 1 kicks the watchdog, CHGPROT[3:2] = 3 unlocks), CNFG_09 0xC0
 *   (CHGIN_ILIM, (mA / 25) - 1).
 *   FG: RepSOC 0x06 (1/256 %), VCELL 0x09 (78.125 uV), Current 0x0A (signed, 1.5625 uV / 5 mOhm).
 *
 * Why: nothing kicked the charger watchdog or configured the charger under XNU, the battery read a
 * fixed 100 % and the phone discharged to 0 % (brown-out reboot loop on 2026-11-18).
 *
 * Boot-args: sweetbattery=2 starts this (SweetBattery.cpp). sweetchg=0 = read only (no writes).
 *   sweetchg_cc=<mA> fast-charge current floor (default 1500), sweetchg_ilim=<mA> input limit floor
 *   (default 0 = leave S-Boot's setting).
 */
#if defined(ARM64_BOARD_CONFIG_SWEET)
#include <sys/param.h>
#include <sys/systm.h>
#include <kern/clock.h>
#include <kern/thread_call.h>
#include <mach/mach_time.h>
#include <machine/machine_routines.h>
#include <libkern/libkern.h>
#include <libkern/OSAtomic.h>
#include <pexpert/pexpert.h>
#include <stdarg.h>

extern vm_offset_t ml_io_map(vm_offset_t, vm_size_t);
void sweet_mali_log_str(const char *s);
void sweet_thermal_src(int src, int on);         /* 0111: keep CPU/GPU clocks low (source bit 1 here) */
void sweet_reboot_recovery_ext(const char *why); /* 0112: logged reset into TWRP */
int sweet_tmu_hottest(void);                     /* 0140: hottest SoC zone, C, -1 unknown */
/*
 * Thermal policy on the battery temperature (sampled with the 10 s poll), hysteresis 3 C:
 *   level 1 >= 43 C: charge current capped at 500 mA     level 2 >= 45 C: capped at 100 mA
 *   level 3 >= 46 C: + CPU/GPU clocks held at their low levels
 *   >= 55 C on two samples in a row: logged reset into the recovery (its Android kernel manages the heat)
 */
static int mx_tlevel, mx_thot;
static uint32_t mx_therm_cc;   /* 0 = no cap */
static uint32_t mx_soc_cc;     /* cap from the SoC temperature, 0 = none */

#define MX_BANK_PA   0x10430020U   /* gpp1 */
#define MX_CON       0x00U
#define MX_DAT       0x04U
#define MX_SCL       0U
#define MX_SDA       1U
#define MX_ADDR_CHG  0x69U
#define MX_ADDR_FG   0x36U

struct sweet_batt_info {
	int      valid;
	unsigned soc_x10;      /* 0.1 % */
	unsigned mv;
	int      ma;           /* + = into the battery */
	int      chgin;        /* cable power present */
	int      charging;
	int      full;
	unsigned dtls01, mode;
	int      temp_x10;     /* battery temperature, 0.1 C (FG TEMP 0x08: matches Android's battery temp), -1000 = unknown */
};

int sweet_max77705_start(void);
void sweet_max77705_get(struct sweet_batt_info *o);

static vm_offset_t mx_bank;
static struct sweet_batt_info mx_info;
static volatile UInt32 mx_busy;
static int mx_write_ok = 1, mx_started;
static uint32_t mx_cc_ma = 1500, mx_ilim_ma = 0, mx_errs, mx_polls;
static thread_call_t mx_tc;

static void
mx_log(const char *fmt, ...) __printflike(1, 2);
static void
mx_log(const char *fmt, ...)
{
	char line[176];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	sweet_mali_log_str(line);
}

static void
mx_us(uint32_t u)
{
	delay_for_interval(u, NSEC_PER_USEC);
}

static inline void
mx_func(uint32_t bit, uint32_t f)
{
	uint32_t v = *(volatile uint32_t *)(mx_bank + MX_CON);
	v = (v & ~(0xFU << (bit * 4))) | ((f & 0xFU) << (bit * 4));
	*(volatile uint32_t *)(mx_bank + MX_CON) = v;
}

/* open drain: low = output 0, high = input (pull-up) */
static inline void
mx_line(uint32_t bit, int high)
{
	if (high) {
		mx_func(bit, 0);
	} else {
		uint32_t v = *(volatile uint32_t *)(mx_bank + MX_DAT);
		*(volatile uint32_t *)(mx_bank + MX_DAT) = v & ~(1U << bit);
		mx_func(bit, 1);
	}
}

static inline int
mx_get(uint32_t bit)
{
	return (*(volatile uint32_t *)(mx_bank + MX_DAT) >> bit) & 1;
}

static void
mx_scl_high(void)
{
	mx_line(MX_SCL, 1);
	for (int t = 0; t < 200 && !mx_get(MX_SCL); t++) {   /* clock stretching */
		mx_us(5);
	}
}

static void
mx_start(void)
{
	mx_line(MX_SDA, 1); mx_scl_high(); mx_us(5);
	mx_line(MX_SDA, 0); mx_us(5);
	mx_line(MX_SCL, 0); mx_us(5);
}

static void
mx_stop(void)
{
	mx_line(MX_SDA, 0); mx_us(5);
	mx_scl_high(); mx_us(5);
	mx_line(MX_SDA, 1); mx_us(5);
}

static int
mx_wbyte(uint8_t b)
{
	for (int i = 7; i >= 0; i--) {
		mx_line(MX_SDA, (b >> i) & 1); mx_us(3);
		mx_scl_high(); mx_us(4);
		mx_line(MX_SCL, 0); mx_us(3);
	}
	mx_line(MX_SDA, 1); mx_us(3);
	mx_scl_high(); mx_us(4);
	int nak = mx_get(MX_SDA);
	mx_line(MX_SCL, 0); mx_us(3);
	return nak;
}

static uint8_t
mx_rbyte(int ack)
{
	uint8_t v = 0;
	mx_line(MX_SDA, 1);
	for (int i = 7; i >= 0; i--) {
		mx_scl_high(); mx_us(4);
		v = (uint8_t)((v << 1) | mx_get(MX_SDA));
		mx_line(MX_SCL, 0); mx_us(3);
	}
	mx_line(MX_SDA, !ack); mx_us(3);
	mx_scl_high(); mx_us(4);
	mx_line(MX_SCL, 0); mx_us(3);
	mx_line(MX_SDA, 1);
	return v;
}

/* free a bus a slave holds low (9 clocks + stop) */
static void
mx_recover(void)
{
	mx_line(MX_SDA, 1);
	for (int i = 0; i < 9 && !mx_get(MX_SDA); i++) {
		mx_line(MX_SCL, 0); mx_us(5);
		mx_scl_high(); mx_us(5);
	}
	mx_stop();
}

static int
mx_read(uint8_t addr, uint8_t reg, uint8_t *buf, int n)
{
	mx_start();
	if (mx_wbyte((uint8_t)(addr << 1)) || mx_wbyte(reg)) {
		mx_stop();
		mx_errs++;
		return -1;
	}
	mx_start();
	if (mx_wbyte((uint8_t)((addr << 1) | 1))) {
		mx_stop();
		mx_errs++;
		return -1;
	}
	for (int i = 0; i < n; i++) {
		buf[i] = mx_rbyte(i != n - 1);
	}
	mx_stop();
	return 0;
}

static int
mx_write(uint8_t addr, uint8_t reg, uint8_t val)
{
	mx_start();
	int r = mx_wbyte((uint8_t)(addr << 1)) || mx_wbyte(reg) || mx_wbyte(val);
	mx_stop();
	if (r) {
		mx_errs++;
	}
	return r ? -1 : 0;
}

static int
mx_r8(uint8_t addr, uint8_t reg, uint8_t *v)
{
	return mx_read(addr, reg, v, 1);
}

static int
mx_r16(uint8_t addr, uint8_t reg, uint16_t *v)
{
	uint8_t b[2];
	if (mx_read(addr, reg, b, 2)) {
		return -1;
	}
	*v = (uint16_t)(b[0] | (b[1] << 8));
	return 0;
}

/* update bits under mask; returns 1 when the register changed */
static int
mx_update(uint8_t reg, uint8_t val, uint8_t mask)
{
	uint8_t old;
	if (mx_r8(MX_ADDR_CHG, reg, &old)) {
		return -1;
	}
	uint8_t nv = (uint8_t)((old & ~mask) | (val & mask));
	if (nv == old) {
		return 0;
	}
	return mx_write(MX_ADDR_CHG, reg, nv) ? -1 : 1;
}

static void
mx_charger_service(int first)
{
	uint8_t ok, d0, d1, c0, c2, c9;
	if (mx_r8(MX_ADDR_CHG, 0xB2, &ok) || mx_r8(MX_ADDR_CHG, 0xB3, &d0) || mx_r8(MX_ADDR_CHG, 0xB4, &d1) ||
	    mx_r8(MX_ADDR_CHG, 0xB7, &c0) || mx_r8(MX_ADDR_CHG, 0xB9, &c2) || mx_r8(MX_ADDR_CHG, 0xC0, &c9)) {
		return;
	}
	int chgin = (ok & 0x40) != 0;
	if (first) {
		mx_log("chg: boot int_ok %02x dtls %02x %02x cnfg00 %02x cc %u mA ilim %u mA", ok, d0, d1, c0,
		    (c2 & 0x3F) * 50U, ((c9 & 0x7F) + 1U) * 25U);
	}
	if (!mx_write_ok) {
		goto out;
	}
	/* unlock the charger settings, then kick the charger watchdog (CNFG_06) */
	(void)mx_update(0xBD, 0x0C, 0x0C);
	{
		uint8_t c6;
		if (!mx_r8(MX_ADDR_CHG, 0xBD, &c6)) {
			(void)mx_write(MX_ADDR_CHG, 0xBD, (uint8_t)((c6 & ~0x03) | 0x01));   /* WDTCLR = 1, always written */
		}
	}
	if (chgin) {
		int changed = 0;
		uint8_t mode = c0 & 0x0F;
		if (mode != 5 && mode != 6 && mode != 7) {
			changed |= mx_update(0xB7, 0x05, 0x0F) > 0;     /* buck + charger on */
		}
		if (mx_therm_cc) {
			/* thermal cap: lower the charge current (never raise it while hot) */
			if ((c2 & 0x3F) * 50U > mx_therm_cc) {
				changed |= mx_update(0xB9, (uint8_t)(mx_therm_cc / 50U), 0x3F) > 0;
			}
		} else {
			if (mx_cc_ma && (c2 & 0x3F) * 50U < mx_cc_ma) {
				changed |= mx_update(0xB9, (uint8_t)(mx_cc_ma / 50U), 0x3F) > 0;
			}
			if (mx_ilim_ma >= 100 && ((c9 & 0x7F) + 1U) * 25U < mx_ilim_ma) {
				changed |= mx_update(0xC0, (uint8_t)(mx_ilim_ma / 25U - 1U), 0x7F) > 0;
			}
		}
		if (changed) {
			uint8_t n0 = 0, n2 = 0, n9 = 0;
			mx_r8(MX_ADDR_CHG, 0xB7, &n0); mx_r8(MX_ADDR_CHG, 0xB9, &n2); mx_r8(MX_ADDR_CHG, 0xC0, &n9);
			mx_log("chg: set cnfg00 %02x->%02x cc %u->%u mA ilim %u->%u mA", c0, n0, (c2 & 0x3F) * 50U,
			    (n2 & 0x3F) * 50U, ((c9 & 0x7F) + 1U) * 25U, ((n9 & 0x7F) + 1U) * 25U);
			c0 = n0;
		}
	}
out:
	mx_info.chgin = chgin;
	mx_info.dtls01 = d1;
	mx_info.mode = c0 & 0x0F;
	uint8_t st = d1 & 0x0F;
	mx_info.charging = chgin && st <= 2;
	mx_info.full = chgin && (st == 3 || st == 4);
}

static void
mx_poll(void)
{
	uint16_t soc, vc, cur;
	int first = mx_polls++ == 0;
	if (mx_r16(MX_ADDR_FG, 0x06, &soc) || mx_r16(MX_ADDR_FG, 0x09, &vc) || mx_r16(MX_ADDR_FG, 0x0A, &cur)) {
		mx_recover();
		if (mx_errs < 8 || (mx_errs % 64) == 0) {
			mx_log("chg: fg read failed (errs %u)", mx_errs);
		}
		mx_info.valid = 0;
		return;
	}
	unsigned s = ((unsigned)(soc >> 8) * 100U + (unsigned)(soc & 0xFF) * 100U / 256U) / 10U;
	unsigned mv = (unsigned)(((uint64_t)(vc & 0xFFF) * 78125ULL) / 1000000ULL) +
	    ((unsigned)((((uint64_t)((vc & 0xF000) >> 4)) * 78125ULL) / 1000000ULL) << 4);
	int raw = (cur & 0x8000) ? (int)cur - 65536 : (int)cur;
	mx_info.soc_x10 = s > 1000 ? 1000 : s;
	mx_info.mv = mv;
	mx_info.ma = -(raw * 15625 * 2 / 100000);   /* the register counts charge as negative here (run184: -1.2 A while SOC rose 31 -> 35 %) */
	mx_info.valid = mv >= 2800 && mv <= 4600;
	{
		uint16_t tr = 0;
		int t10 = -1000;
		if (!mx_r16(MX_ADDR_FG, 0x08, &tr)) {
			int raw16 = (tr & 0x8000) ? (int)tr - 65536 : (int)tr;
			t10 = raw16 * 10 / 256;
			if (t10 < -300 || t10 > 1000) {
				t10 = -1000;
			}
		}
		mx_info.temp_x10 = t10;
		/*
		 * FG TEMP is not live here: Android's charger driver writes the thermistor reading into it, so under iOS it
		 * keeps the last value (run184: 26.1 C for 9 minutes while charging). The charge current therefore also
		 * follows the SoC's hottest zone (0140): >= 65 C 500 mA, >= 75 C 100 mA, released below 60 C.
		 */
		{
			static uint32_t soc_cc;
			int soc = sweet_tmu_hottest();
			uint32_t want = soc >= 75 ? 100U : soc >= 65 ? 500U : (soc > 0 && soc < 60) || soc <= 0 ? 0U : soc_cc;
			if (want != soc_cc) {
				mx_log("chg: SoC %d C: charge cap %u mA", soc, want);
				soc_cc = want;
			}
			mx_soc_cc = soc_cc;
		}
		if (t10 > -1000) {
			int lv = mx_tlevel;
			int up = t10 >= 460 ? 3 : t10 >= 450 ? 2 : t10 >= 430 ? 1 : 0;
			if (up > lv) {
				lv = up;
			} else {
				while (lv > 0 && t10 < (lv == 3 ? 430 : lv == 2 ? 420 : 400)) {
					lv--;
				}
			}
			if (lv != mx_tlevel || first) {
				mx_log("chg: temp %d.%d C thermal level %d -> %d", t10 / 10, (t10 < 0 ? -t10 : t10) % 10, mx_tlevel, lv);
				mx_tlevel = lv;
			}
			mx_therm_cc = lv >= 2 ? 100U : lv == 1 ? 500U : 0U;
			if (mx_soc_cc && (!mx_therm_cc || mx_soc_cc < mx_therm_cc)) {
				mx_therm_cc = mx_soc_cc;
			}
			sweet_thermal_src(1, lv >= 3);
			mx_thot = t10 >= 550 ? mx_thot + 1 : 0;
			if (mx_thot >= 2) {
				mx_log("chg: battery %d.%d C twice: reset into the recovery", t10 / 10, t10 % 10);
				sweet_reboot_recovery_ext("battery over 55 C");
			}
		}
	}
	mx_charger_service(first);
	if (first || (mx_polls % 6) == 0) {   /* once a minute: temperature and current over time */
		mx_log("chg: soc %u.%u%% %u mV %d mA chgin %d dtls01 %02x mode %u errs %u temp %d", mx_info.soc_x10 / 10,
		    mx_info.soc_x10 % 10, mv, mx_info.ma, mx_info.chgin, mx_info.dtls01, mx_info.mode, mx_errs, mx_info.temp_x10);
	}
}

static void
mx_tick(__unused thread_call_param_t p0, __unused thread_call_param_t p1)
{
	if (OSCompareAndSwap(0, 1, &mx_busy)) {
		mx_poll();
		mx_busy = 0;
	}
	uint64_t dl;
	clock_interval_to_deadline(10, NSEC_PER_SEC, &dl);
	thread_call_enter_delayed(mx_tc, dl);
}

int
sweet_max77705_start(void)
{
	if (mx_started) {
		return mx_info.valid ? 0 : -1;
	}
	mx_started = 1;
	PE_parse_boot_argn("sweetchg", &mx_write_ok, sizeof(mx_write_ok));
	PE_parse_boot_argn("sweetchg_cc", &mx_cc_ma, sizeof(mx_cc_ma));
	PE_parse_boot_argn("sweetchg_ilim", &mx_ilim_ma, sizeof(mx_ilim_ma));
	if (mx_cc_ma > 3000) {
		mx_cc_ma = 3000;
	}
	if (mx_ilim_ma > 3000) {
		mx_ilim_ma = 3000;
	}
	mx_bank = ml_io_map(MX_BANK_PA, 0x20);
	if (!mx_bank) {
		mx_log("chg: map failed");
		return -1;
	}
	uint32_t con = *(volatile uint32_t *)(mx_bank + MX_CON);
	/* expect S-Boot's HSI2C function (2) on both pins; anything else = wrong bank, do not touch */
	if ((con & 0xFF) != 0x22) {
		mx_log("chg: gpp1 con %08x not hsi2c (0x22), not touching it", con);
		return -1;
	}
	mx_line(MX_SDA, 1);
	mx_line(MX_SCL, 1);
	mx_us(20);
	mx_recover();
	mx_poll();
	mx_log("chg: started (writes %s, cc floor %u mA, ilim floor %u mA)", mx_write_ok ? "on" : "off",
	    mx_cc_ma, mx_ilim_ma);
	mx_tc = thread_call_allocate(mx_tick, NULL);
	uint64_t dl;
	clock_interval_to_deadline(10, NSEC_PER_SEC, &dl);
	thread_call_enter_delayed(mx_tc, dl);
	return mx_info.valid ? 0 : -1;
}

void
sweet_max77705_get(struct sweet_batt_info *o)
{
	*o = mx_info;
}
#endif /* ARM64_BOARD_CONFIG_SWEET */
EOF_SWEET_SRC

grep -q 'bsd/dev/sweet_max77705.c' bsd/conf/files || printf 'bsd/dev/sweet_max77705.c\t\tstandard\n' >> bsd/conf/files
