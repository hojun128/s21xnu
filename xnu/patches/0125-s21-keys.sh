#!/bin/bash
# S21 side keys: volume up/down (ALIVE gpa0-3/gpa0-4) and power (S2MPS23 PMIC STATUS1 over ACPM).
# dxb runs patches/*.sh from the XNU source root before applying *.patch.
set -euo pipefail

[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0
[[ -f bsd/conf/files ]] || exit 1

cat > bsd/dev/sweet_s21keys.c <<'EOF_SWEET_SRC'
/*
 * S21 (SM-G991, board o1s) hardware keys for SweetHIDButtons (sweet_hid_key: 0 power, 1 vol+, 2 vol-).
 *
 * The old sweet_keys.c (boot-arg sweetkeys) is for a Qualcomm SPMI board and stays off on the S21.
 *
 * Volume: DT gpio_keys, KEY_VOLUMEUP = gpa0-3, KEY_VOLUMEDOWN = gpa0-4, active low, pin function 0xF
 *   (EINT) in pinctrl@14EC0000 (ALIVE), bank gpa0 at +0 (CON +0, DAT +4). Read only.
 * Power: DT s2mps23-keys (KEY_POWER) sits on the S2MPS23 PMIC, which only the APM firmware talks to.
 *   Read only through the ACPM MFD protocol on IPC channel 2 (s2mps23mfd acpm-ipc-channel = 2,
 *   speedy channel 0), Samsung SM-G991B drivers/soc/samsung/acpm/acpm_mfd.c:
 *     cmd[0] = reg | type << 8 | speedy channel << 12 | seq << 16, cmd[1] = FUNC_READ (0)
 *     reply cmd[1]: value = bits 15..8, return code = bits 31..24
 *   type 1 = PMIC page (I2C_ADDR_PMIC), reg 0x0E = S2MPS23_PMIC_REG_STATUS1, bit 0 = PWRON (pressed).
 *   Channel 2 is a queue channel (run167 table dump: type 1, len 5, 16 B elements); the queue handling
 *   follows acpm_ipc.c __acpm_ipc_send_data / check_response.
 *
 * Boot-args: sweets21keys=0 off, sweets21pwr=0 no power key (no ACPM traffic).
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
extern void sweet_hid_key(int key, int down);
extern void sweet_mali_log_str(const char *s);
int sweet_s21keys_start(void);

#define SK_ALIVE      0x14EC0000U
#define SK_SRAM       0x02039000U
#define SK_SRAM_SIZE  0x41000U
#define SK_INIT       0x8000U
#define SK_MBOX       0x15900000U
#define SK_CH         2U
#define SK_INTGR0     0x08U
#define SK_INTCR1     0x20U
#define SK_INTGR1     0x0CU
#define SK_INTSR1     0x28U

static vm_offset_t sk_alive, sk_sram, sk_mbox;
static struct { uint32_t txr, txf, txb, rxr, rxf, rxb, len, sz; } kq;
static int kq_ok;
static uint32_t kq_seq, kq_err;
static int sk_started, sk_chan;

static void
sk_log(const char *fmt, ...)
{
	char b[200];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(b, sizeof(b), fmt, ap);
	va_end(ap);
	sweet_mali_log_str(b);
}

#define SR(o)      (*(volatile uint32_t *)(sk_sram + (o)))
#define MB(o)      (*(volatile uint32_t *)(sk_mbox + (o)))

static int
kq_init(void)
{
	sk_sram = ml_io_map(SK_SRAM, SK_SRAM_SIZE);
	sk_mbox = ml_io_map(SK_MBOX, 0x1000);
	if (!sk_sram || !sk_mbox) {
		return -1;
	}
	uint32_t chans = SR(SK_INIT + 8), apmax = SR(SK_INIT + 24);
	if (chans == 0 || chans >= SK_SRAM_SIZE || apmax == 0 || apmax > 32) {
		sk_log("keys: acpm bad initdata %x %u", chans, apmax);
		return -1;
	}
	for (uint32_t i = 0; i < apmax; i++) {
		uint32_t e = chans + i * 72U;
		if (e + 72U > SK_SRAM_SIZE) {
			break;
		}
		if (SR(e) != SK_CH) {
			continue;
		}
		uint32_t type = SR(e + 12);
		kq.txr = SR(e + 16); kq.txf = SR(e + 20); kq.txb = SR(e + 24);
		kq.rxr = SR(e + 40); kq.rxf = SR(e + 44); kq.rxb = SR(e + 48);
		kq.len = SR(e + 52); kq.sz = SR(e + 56);
		if (type != 1 || kq.len < 2 || kq.len > 64 || kq.sz < 16 || kq.sz > 64 ||
		    kq.txb + kq.len * kq.sz > SK_SRAM_SIZE || kq.rxb + kq.len * kq.sz > SK_SRAM_SIZE ||
		    kq.txr >= SK_SRAM_SIZE || kq.txf >= SK_SRAM_SIZE || kq.rxr >= SK_SRAM_SIZE || kq.rxf >= SK_SRAM_SIZE) {
			sk_log("keys: acpm ch%u unusable type %u len %u sz %u", SK_CH, type, kq.len, kq.sz);
			return -1;
		}
		return 0;
	}
	sk_log("keys: acpm ch%u not found", SK_CH);
	return -1;
}

/* one ACPM MFD read; 0 = ok */
static int
kq_read(uint32_t type, uint32_t reg, uint8_t *val)
{
	if (++kq_seq >= 64) {
		kq_seq = 1;
	}
	uint32_t front = SR(kq.txf);
	if (front >= kq.len) {
		return -1;
	}
	uint32_t next = (front + 1) % kq.len;
	for (int t = 0; t < 50 && next == SR(kq.txr); t++) {
		delay(20);
	}
	if (next == SR(kq.txr)) {
		return -2;   /* tx full */
	}
	uint32_t cmd0 = (reg & 0xFFU) | ((type & 0xFU) << 8) | (0U << 12) | ((kq_seq & 0x3FU) << 16);
	uint32_t base = kq.txb + kq.sz * front;
	SR(base) = cmd0;
	for (uint32_t w = 1; w < kq.sz / 4; w++) {
		SR(base + w * 4) = 0;    /* cmd[1] = FUNC_READ */
	}
	__asm__ volatile ("dsb sy" ::: "memory");
	SR(kq.txf) = next;
	__asm__ volatile ("dsb sy" ::: "memory");
	MB(SK_INTGR0) = (1U << SK_CH) << 16;
	for (int t = 0; t < 500; t++) {           /* ~5 ms */
		uint32_t f = SR(kq.rxf), rear = SR(kq.rxr), i = rear;
		while (i != f && i < kq.len && f < kq.len) {
			uint32_t e = kq.rxb + kq.sz * i;
			if (((SR(e) >> 16) & 0x3FU) == (kq_seq & 0x3FU)) {
				uint32_t r1 = SR(e + 4);
				if (i != rear) {   /* same compaction as check_response() */
					for (uint32_t w = 0; w < kq.sz / 4; w++) {
						SR(e + w * 4) = SR(kq.rxb + kq.sz * rear + w * 4);
					}
				}
				rear = (rear + 1) % kq.len;
				SR(kq.rxr) = rear;
				__asm__ volatile ("dsb sy" ::: "memory");
				if (rear == SR(kq.rxf)) {
					MB(SK_INTCR1) = 1U << SK_CH;
					if (rear != SR(kq.rxf)) {
						MB(SK_INTGR1) = 1U << SK_CH;
					}
				}
				if ((r1 >> 24) & 0xFFU) {
					return -3;   /* APM speedy rx failed */
				}
				*val = (uint8_t)((r1 >> 8) & 0xFFU);
				return 0;
			}
			i = (i + 1) % kq.len;
		}
		delay(10);
	}
	return -4;   /* no reply */
}

static void
sk_wait(unsigned ms)
{
	uint64_t dl;
	clock_interval_to_deadline(ms, NSEC_PER_MSEC, &dl);
	(void)assert_wait_deadline(&sk_chan, THREAD_UNINT, dl);
	thread_block(THREAD_CONTINUE_NULL);
}

static int sk_use_pwr = 1, sk_use_vol = 1;
/*
 * vol+ and vol- held together for 3 s (power up) = warm reboot to TWRP with the kept lines replayed
 * into pmsg, so an interactive session can end without the 7 s force-off that clears the log.
 * Boot-arg sweetkeyrec=0 off.
 */
static int sk_keyrec = 1;
extern void sweet_reboot_recovery_ext(const char *why);

static void
sk_thread(void *arg, wait_result_t wr)
{
	(void)arg; (void)wr;
	int state[3] = {0, 0, 0}, cand[3] = {0, 0, 0}, cnt[3] = {0, 0, 0};
	unsigned pwr_fail = 0;
	unsigned combo = 0;
	for (;;) {
		int now[3] = {state[0], state[1], state[2]};
		if (sk_use_vol) {
			uint32_t dat = *(volatile uint32_t *)(sk_alive + 4);
			now[1] = !(dat & (1U << 3));
			now[2] = !(dat & (1U << 4));
		}
		if (sk_use_pwr && kq_ok) {
			uint8_t v = 0;
			int r = kq_read(1, 0x0E, &v);
			if (r == 0) {
				now[0] = v & 1U;
				pwr_fail = 0;
			} else {
				kq_err++;
				if (kq_err <= 4 || (kq_err % 500) == 0) {
					sk_log("keys: pmic read err %d (n %u)", r, kq_err);
				}
				if (++pwr_fail >= 50) {
					sk_log("keys: power key off after %u errors", pwr_fail);
					kq_ok = 0;
				}
			}
		}
		for (int k = 0; k < 3; k++) {
			/* two equal samples in a row (30 ms poll) */
			if (now[k] != state[k]) {
				if (cand[k] == now[k]) {
					cnt[k]++;
				} else {
					cand[k] = now[k];
					cnt[k] = 1;
				}
				if (cnt[k] >= 2) {
					state[k] = now[k];
					cnt[k] = 0;
					sk_log("keys: %s %s", k == 0 ? "power" : k == 1 ? "vol+" : "vol-", state[k] ? "down" : "up");
					sweet_hid_key(k, state[k]);
				}
			} else {
				cnt[k] = 0;
				cand[k] = state[k];
			}
		}
		if (sk_keyrec && sk_use_vol && state[1] && state[2] && !state[0]) {
			if (++combo == 100) {
				sk_log("keys: vol+ and vol- held 3 s, reboot to recovery");
				sweet_reboot_recovery_ext("keys vol+ vol-");
			}
		} else {
			combo = 0;
		}
		sk_wait(30);
	}
}

int
sweet_s21keys_start(void)
{
	int on = 1;
	thread_t th;
	if (sk_started) {
		return 0;
	}
	sk_started = 1;
	PE_parse_boot_argn("sweets21keys", &on, sizeof(on));
	PE_parse_boot_argn("sweets21pwr", &sk_use_pwr, sizeof(sk_use_pwr));
	PE_parse_boot_argn("sweetkeyrec", &sk_keyrec, sizeof(sk_keyrec));
	if (!on) {
		sk_log("keys: off (sweets21keys=0)");
		return -1;
	}
	sk_alive = ml_io_map(SK_ALIVE, 0x1000);
	if (!sk_alive) {
		return -1;
	}
	uint32_t con = *(volatile uint32_t *)(sk_alive + 0), dat = *(volatile uint32_t *)(sk_alive + 4);
	uint32_t f3 = (con >> 12) & 0xFU, f4 = (con >> 16) & 0xFU;
	if ((f3 != 0xF && f3 != 0) || (f4 != 0xF && f4 != 0)) {
		sk_use_vol = 0;   /* not the expected gpio_keys pins: never interpret them */
	}
	uint8_t st = 0;
	int r = -9;
	if (sk_use_pwr) {
		kq_ok = kq_init() == 0;
		if (kq_ok) {
			r = kq_read(1, 0x0E, &st);
			if (r) {
				r = kq_read(1, 0x0E, &st);
			}
			if (r) {
				kq_ok = 0;
			}
		}
	}
	sk_log("keys: gpa0 con %08x dat %02x vol %d | acpm ch%u len %u sz %u pwr %d status1 %02x (r %d)",
	    con, dat & 0xFFU, sk_use_vol, SK_CH, kq.len, kq.sz, kq_ok, st, r);
	if (!sk_use_vol && !kq_ok) {
		return -1;
	}
	if (kernel_thread_start(sk_thread, NULL, &th) != KERN_SUCCESS) {
		return -1;
	}
	thread_deallocate(th);
	return 0;
}
#endif /* ARM64_BOARD_CONFIG_SWEET */
EOF_SWEET_SRC

grep -q 'bsd/dev/sweet_s21keys.c' bsd/conf/files || printf 'bsd/dev/sweet_s21keys.c\t\tstandard\n' >> bsd/conf/files
