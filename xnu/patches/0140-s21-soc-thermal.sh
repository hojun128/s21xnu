#!/bin/bash
# S21 SoC temperatures through ACPM TMU (channel 9) + thermal steps. Protocol from N1709/z3sios (MIT,
# redwood_exynos_acpm.c, itself from Samsung's exynos_acpm_tmu.c): cmd[1] = READ_TEMP 0x02 | zone << 16,
# reply cmd[1]: return code byte 1, degrees C byte 3; INIT 0x01 once. Zones BIG 0, MID 1, LITTLE 2, G3D 3.
# dxb runs patches/*.sh from the XNU source root before applying *.patch.
set -euo pipefail
[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0
[[ -f bsd/conf/files ]] || exit 1

cat > bsd/dev/sweet_tmu.c <<'EOF_SWEET_SRC'
/*
 * S21 SoC temperatures (boot-arg sweettmu, default 1; 0 = off): a kernel thread reads the four ACPM TMU zones
 * every second. Steps: any CPU zone >= 86 C or G3D >= 88 C holds the CPU/GPU clocks low (thermal cap source 2,
 * released 6 C lower); any zone >= 105 C on two readings in a row: logged reset into the recovery. Lines
 * ("dvfs tmu: ...") once a minute, at every 10 C step above 60 C and on every step change. Only the TMU
 * channel's own queue is used (the keys driver uses channel 2, DVFS channel 5).
 */
#if defined(ARM64_BOARD_CONFIG_SWEET)
#include <sys/param.h>
#include <sys/systm.h>
#include <kern/clock.h>
#include <kern/thread.h>
#include <kern/sched_prim.h>
#include <machine/machine_routines.h>
#include <pexpert/pexpert.h>
#include <stdarg.h>

extern vm_offset_t ml_io_map(vm_offset_t, vm_size_t);
extern void sweet_mali_log_str(const char *s);
extern void sweet_thermal_src(int src, int on);
extern void sweet_reboot_recovery_ext(const char *why);
int sweet_tmu_start(void);
int sweet_tmu_hottest(void);

#define TM_SRAM       0x02039000U
#define TM_SRAM_SIZE  0x41000U
#define TM_INIT       0x8000U
#define TM_MBOX       0x15900000U
#define TM_CH         9U
#define TM_INTGR0     0x08U
#define TM_INTCR1     0x20U
#define TM_INTGR1     0x0CU

static vm_offset_t tm_sram, tm_mbox;
static struct { uint32_t txr, txf, txb, rxr, rxf, rxb, len, sz; } tq;
static uint32_t tq_seq;
static volatile int tm_temp[4] = { -1, -1, -1, -1 };
static const char *const tm_name[4] = { "big", "mid", "little", "g3d" };

static void
tm_log(const char *fmt, ...)
{
	char b[160];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(b, sizeof(b), fmt, ap);
	va_end(ap);
	sweet_mali_log_str(b);
}

#define SR(o)      (*(volatile uint32_t *)(tm_sram + (o)))
#define MB(o)      (*(volatile uint32_t *)(tm_mbox + (o)))

static int
tq_init(void)
{
	tm_sram = ml_io_map(TM_SRAM, TM_SRAM_SIZE);
	tm_mbox = ml_io_map(TM_MBOX, 0x1000);
	if (!tm_sram || !tm_mbox) {
		return -1;
	}
	uint32_t chans = SR(TM_INIT + 8), apmax = SR(TM_INIT + 24);
	if (chans == 0 || chans >= TM_SRAM_SIZE || apmax == 0 || apmax > 32) {
		return -1;
	}
	for (uint32_t i = 0; i < apmax; i++) {
		uint32_t e = chans + i * 72U;
		if (e + 72U > TM_SRAM_SIZE || SR(e) != TM_CH) {
			continue;
		}
		uint32_t type = SR(e + 12);
		tq.txr = SR(e + 16); tq.txf = SR(e + 20); tq.txb = SR(e + 24);
		tq.rxr = SR(e + 40); tq.rxf = SR(e + 44); tq.rxb = SR(e + 48);
		tq.len = SR(e + 52); tq.sz = SR(e + 56);
		if (type != 1 || tq.len < 2 || tq.len > 64 || tq.sz < 16 || tq.sz > 64 ||
		    tq.txb + tq.len * tq.sz > TM_SRAM_SIZE || tq.rxb + tq.len * tq.sz > TM_SRAM_SIZE ||
		    tq.txr >= TM_SRAM_SIZE || tq.txf >= TM_SRAM_SIZE || tq.rxr >= TM_SRAM_SIZE || tq.rxf >= TM_SRAM_SIZE) {
			tm_log("dvfs tmu: acpm ch%u unusable type %u len %u sz %u", TM_CH, type, tq.len, tq.sz);
			return -1;
		}
		return 0;
	}
	tm_log("dvfs tmu: acpm ch%u not found", TM_CH);
	return -1;
}

/* one request on the TMU queue; 0 and the reply's word 1, or < 0 */
static int
tq_xfer(uint32_t w1, uint32_t *r1out)
{
	if (++tq_seq >= 64) {
		tq_seq = 1;
	}
	uint32_t front = SR(tq.txf);
	if (front >= tq.len) {
		return -1;
	}
	uint32_t next = (front + 1) % tq.len;
	for (int t = 0; t < 50 && next == SR(tq.txr); t++) {
		delay(20);
	}
	if (next == SR(tq.txr)) {
		return -2;
	}
	uint32_t base = tq.txb + tq.sz * front;
	SR(base) = (tq_seq & 0x3FU) << 16;
	SR(base + 4) = w1;
	for (uint32_t w = 2; w < tq.sz / 4; w++) {
		SR(base + w * 4) = 0;
	}
	__asm__ volatile ("dsb sy" ::: "memory");
	SR(tq.txf) = next;
	__asm__ volatile ("dsb sy" ::: "memory");
	MB(TM_INTGR0) = (1U << TM_CH) << 16;
	for (int t = 0; t < 1000; t++) {           /* ~10 ms */
		uint32_t f = SR(tq.rxf), rear = SR(tq.rxr), i = rear;
		while (i != f && i < tq.len && f < tq.len) {
			uint32_t e = tq.rxb + tq.sz * i;
			if (((SR(e) >> 16) & 0x3FU) == (tq_seq & 0x3FU)) {
				uint32_t r1 = SR(e + 4);
				if (i != rear) {
					for (uint32_t w = 0; w < tq.sz / 4; w++) {
						SR(e + w * 4) = SR(tq.rxb + tq.sz * rear + w * 4);
					}
				}
				rear = (rear + 1) % tq.len;
				SR(tq.rxr) = rear;
				__asm__ volatile ("dsb sy" ::: "memory");
				if (rear == SR(tq.rxf)) {
					MB(TM_INTCR1) = 1U << TM_CH;
					if (rear != SR(tq.rxf)) {
						MB(TM_INTGR1) = 1U << TM_CH;
					}
				}
				*r1out = r1;
				return 0;
			}
			i = (i + 1) % tq.len;
		}
		delay(10);
	}
	return -4;
}

static int
tm_read(unsigned zone)
{
	uint32_t r1 = 0;
	if (tq_xfer(0x02U | (zone << 16), &r1) != 0 || (int8_t)(r1 >> 8) != 0) {
		return -1;
	}
	int t = (int)((r1 >> 24) & 0xFFU);
	return t > 0 && t < 150 ? t : -1;
}

int
sweet_tmu_hottest(void)
{
	int h = -1;
	for (int z = 0; z < 4; z++) {
		if (tm_temp[z] > h) {
			h = tm_temp[z];
		}
	}
	return h;
}

static int tm_ev;

static void
tm_thread(__unused void *arg, __unused wait_result_t w)
{
	int capped = 0, crit = 0, lastdec = 0, fails = 0;
	uint32_t ticks = 0;
	for (;;) {
		int hot_cpu = 0, hot_gpu = 0, maxc = -1, ok = 0;
		for (unsigned z = 0; z < 4; z++) {
			int t = tm_read(z);
			tm_temp[z] = t;
			if (t >= 0) {
				ok++;
				if (t > maxc) {
					maxc = t;
				}
				if (z < 3 && t >= (capped ? 80 : 86)) {
					hot_cpu = 1;
				}
				if (z == 3 && t >= (capped ? 82 : 88)) {
					hot_gpu = 1;
				}
			}
		}
		if (!ok) {
			if (fails++ == 3) {
				tm_log("dvfs tmu: no readings, thermal steps off (battery temperature still protects)");
			}
			if (fails > 3) {
				return;
			}
		} else {
			fails = 0;
			int cap = hot_cpu || hot_gpu, dec = maxc >= 60 ? maxc / 10 : 0;
			if (cap != capped) {
				tm_log("dvfs tmu: %s at big %d mid %d little %d g3d %d C", cap ? "HOT: clocks held low" : "cooled: clocks released",
				    tm_temp[0], tm_temp[1], tm_temp[2], tm_temp[3]);
				sweet_thermal_src(2, cap);
				capped = cap;
			} else if ((ticks % 60) == 0 || dec > lastdec) {
				tm_log("dvfs tmu: big %d mid %d little %d g3d %d C%s", tm_temp[0], tm_temp[1], tm_temp[2], tm_temp[3],
				    capped ? " (capped)" : "");
			}
			lastdec = dec;
			crit = maxc >= 105 ? crit + 1 : 0;
			if (crit >= 2) {
				tm_log("dvfs tmu: %d C twice: reset into the recovery", maxc);
				sweet_reboot_recovery_ext("SoC over 105 C");
			}
		}
		ticks++;
		assert_wait_timeout((event_t)&tm_ev, THREAD_UNINT, 1000, NSEC_PER_MSEC);
		thread_block(THREAD_CONTINUE_NULL);
	}
}

int
sweet_tmu_start(void)
{
	static int started;
	int on = 1;
	thread_t th;
	if (started) {
		return 0;
	}
	started = 1;
	PE_parse_boot_argn("sweettmu", &on, sizeof(on));
	if (!on || tq_init() != 0) {
		tm_log("dvfs tmu: off");
		return -1;
	}
	uint32_t r1 = 0;
	int ir = tq_xfer(0x01U, &r1);   /* TMU_IPC_INIT, as exynos_acpm_tmu.c at probe */
	int t0 = tm_read(0);
	tm_log("dvfs tmu: ch%u len %u sz %u, init %d (%08x), big %d C", TM_CH, tq.len, tq.sz, ir, r1, t0);
	if (kernel_thread_start(tm_thread, NULL, &th) == KERN_SUCCESS) {
		thread_deallocate(th);
	}
	return 0;
}
#endif /* ARM64_BOARD_CONFIG_SWEET */
EOF_SWEET_SRC

grep -q 'bsd/dev/sweet_tmu.c' bsd/conf/files || printf 'bsd/dev/sweet_tmu.c\t\t\tstandard\n' >> bsd/conf/files
