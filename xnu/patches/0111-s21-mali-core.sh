#!/bin/bash
# S21 Mali-G78 core driver (power, GPU page tables, job submit, self-tests, exported ctx API).
# dxb runs patches/*.sh from the XNU source root before applying *.patch.
set -euo pipefail

[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0
[[ -f bsd/conf/files ]] || exit 1

cat > bsd/dev/sweet_mali.c <<'EOF_SWEET_SRC'
/*
 * S21 (Exynos 2100) Mali-G78 core driver, step A1: power, GPU page tables, job submit.
 * Everything here was measured on the phone first (see the gpu_diag notes in
 * sweet_touch.c): GPU_ID 0x92020010, 14 shader cores, 3 job slots (Job Manager),
 * 8 address spaces, LPAE page-table mode. S-Boot leaves the G3D domain on and the
 * GPU's L2/tiler/shaders off. Polling only (the three GPU IRQ lines stay masked).
 *
 * Boot-args: mali=1 (power on, self-test, leave powered), gpu_scratch=<phys> (RAM that
 * XNU does not manage, mkadt --gpu-scratch), mali_pages=<n> (pool size in 4K pages).
 */
#if defined(ARM64_BOARD_CONFIG_SWEET)
#include <sys/param.h>
#include <sys/systm.h>
#include <kern/clock.h>
#include <mach/mach_time.h>
#include <machine/machine_routines.h>
#include <arm/caches_internal.h>
#include <vm/pmap.h>
#include <vm/vm_kern.h>
#include <libkern/libkern.h>
#include <pexpert/pexpert.h>
#include <stdarg.h>
#include <kern/thread_call.h>
#include <kern/timer_call.h>
#include <libkern/OSAtomic.h>

extern vm_offset_t ml_io_map(vm_offset_t, vm_size_t);
extern ppnum_t pmap_find_phys(pmap_t pmap, addr64_t va);
extern void s21_plog(const char *line);

#define MALI_PHYS        0x18500000U
#define MALI_SIZE        0x5000U
#define R_GPU_ID         0x000U
#define R_AS_PRESENT     0x018U
#define R_JS_PRESENT     0x01CU
#define R_GPU_IRQ_RAW    0x020U
#define R_GPU_IRQ_CLEAR  0x024U
#define R_GPU_IRQ_MASK   0x028U
#define R_GPU_CMD        0x030U
#define R_GPU_STATUS     0x034U
#define R_SHADER_PRESENT 0x100U
#define R_TILER_PRESENT  0x110U
#define R_L2_PRESENT     0x120U
#define R_SHADER_READY   0x140U
#define R_TILER_READY    0x150U
#define R_L2_READY       0x160U
#define R_SHADER_PWRON   0x180U
#define R_TILER_PWRON    0x190U
#define R_L2_PWRON       0x1A0U
#define R_SHADER_PWROFF  0x1C0U
#define R_TILER_PWROFF   0x1D0U
#define R_L2_PWROFF      0x1E0U
#define R_JOB_IRQ_RAW    0x1000U
#define R_JOB_IRQ_CLEAR  0x1004U
#define R_JOB_IRQ_MASK   0x1008U
#define R_MMU_IRQ_RAW    0x2000U
#define R_MMU_IRQ_CLEAR  0x2004U
#define R_MMU_IRQ_MASK   0x2008U
#define R_AS(n, o)       (0x2400U + ((uint32_t)(n) << 6) + (o))
#define R_JS(n, o)       (0x1800U + ((uint32_t)(n) << 7) + (o))

#define GPU_CMD_SOFT_RESET 1U
#define JS_COMMAND_START   1U
#define JS_COMMAND_HARD_STOP 3U
#define AS_COMMAND_UPDATE  1U

/* page entry bits, Mali LPAE: table = pa|3, leaf = pa|1|AF|SH|R|W (leaf type is 1, not 3) */
#define PTE_TABLE   3ULL
#define PTE_LEAF    (1ULL | (1ULL << 6) | (1ULL << 7) | (1ULL << 10) | (3ULL << 8))

struct mali_ctx {
	uint64_t pgd_pa;
	int      as;
};

static struct {
	vm_offset_t reg;
	vm_offset_t pool_va;
	uint64_t    pool_pa;
	uint32_t    pool_pages, pool_next;
	uint32_t    shader_present, tiler_present, l2_present, as_present, js_present, gpu_id;
	int         up, powered;
} mali;

static char mali_keep[24576];
static uint32_t mali_keep_len;
static void mali_log(const char *fmt, ...) __printflike(1, 2);
static void
mali_log(const char *fmt, ...)
{
	char line[192];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	printf("sweet_mali: %s\n", line);
	s21_plog(line);
	/* job failures/timeouts are also kept for the replay before a recovery reboot (sweet_mali_keep_dump) */
	/* ... and the clock settings and present-copy timings, which the 128 KiB ring loses by the end of a run (run164) */
	if (!strncmp(line, "job ", 4) || !strncmp(line, "fault", 5) || !strncmp(line, "recover", 7) ||
	    !strncmp(line, "dvfs", 4) || !strncmp(line, "gpucomp:", 8) || !strncmp(line, "chg:", 4) || !strncmp(line, "keys:", 5) ||
	    !strncmp(line, "crash:", 6)) {
		/* several threads log (governor, charger, keys, exits): reserve the space atomically */
		uint32_t n = (uint32_t)strlen(line);
		uint32_t at = (uint32_t)OSAddAtomic((SInt32)(n + 1), (volatile SInt32 *)&mali_keep_len);
		if (at + n + 1 <= sizeof(mali_keep)) {
			memcpy(mali_keep + at, line, n);
			mali_keep[at + n] = '\n';
		}
	}
}

void sweet_mali_keep_dump(void);
void
sweet_mali_keep_dump(void)
{
	char ln[192];
	uint32_t i = 0, end = mali_keep_len < sizeof(mali_keep) ? mali_keep_len : (uint32_t)sizeof(mali_keep);
	while (i < end) {
		uint32_t n = 0;
		while (i < end && mali_keep[i] != '\n' && n < sizeof(ln) - 4) {
			ln[n++] = mali_keep[i++];
		}
		ln[n] = 0;
		i++;
		if (n) {
			s21_plog(ln);
		}
	}
}

static inline uint32_t
rd(uint32_t off)
{
	return *(volatile uint32_t *)(mali.reg + off);
}

static inline void
wr(uint32_t off, uint32_t v)
{
	*(volatile uint32_t *)(mali.reg + off) = v;
}

static void
us(uint32_t n)
{
	delay_for_interval(n, NSEC_PER_USEC);
}

/* wait until (reg & mask) == want, in ms; returns elapsed ms or 0xFFFFFFFF on timeout */
/* spin on a register for up to spin_us without sleeping (a 1 ms delay_for_interval blocks the thread and wakes
 * late: several ms lost per job, run109); true when (reg & mask) == want */
static bool
spin_reg(uint32_t off, uint32_t mask, uint32_t want, uint32_t spin_us)
{
	uint64_t end, now = mach_absolute_time();
	nanoseconds_to_absolutetime((uint64_t)spin_us * 1000ULL, &end);
	end += now;
	do {
		if ((rd(off) & mask) == want) {
			return true;
		}
		now = mach_absolute_time();
	} while (now < end);
	return (rd(off) & mask) == want;
}

static uint32_t
wait_reg(uint32_t off, uint32_t mask, uint32_t want, uint32_t ms)
{
	if (spin_reg(off, mask, want, 500)) {
		return 0;
	}
	for (uint32_t t = 0; t < ms; t++) {
		if ((rd(off) & mask) == want) {
			return t;
		}
		us(1000);
	}
	return (rd(off) & mask) == want ? ms : 0xFFFFFFFFU;
}

/* ---- RAM pool: page tables and GPU buffers come from the unmanaged scratch window ---- */
/* freed page-table pages (a context's tables go back when it is destroyed: AegirPoster restarts used to leak them
 * until the 2 MiB pool was empty and every later GPU allocation failed, run155/156) */
static uint32_t pool_free_idx[1024], pool_nfree;
static uint64_t
pool_alloc(void)
{
	uint32_t i;
	if (pool_nfree) {
		i = pool_free_idx[--pool_nfree];
	} else if (mali.pool_next < mali.pool_pages) {
		i = mali.pool_next++;
	} else {
		return 0;
	}
	volatile uint32_t *p = (volatile uint32_t *)(mali.pool_va + ((vm_offset_t)i << 12));
	for (uint32_t k = 0; k < 1024; k++) {
		p[k] = 0;
	}
	return mali.pool_pa + ((uint64_t)i << 12);
}

static void
pool_free_pa(uint64_t pa)
{
	if (pa < mali.pool_pa || pa >= mali.pool_pa + ((uint64_t)mali.pool_pages << 12) || pool_nfree >= 1024) {
		return;
	}
	pool_free_idx[pool_nfree++] = (uint32_t)((pa - mali.pool_pa) >> 12);
}

static volatile uint32_t *
pa2va(uint64_t pa)
{
	return (volatile uint32_t *)(mali.pool_va + (vm_offset_t)(pa - mali.pool_pa));
}

/* ---- GPU contexts: one 4-level LPAE page table per address space ---- */
static int
ctx_init(struct mali_ctx *c, int as)
{
	c->as = as;
	c->pgd_pa = pool_alloc();
	return c->pgd_pa ? 0 : -1;
}

static uint64_t
tbl_next(uint64_t table_pa, uint32_t idx)
{
	volatile uint32_t *t = pa2va(table_pa);
	uint64_t e = (uint64_t)t[idx * 2] | ((uint64_t)t[idx * 2 + 1] << 32);
	if (e & 1ULL) {
		return e & 0x0000FFFFFFFFF000ULL;
	}
	uint64_t n = pool_alloc();
	if (!n) {
		return 0;
	}
	e = n | PTE_TABLE;
	t[idx * 2] = (uint32_t)e;
	t[idx * 2 + 1] = (uint32_t)(e >> 32);
	return n;
}

/* map one 4 KiB page: va (48 bit) -> pa, read+write */
static int
ctx_map(struct mali_ctx *c, uint64_t va, uint64_t pa)
{
	uint64_t t1 = tbl_next(c->pgd_pa, (uint32_t)((va >> 39) & 0x1FF));
	uint64_t t2 = t1 ? tbl_next(t1, (uint32_t)((va >> 30) & 0x1FF)) : 0;
	uint64_t t3 = t2 ? tbl_next(t2, (uint32_t)((va >> 21) & 0x1FF)) : 0;
	if (!t3) {
		return -1;
	}
	uint32_t idx = (uint32_t)((va >> 12) & 0x1FF);
	volatile uint32_t *t = pa2va(t3);
	uint64_t e = (pa & 0x0000FFFFFFFFF000ULL) | PTE_LEAF;
	t[idx * 2] = (uint32_t)e;
	t[idx * 2 + 1] = (uint32_t)(e >> 32);
	return 0;
}

static void
ctx_activate(struct mali_ctx *c)
{
	uint32_t as = (uint32_t)c->as;
	__asm__ volatile ("dsb sy" ::: "memory");
	wait_reg(R_AS(as, 0x28), 1U, 0U, 10);
	wr(R_AS(as, 0x00), (uint32_t)(c->pgd_pa | 3ULL | (1ULL << 2)));
	wr(R_AS(as, 0x04), (uint32_t)(c->pgd_pa >> 32));
	wr(R_AS(as, 0x08), 0x8D88U);
	wr(R_AS(as, 0x0C), 0x8D88U);
	wr(R_AS(as, 0x18), AS_COMMAND_UPDATE);
	wait_reg(R_AS(as, 0x28), 1U, 0U, 10);
}

static void
as_flush(uint32_t as)
{
	wait_reg(R_AS(as, 0x28), 1U, 0U, 10);
	wr(R_AS(as, 0x10), 46U);                  /* LOCKADDR: base 0, region width 2^47 */
	wr(R_AS(as, 0x14), 0U);
	wr(R_AS(as, 0x18), 2U);                   /* AS_COMMAND_LOCK */
	wait_reg(R_AS(as, 0x28), 1U, 0U, 10);
	wr(R_AS(as, 0x18), 5U);                   /* AS_COMMAND_FLUSH_MEM */
	wait_reg(R_AS(as, 0x28), 1U, 0U, 10);
	wr(R_AS(as, 0x18), 3U);                   /* AS_COMMAND_UNLOCK */
	wait_reg(R_AS(as, 0x28), 1U, 0U, 10);
}

static void
ctx_deactivate(struct mali_ctx *c)
{
	uint32_t as = (uint32_t)c->as;
	wr(R_AS(as, 0x00), 0);
	wr(R_AS(as, 0x04), 0);
	wr(R_AS(as, 0x18), AS_COMMAND_UPDATE);
	wait_reg(R_AS(as, 0x28), 1U, 0U, 10);
}

/* ---- power ---- */
static int
power_block(uint32_t onreg, uint32_t rdyreg, uint32_t mask, int on, const char *name)
{
	if (on) {
		wr(onreg, mask);
	} else {
		wr(onreg + 0x40U, mask);              /* PWROFF registers are PWRON + 0x40 */
	}
	uint32_t t = wait_reg(rdyreg, mask, on ? mask : 0U, 200);
	if (t == 0xFFFFFFFFU) {
		mali_log("%s %s timed out (ready=%x)", name, on ? "on" : "off", rd(rdyreg));
		return -1;
	}
	return 0;
}

static int
mali_power(int on)
{
	int r = 0;
	if (on == mali.powered) {
		return 0;
	}
	if (on) {
		wr(R_GPU_IRQ_CLEAR, 0xFFFFFFFFU);
		r |= power_block(R_L2_PWRON, R_L2_READY, mali.l2_present, 1, "l2");
		r |= power_block(R_TILER_PWRON, R_TILER_READY, mali.tiler_present, 1, "tiler");
		r |= power_block(R_SHADER_PWRON, R_SHADER_READY, mali.shader_present, 1, "shader");
	} else {
		r |= power_block(R_SHADER_PWRON, R_SHADER_READY, mali.shader_present, 0, "shader");
		r |= power_block(R_TILER_PWRON, R_TILER_READY, mali.tiler_present, 0, "tiler");
		r |= power_block(R_L2_PWRON, R_L2_READY, mali.l2_present, 0, "l2");
	}
	mali.powered = r ? mali.powered : on;
	return r;
}

/* ---- recovery: a faulted job leaves the job manager wedged (every later job reports 0x5b), so soft-reset
 * the GPU and power it back up; the next submit re-programs the address space ---- */
static int sweet_mali_one_core;   /* boot-arg mali_onecore=1: old single-core affinity */
static void mali_as_invalidate_all(void);
static uint32_t mali_faults;     /* after MALI_MAX_FAULTS faults/timeouts the GPU is fenced off until reboot */
#define MALI_MAX_FAULTS 12

static void
mali_recover(const char *why)
{
	mali_as_invalidate_all();
	if (++mali_faults >= MALI_MAX_FAULTS) {
		mali_log("fault %u (%s): GPU fenced off until reboot", mali_faults, why);
		return;
	}
	wr(R_GPU_IRQ_CLEAR, 0xFFFFFFFFU);
	wr(R_GPU_CMD, GPU_CMD_SOFT_RESET);
	uint32_t t = wait_reg(R_GPU_IRQ_RAW, 0x100U, 0x100U, 100);
	wr(R_GPU_IRQ_CLEAR, 0xFFFFFFFFU);
	wr(R_GPU_IRQ_MASK, 0);
	wr(R_JOB_IRQ_MASK, 0);
	wr(R_MMU_IRQ_MASK, 0);
	wr(R_JOB_IRQ_CLEAR, 0xFFFFFFFFU);
	wr(R_MMU_IRQ_CLEAR, 0xFFFFFFFFU);
	mali.powered = 0;
	int p = mali_power(1);
	mali_log("recover after %s: reset %s, power %s", why, t == 0xFFFFFFFFU ? "timed out" : "ok", p ? "failed" : "ok");
}

int sweet_s21keys_start(void);
int sweet_s21_battery_start(void);
static inline void gov_job(void);   /* idle clock governor, below mali_dvfs() */

/* ---- job submission (polling) ---- */
/* returns 0 on DONE, else the JS_STATUS exception code (or 0xFFFF on timeout) */
static uint32_t
mali_submit_wait(struct mali_ctx *c, uint32_t slot, uint64_t jc_va, uint32_t timeout_ms)
{
	uint32_t done = 1U << slot, fail = 1U << (slot + 16), raw = 0, t;
	gov_job();
	wr(R_JOB_IRQ_CLEAR, 0xFFFFFFFFU);
	wr(R_MMU_IRQ_CLEAR, 0xFFFFFFFFU);
	wr(R_JS(slot, 0x40), (uint32_t)jc_va);
	wr(R_JS(slot, 0x44), (uint32_t)(jc_va >> 32));
	/* all shader cores: one core took > 2 s on a full-screen poster pass with eight textures (run70 timeout) */
	wr(R_JS(slot, 0x50), sweet_mali_one_core ? (mali.shader_present & (~mali.shader_present + 1U)) : mali.shader_present);
	wr(R_JS(slot, 0x54), 0);
	wr(R_JS(slot, 0x58), ((uint32_t)c->as) | (3U << 8) | (1U << 10) | (3U << 12) | (8U << 16));
	wr(R_JS(slot, 0x60), JS_COMMAND_START);
	{
		/* spin up to 30 ms first: most jobs finish well within that */
		uint64_t end, now = mach_absolute_time();
		nanoseconds_to_absolutetime(30ULL * 1000000ULL, &end);
		end += now;
		do {
			raw = rd(R_JOB_IRQ_RAW);
			if (raw & (done | fail)) {
				break;
			}
			now = mach_absolute_time();
		} while (now < end);
	}
	for (t = 0; t < timeout_ms && !(raw & (done | fail)); t++) {
		raw = rd(R_JOB_IRQ_RAW);
		if (raw & (done | fail)) {
			break;
		}
		us(1000);
	}
	if (!(raw & (done | fail))) {
		uint32_t as = (uint32_t)c->as;
		mali_log("job timeout slot %u js=%x mmu=%x fault=%x addr=%x%08x", slot, rd(R_JS(slot, 0x24)), rd(R_MMU_IRQ_RAW),
		    rd(R_AS(as, 0x1C)), rd(R_AS(as, 0x24)), rd(R_AS(as, 0x20)));
		wr(R_JS(slot, 0x60), JS_COMMAND_HARD_STOP);
		us(20000);
		wr(R_JOB_IRQ_CLEAR, 0xFFFFFFFFU);
		mali_recover("timeout");
		return 0xFFFFU;
	}
	uint32_t js = rd(R_JS(slot, 0x24));
	wr(R_JOB_IRQ_CLEAR, 0xFFFFFFFFU);
	if (raw & fail) {
		uint32_t as = (uint32_t)c->as;
		mali_log("job failed slot %u js=%x mmu=%x fault=%x/%x", slot, js, rd(R_MMU_IRQ_RAW), rd(R_AS(as, 0x1C)), rd(R_AS(as, 0x20)));
		wr(R_MMU_IRQ_CLEAR, 0xFFFFFFFFU);
		mali_recover("fault");
		return js ? js : 0xFFFEU;
	}
	return 0;
}

/* ---- self-test: one WRITE_VALUE job through our own tables, must write 0xC0FFEE01 ---- */
static int
mali_selftest(void)
{
	struct mali_ctx c;
	const uint64_t VA_JOB = 0x10000000ULL, VA_OUT = 0x10001000ULL;
	uint64_t job_pa, out_pa;
	if (ctx_init(&c, 0)) {
		mali_log("selftest: pool empty (ctx)");
		return -1;
	}
	job_pa = pool_alloc();
	out_pa = pool_alloc();
	if (!job_pa || !out_pa || ctx_map(&c, VA_JOB, job_pa) || ctx_map(&c, VA_OUT, out_pa)) {
		mali_log("selftest: pool empty (map)");
		return -1;
	}
	volatile uint32_t *j = pa2va(job_pa), *o = pa2va(out_pa);
	j[4] = (2U << 1) | 1U;                 /* byte 16: 64-bit descriptor, type WRITE_VALUE */
	j[8] = (uint32_t)VA_OUT;               /* payload: address */
	j[9] = (uint32_t)(VA_OUT >> 32);
	j[10] = 6U;                            /* immediate 32 */
	j[12] = 0xC0FFEE01U;
	o[0] = 0xDEADBEEFU;
	ctx_activate(&c);
	uint32_t r = mali_submit_wait(&c, 1, VA_JOB, 100);
	__asm__ volatile ("dsb sy" ::: "memory");
	mali_log("selftest: status=%x out=%08x exc=%x%s", r, o[0], j[0], o[0] == 0xC0FFEE01U ? " OK THE GPU WROTE IT" : " FAIL");
	ctx_deactivate(&c);
	return o[0] == 0xC0FFEE01U ? 0 : -1;
}

/* ---- self-test 2: the GPU reads/writes ordinary kernel RAM (cacheable heap, not the scratch window) ---- */
static int
mali_selftest_heap(void)
{
	struct mali_ctx c;
	const uint64_t VA_JOB = 0x20000000ULL, VA_OUT = 0x20001000ULL;
	vm_offset_t buf = 0;
	if (kmem_alloc_contig(kernel_map, &buf, 2 * PAGE_SIZE, PAGE_MASK, 0, 0,
	    KMA_DATA | KMA_ZERO | KMA_PERMANENT, VM_KERN_MEMORY_IOKIT) != KERN_SUCCESS) {
		mali_log("heap test: kmem_alloc_contig failed");
		return -1;
	}
	ppnum_t pn = pmap_find_phys(kernel_pmap, (addr64_t)buf);
	if (!pn) {
		mali_log("heap test: no physical page");
		return -1;
	}
	uint64_t pa = ptoa_64(pn);
	volatile uint32_t *j = (volatile uint32_t *)buf;
	volatile uint32_t *o = (volatile uint32_t *)(buf + PAGE_SIZE);
	if (ctx_init(&c, 0) || ctx_map(&c, VA_JOB, pa) || ctx_map(&c, VA_OUT, pa + PAGE_SIZE)) {
		mali_log("heap test: pool empty");
		return -1;
	}
	j[4] = (2U << 1) | 1U;
	j[8] = (uint32_t)VA_OUT;
	j[9] = (uint32_t)(VA_OUT >> 32);
	j[10] = 6U;
	j[12] = 0xC0FFEE02U;
	o[0] = 0xDEADBEEFU;
	flush_dcache64((addr64_t)pa, 2 * PAGE_SIZE, TRUE);   /* clean+invalidate: the GPU is not coherent */
	ctx_activate(&c);
	uint32_t r = mali_submit_wait(&c, 1, VA_JOB, 100);
	flush_dcache64((addr64_t)pa, 2 * PAGE_SIZE, TRUE);
	__asm__ volatile ("dsb sy" ::: "memory");
	mali_log("heap test: pa=%llx status=%x out=%08x exc=%x%s", pa, r, o[0], j[0],
	    o[0] == 0xC0FFEE02U ? " OK THE GPU WROTE KERNEL RAM" : " FAIL");
	ctx_deactivate(&c);
	return o[0] == 0xC0FFEE02U ? 0 : -1;
}

/* ---- ACPM DVFS: CPU/GPU clocks. S-Boot leaves the GPU at its DVFS start clock (221 MHz, DT gpu_dvfs_start_clock)
 * and nothing in XNU ever raised a clock. Protocol = Samsung acpm_dvfs (also mainline exynos-acpm-dvfs.c): 4 words
 * { domain id | seq << 16, rate kHz, 0 = FREQ_REQ / 1 = FREQ_GET, 0 } on the acpm_dvfs IPC channel (5 in the
 * SM-G991N DT); domain ids = cal_id & 0xFFF (dm_domains: MIF 0, INT 1, CL0 2, CL1 3, CL2 4, DSU 6, G3D 11).
 * Boot-args (kHz): sweetdvfs=0 off, sweetg3d, sweetcl0, sweetcl1, sweetcl2, sweetdsu, sweetmif (0 = leave). ---- */
#define ACD_SRAM      0x02039000U
#define ACD_SRAM_SIZE 0x41000U
#define ACD_INIT      0x8000U
#define ACD_MBOX      0x15900000U
#define ACD_CH        5U
static vm_offset_t acd_sram, acd_mbox;
static uint32_t acd_seq;
static int acd_state;   /* 0 = not tried, 1 = ok, -1 = unusable */
static struct { uint32_t txr, txf, txb, rxr, rxf, rxb, len, sz, type, fld; } acd;
static int acd_buf_ok;   /* boot-arg sweetdvfsbuf=1: talk to a buffer-type (type 2) channel */
#define ACD(o) (*(volatile uint32_t *)(acd_sram + (o)))

static int
acd_init(void)
{
	if (acd_state) {
		return acd_state > 0 ? 0 : -1;
	}
	acd_state = -1;
	acd_sram = ml_io_map(ACD_SRAM, ACD_SRAM_SIZE);
	acd_mbox = ml_io_map(ACD_MBOX, 0x1000);
	if (!acd_sram || !acd_mbox) {
		mali_log("dvfs: map failed");
		return -1;
	}
	uint32_t chans = ACD(ACD_INIT + 8), apmax = ACD(ACD_INIT + 24);
	if (chans == 0 || chans >= ACD_SRAM_SIZE || apmax == 0 || apmax > 32) {
		mali_log("dvfs: bad initdata chans=%x apmax=%u", chans, apmax);
		return -1;
	}
	/* channel table dump (run165: the id-5 entry read q_len 1, which no sender can use) */
	mali_log("dvfs: initdata chans=%x nch=%u apmax=%u", chans, ACD(ACD_INIT + 12), apmax);
	for (uint32_t i = 0; i < apmax && i < 16; i++) {
		uint32_t e = chans + i * 72U;
		if (e + 72U > ACD_SRAM_SIZE) {
			break;
		}
		mali_log("dvfs: ch[%u] id %u fld %u own %d ty %u rx %x/%x/%x ib %x/%x/%x tx %x/%x/%x q %u/%u cr %u mb %x poll %u",
		    i, ACD(e), ACD(e + 4), (int)ACD(e + 8), ACD(e + 12), ACD(e + 16), ACD(e + 20), ACD(e + 24), ACD(e + 28), ACD(e + 32),
		    ACD(e + 36), ACD(e + 40), ACD(e + 44), ACD(e + 48), ACD(e + 52), ACD(e + 56), ACD(e + 60), ACD(e + 64), ACD(e + 68));
	}
	for (uint32_t i = 0; i < apmax; i++) {
		uint32_t e = chans + i * 72U;
		if (e + 72U > ACD_SRAM_SIZE) {
			break;
		}
		if (ACD(e) != ACD_CH) {
			continue;
		}
		acd.txr = ACD(e + 16); acd.txf = ACD(e + 20); acd.txb = ACD(e + 24);
		acd.rxr = ACD(e + 40); acd.rxf = ACD(e + 44); acd.rxb = ACD(e + 48);
		acd.len = ACD(e + 52); acd.sz = ACD(e + 56); acd.type = ACD(e + 12); acd.fld = ACD(e + 4);
		PE_parse_boot_argn("sweetdvfsbuf", &acd_buf_ok, sizeof(acd_buf_ok));
		if (acd.len == 0 || acd.len > 64 || acd.sz < 16 || acd.sz > 64 || acd.txb >= ACD_SRAM_SIZE || acd.rxb >= ACD_SRAM_SIZE ||
		    acd.txf >= ACD_SRAM_SIZE || acd.rxf >= ACD_SRAM_SIZE || acd.txr >= ACD_SRAM_SIZE || acd.rxr >= ACD_SRAM_SIZE) {
			mali_log("dvfs: ch%u bad queue len=%u sz=%u", ACD_CH, acd.len, acd.sz);
			return -1;
		}
		acd_state = 1;
		mali_log("dvfs: ch%u len=%u sz=%u type=%u fld=%x", ACD_CH, acd.len, acd.sz, acd.type, acd.fld);
		return 0;
	}
	mali_log("dvfs: ch%u not found", ACD_CH);
	return -1;
}

/* one request; returns the reply's word 1 or -1 (no reply within ~wait_ms) */
static int64_t
acd_xfer(uint32_t id, uint32_t w1, uint32_t type, uint32_t wait_ms)
{
	if (acd_init()) {
		return -1;
	}
	if (++acd_seq >= 64) {
		acd_seq = 1;
	}
	uint32_t cmd[4] = { (id & 0xFFFU) | ((acd_seq & 0x3FU) << 16), w1, type, 0 };
	if (acd.type == 2) {
		/* run167 table dump: the acpm_dvfs channel is TYPE_BUFFER (q_len 1, no usable front/rear ring): one command
		 * buffer at the AP-TX base, doorbell, the reply lands in the AP-RX buffer with the mailbox INTSR1 bit set */
		if (!acd_buf_ok) {
			static int nl;
			if (nl++ < 1) {
				mali_log("dvfs: ch%u is a buffer channel (type 2), boot-arg sweetdvfsbuf=1 to use it", ACD_CH);
			}
			return -1;
		}
		uint32_t bit = acd.fld ? acd.fld : (1U << ACD_CH);
		*(volatile uint32_t *)(acd_mbox + 0x20) = bit;              /* INTCR1: drop a stale reply flag */
		for (uint32_t w = 0; w < acd.sz / 4; w++) {
			ACD(acd.txb + w * 4) = w < 4 ? cmd[w] : 0;
		}
		__asm__ volatile ("dsb sy" ::: "memory");
		*(volatile uint32_t *)(acd_mbox + 0x08) = bit << 16;        /* INTGR0 doorbell */
		for (uint32_t t = 0; t < wait_ms * 10; t++) {
			if (*(volatile uint32_t *)(acd_mbox + 0x28) & bit) {     /* INTSR1 */
				uint32_t r0 = ACD(acd.rxb), r1 = ACD(acd.rxb + 4);
				*(volatile uint32_t *)(acd_mbox + 0x20) = bit;
				static int nl;
				if (nl++ < 4) {
					mali_log("dvfs: buf reply %08x %08x after %u00us", r0, r1, t);
				}
				return (int64_t)r1;
			}
			us(100);
		}
		{
			static int nl;
			if (nl++ < 4) {
				mali_log("dvfs: buf no reply (rx %08x %08x sr1 %x)", ACD(acd.rxb), ACD(acd.rxb + 4),
				    *(volatile uint32_t *)(acd_mbox + 0x28));
			}
		}
		return -1;
	}
	uint32_t front = ACD(acd.txf);
	if (front >= acd.len) {
		mali_log("dvfs: bad tx front %u", front);
		return -1;
	}
	uint32_t next = (front + 1) % acd.len;
	for (int t = 0; t < 200 && next == ACD(acd.txr); t++) {
		us(100);
	}
	if (next == ACD(acd.txr)) {
		mali_log("dvfs: tx full");
		return -1;
	}
	for (uint32_t w = 0; w < acd.sz / 4; w++) {
		ACD(acd.txb + acd.sz * front + w * 4) = w < 4 ? cmd[w] : 0;
	}
	__asm__ volatile ("dsb sy" ::: "memory");
	ACD(acd.txf) = next;
	__asm__ volatile ("dsb sy" ::: "memory");
	*(volatile uint32_t *)(acd_mbox + 0x08) = (1U << ACD_CH) << 16;   /* INTGR0 */
	for (uint32_t t = 0; t < wait_ms * 10; t++) {
		uint32_t f = ACD(acd.rxf), i = ACD(acd.rxr);
		while (i != f && i < acd.len) {
			uint32_t e = acd.rxb + acd.sz * i;
			if (((ACD(e) >> 16) & 0x3FU) == (acd_seq & 0x3FU)) {
				uint32_t r1 = ACD(e + 4);
				ACD(acd.rxr) = (i + 1) % acd.len;
				*(volatile uint32_t *)(acd_mbox + 0x20) = 1U << ACD_CH;   /* INTCR1 */
				return (int64_t)r1;
			}
			i = (i + 1) % acd.len;
		}
		us(100);
	}
	return -1;
}

/* GPU clock from its cycle counter against the system timer */
static uint32_t
mali_measure_mhz(void)
{
	wr(R_GPU_CMD, 0x05U);   /* CYCLE_COUNT_START */
	us(50);
	uint64_t c0 = rd(0x090U) | ((uint64_t)rd(0x094U) << 32), t0 = mach_absolute_time();
	us(2000);
	uint64_t c1 = rd(0x090U) | ((uint64_t)rd(0x094U) << 32), t1 = mach_absolute_time(), ns;
	wr(R_GPU_CMD, 0x06U);   /* CYCLE_COUNT_STOP */
	absolutetime_to_nanoseconds(t1 - t0, &ns);
	return ns ? (uint32_t)((c1 - c0) * 1000ULL / ns) : 0;
}

/* boot CPU clock: a chain of dependent adds runs at one per cycle on A55/A78/X1 */
static uint32_t
cpu_measure_mhz(void)
{
	uint64_t x = 0, t0 = mach_absolute_time(), ns;
	for (int i = 0; i < 200000; i++) {
		__asm__ volatile ("add %0,%0,#1\n add %0,%0,#1\n add %0,%0,#1\n add %0,%0,#1\n add %0,%0,#1\n add %0,%0,#1\n add %0,%0,#1\n add %0,%0,#1\n"
		                  "add %0,%0,#1\n add %0,%0,#1\n add %0,%0,#1\n add %0,%0,#1\n add %0,%0,#1\n add %0,%0,#1\n add %0,%0,#1\n add %0,%0,#1" : "+r"(x));
	}
	absolutetime_to_nanoseconds(mach_absolute_time() - t0, &ns);
	return ns ? (uint32_t)(x * 1000ULL / ns) : 0;
}

/*
 * Clock domains on ACPM channel 5. "hi" = the level used while the UI draws (boot-args sweetdsu/cl0/cl1/cl2/g3d
 * override it), "lo" = the idle level of the governor below (sweetg3dlo/cl0lo/cl1lo/cl2lo; 0 = leave as is).
 * All values are entries of the DT freq tables (exynos-acme domain@0..2, gpu_dvfs_table).
 */
static const struct dvfs_dom { const char *name, *arg, *arglo; uint32_t id, def, lo; } D[] = {
	{ "mif", "sweetmif", "sweetmiflo", 0, 0, 0 },          /* S-Boot runs MIF at its boot level (3172 MHz) */
	{ "dsu", "sweetdsu", "sweetdsulo", 6, 1586000, 0 },    /* DT dm-table: CL2 2288 MHz needs DSU >= 1586 MHz */
	{ "cl0", "sweetcl0", "sweetcl0lo", 2, 1794000, 1066000 },
	{ "cl1", "sweetcl1", "sweetcl1lo", 3, 2080000, 1040000 },
	{ "cl2", "sweetcl2", "sweetcl2lo", 4, 2288000, 1040000 },
	{ "g3d", "sweetg3d", "sweetg3dlo", 11, 676000, 130000 },
	{ "int", "sweetint", "sweetintlo", 1, 0, 0 },
};
#define DVFS_N (sizeof(D) / sizeof(D[0]))
static uint32_t dvfs_hi[DVFS_N], dvfs_lo[DVFS_N];
static int dvfs_ok;

static void
mali_dvfs(int gpu_ready)
{
	int on = 1;
	PE_parse_boot_argn("sweetdvfs", &on, sizeof(on));
	char ln[192]; int L = 0;
	uint32_t g0 = gpu_ready ? mali_measure_mhz() : 0, c0 = cpu_measure_mhz();
	for (unsigned i = 0; i < DVFS_N; i++) {
		dvfs_hi[i] = D[i].def;
		PE_parse_boot_argn(D[i].arg, &dvfs_hi[i], sizeof(dvfs_hi[i]));
		dvfs_lo[i] = D[i].lo;
		PE_parse_boot_argn(D[i].arglo, &dvfs_lo[i], sizeof(dvfs_lo[i]));
		int64_t cur = acd_xfer(D[i].id, 0, 1, 20);
		L += snprintf(ln + L, sizeof(ln) - L, " %s %lld", D[i].name, cur);
		if (acd_state < 0) {
			break;
		}
	}
	mali_log("dvfs before (kHz):%s gpu %u MHz cpu %u MHz", ln, g0, c0);
	if (!on || acd_state < 0) {
		return;
	}
	L = 0;
	for (unsigned i = 0; i < DVFS_N; i++) {
		uint32_t f = dvfs_hi[i];
		if (!f) {
			continue;
		}
		int64_t r = acd_xfer(D[i].id, f, 0, 20);
		us(1000);
		int64_t now = acd_xfer(D[i].id, 0, 1, 20);
		L += snprintf(ln + L, sizeof(ln) - L, " %s %u->%lld(%lld)", D[i].name, f, now, r);
	}
	uint32_t g1 = gpu_ready ? mali_measure_mhz() : 0, c1 = cpu_measure_mhz();
	mali_log("dvfs set:%s gpu %u MHz cpu %u MHz", ln, g1, c1);
	dvfs_ok = 1;
}

/*
 * Idle governor (boot-arg sweetgov=0 disables): the clocks stay at "hi" while GPU jobs arrive. The GPU drops to
 * its "lo" level after sweetgov_gpu_ms (1000) without a job, the CPU clusters after sweetgov_cpu_ms (8000) and
 * only once uptime passed sweetgov_cpu_after s (480, the boot is CPU-bound behind a static logo). The first job
 * after idle wakes the governor thread, which restores "hi" (the submitter never waits for ACPM).
 * Raising goes DSU first, lowering goes CPU first (dm-table constraint CL -> DSU).
 */
static int gov_on = 1;
static uint32_t gov_gpu_ms = 1000, gov_cpu_ms = 8000, gov_cpu_after = 480;
static volatile uint64_t gov_last_job;
static volatile int gov_gpu_lo, gov_cpu_lo;
static volatile UInt32 gov_busy, gov_pending;
static thread_call_t gov_tc;

/*
 * Thermal cap (set by the MAX77705 battery-temperature policy, 0123): while on, the governor keeps the CPU and GPU at
 * their "lo" levels whatever the load. iOS had no thermal management at all: a hung test run (run181) heated the
 * phone to ~71 C on full clocks.
 */
static volatile int sweet_thermal_cap;
void sweet_thermal_set(int cap);
void
sweet_thermal_set(int cap)
{
	if (sweet_thermal_cap == cap) {
		return;
	}
	sweet_thermal_cap = cap;
	mali_log("dvfs thermal: clocks %s", cap ? "capped low" : "released");
	if (gov_tc) {
		thread_call_enter(gov_tc);
	}
}

/*
 * Software watchdog + hard reset (boot-arg sweetswdog=<s>, default 90; 0 off). A thread call stamps a heartbeat every
 * 2 s; a timer call (interrupt context, no locks) checks it every 5 s and, if no heartbeat came for that long (threads
 * starved or deadlocked, as in run181 where even the autorec thread call never ran), writes the recovery reset reason
 * and resets the SoC straight into TWRP. sweet_hard_reset_at(s) arms the same reset unconditionally (autorec backstop).
 * A hang with interrupts off on every core is not covered (the hardware watchdog clock is gated, run41).
 */
static volatile uint32_t *swd_pmu;
static timer_call_data_t swd_tc, swd_hard_tc;
static thread_call_t swd_hb_tc;
static volatile uint64_t swd_beat;
static uint64_t swd_limit_abs, swd_check_abs, swd_hb_abs;

static void
swd_reset_now(void)
{
	volatile uint32_t *r = swd_pmu;
	if (r == NULL) {
		return;
	}
	r[0x808 / 4] = (r[0x808 / 4] & ~0x00FF0000U) | 0x004E0000U;   /* normal reboot magic */
	r[0x80c / 4] = 0x12345604U;                                  /* reset reason: recovery */
	r[0x810 / 4] = 0xFFU;
	__asm__ volatile ("dsb sy" ::: "memory");
	r[0x3c00 / 4] = 0x2U;                                        /* SWRESET */
	__asm__ volatile ("dsb sy" ::: "memory");
	for (;;) {
		__asm__ volatile ("wfe");
	}
}

static void
swd_hb(__unused thread_call_param_t p0, __unused thread_call_param_t p1)
{
	uint64_t now = mach_absolute_time();
	swd_beat = now;
	thread_call_enter_delayed(swd_hb_tc, now + swd_hb_abs);
}

static void
swd_check(__unused timer_call_param_t p0, __unused timer_call_param_t p1)
{
	uint64_t now = mach_absolute_time();
	if (swd_beat && now > swd_beat && now - swd_beat > swd_limit_abs) {
		swd_reset_now();
	}
	timer_call_enter(&swd_tc, now + swd_check_abs, TIMER_CALL_SYS_CRITICAL);
}

static void
swd_hard(__unused timer_call_param_t p0, __unused timer_call_param_t p1)
{
	swd_reset_now();
}

static int
swd_map(void)
{
	if (swd_pmu == NULL) {
		swd_pmu = (volatile uint32_t *)ml_io_map(0x15860000U, 0x4000);
	}
	return swd_pmu != NULL;
}

static void
swd_start(void)
{
	uint32_t secs = 90;
	PE_parse_boot_argn("sweetswdog", &secs, sizeof(secs));
	if (!secs || !swd_map()) {
		mali_log("dvfs swdog: off");
		return;
	}
	nanoseconds_to_absolutetime((uint64_t)secs * NSEC_PER_SEC, &swd_limit_abs);
	nanoseconds_to_absolutetime(5ULL * NSEC_PER_SEC, &swd_check_abs);
	nanoseconds_to_absolutetime(2ULL * NSEC_PER_SEC, &swd_hb_abs);
	swd_hb_tc = thread_call_allocate_with_priority(swd_hb, NULL, THREAD_CALL_PRIORITY_HIGH);
	if (swd_hb_tc == NULL) {
		return;
	}
	swd_beat = mach_absolute_time();
	thread_call_enter(swd_hb_tc);
	timer_call_setup(&swd_tc, swd_check, NULL);
	timer_call_enter(&swd_tc, mach_absolute_time() + swd_check_abs, TIMER_CALL_SYS_CRITICAL);
	mali_log("dvfs swdog: on, reset to recovery after %u s without a heartbeat", secs);
}

void sweet_hard_reset_at(uint32_t secs);
void
sweet_hard_reset_at(uint32_t secs)
{
	uint64_t d = 0;
	if (!secs || !swd_map()) {
		return;
	}
	nanoseconds_to_absolutetime((uint64_t)secs * NSEC_PER_SEC, &d);
	timer_call_setup(&swd_hard_tc, swd_hard, NULL);
	timer_call_enter(&swd_hard_tc, mach_absolute_time() + d, TIMER_CALL_SYS_CRITICAL);
	mali_log("dvfs swdog: hard reset backstop in %u s", secs);
}
static uint32_t gov_switches;

static void
gov_set(int gpu, int lo)
{
	for (unsigned k = 0; k < DVFS_N; k++) {
		unsigned i = lo ? (unsigned)(DVFS_N - 1 - k) : k;
		int is_gpu = D[i].id == 11;
		if (is_gpu != gpu || !dvfs_lo[i] || !dvfs_hi[i]) {
			continue;
		}
		(void)acd_xfer(D[i].id, lo ? dvfs_lo[i] : dvfs_hi[i], 0, 20);
	}
}

static void
gov_run(__unused thread_call_param_t p0, __unused thread_call_param_t p1)
{
	if (!OSCompareAndSwap(0, 1, &gov_busy)) {
		uint64_t dl;   /* another run is active: retry shortly so a pending wake-up is never lost */
		clock_interval_to_deadline(5, NSEC_PER_MSEC, &dl);
		thread_call_enter_delayed(gov_tc, dl);
		return;
	}
	gov_pending = 0;
	uint64_t now = mach_absolute_time(), idle_ns = 0, up_ns = 0;
	absolutetime_to_nanoseconds(now - gov_last_job, &idle_ns);
	absolutetime_to_nanoseconds(now, &up_ns);
	uint32_t idle_ms = (uint32_t)(idle_ns / 1000000ULL);
	int want_gpu_lo = idle_ms >= gov_gpu_ms || sweet_thermal_cap;
	int want_cpu_lo = (idle_ms >= gov_cpu_ms && up_ns / 1000000000ULL >= gov_cpu_after) || sweet_thermal_cap;
	if (!want_cpu_lo && gov_cpu_lo) {
		gov_set(0, 0);
		gov_cpu_lo = 0;
		gov_switches++;
	}
	if (want_gpu_lo != gov_gpu_lo) {
		gov_set(1, want_gpu_lo);
		gov_gpu_lo = want_gpu_lo;
		gov_switches++;
	}
	if (want_cpu_lo && !gov_cpu_lo) {
		gov_set(0, 1);
		gov_cpu_lo = 1;
		gov_switches++;
	}
	if (gov_switches <= 24 || (gov_switches % 200) == 0) {
		static uint32_t logged;
		if (logged != gov_switches) {
			logged = gov_switches;
			mali_log("dvfs gov: gpu %s cpu %s (idle %u ms, %u switches)", gov_gpu_lo ? "lo" : "hi",
			    gov_cpu_lo ? "lo" : "hi", idle_ms, gov_switches);
		}
	}
	gov_busy = 0;
	/* keep checking until everything is low; a job re-arms it from mali_submit_wait */
	if (!gov_gpu_lo || (!gov_cpu_lo && gov_cpu_ms)) {
		uint64_t dl;
		clock_interval_to_deadline(gov_gpu_lo ? 1000 : 250, NSEC_PER_MSEC, &dl);
		thread_call_enter_delayed(gov_tc, dl);
	}
}

static inline void
gov_job(void)
{
	gov_last_job = mach_absolute_time();
	if (gov_tc && (gov_gpu_lo || gov_cpu_lo) && OSCompareAndSwap(0, 1, &gov_pending)) {
		thread_call_enter(gov_tc);
	}
}

static void
gov_start(void)
{
	PE_parse_boot_argn("sweetgov", &gov_on, sizeof(gov_on));
	PE_parse_boot_argn("sweetgov_gpu_ms", &gov_gpu_ms, sizeof(gov_gpu_ms));
	PE_parse_boot_argn("sweetgov_cpu_ms", &gov_cpu_ms, sizeof(gov_cpu_ms));
	PE_parse_boot_argn("sweetgov_cpu_after", &gov_cpu_after, sizeof(gov_cpu_after));
	if (!gov_on || !dvfs_ok) {
		mali_log("dvfs gov: off");
		return;
	}
	if (!gov_cpu_ms) {
		gov_cpu_ms = 0xFFFFFFFFU;   /* never lower the CPU */
	}
	gov_last_job = mach_absolute_time();
	gov_tc = thread_call_allocate(gov_run, NULL);
	uint64_t dl;
	clock_interval_to_deadline(250, NSEC_PER_MSEC, &dl);
	thread_call_enter_delayed(gov_tc, dl);
	mali_log("dvfs gov: on (gpu lo after %u ms, cpu lo after %u ms once up %u s)", gov_gpu_ms, gov_cpu_ms,
	    gov_cpu_after);
}

void sweet_mali_boot(void);

void
sweet_mali_boot(void)
{
	uint64_t scratch = 0;
	uint32_t pages = 256;
	int on = 0;

	if (mali.up) {
		return;                            /* already booted (IOKit service or touch init) */
	}
	mali_log("boot: entered");
	if (!PE_parse_boot_argn("mali", &on, sizeof(on)) || !on) {
		return;
	}
	if (!PE_parse_boot_argn("gpu_scratch", &scratch, sizeof(scratch)) || !scratch) {
		mali_log("no gpu_scratch boot-arg");
		return;
	}
	PE_parse_boot_argn("mali_pages", &pages, sizeof(pages));
	if (pages > 512) {
		pages = 512;                       /* the 2 MiB window */
	}
	mali.reg = ml_io_map(MALI_PHYS, MALI_SIZE);
	mali.pool_pa = scratch;
	mali.pool_pages = pages;
	mali.pool_va = ml_io_map((vm_offset_t)scratch, (vm_size_t)pages << 12);
	if (!mali.reg || !mali.pool_va) {
		mali_log("map failed");
		return;
	}
	mali.gpu_id = rd(R_GPU_ID);
	if ((mali.gpu_id >> 16) != 0x9202U) {
		mali_log("unexpected GPU_ID %08x, not touching it", mali.gpu_id);
		return;
	}
	mali.shader_present = rd(R_SHADER_PRESENT);
	PE_parse_boot_argn("mali_onecore", &sweet_mali_one_core, sizeof(sweet_mali_one_core));
	mali.tiler_present = rd(R_TILER_PRESENT);
	mali.l2_present = rd(R_L2_PRESENT);
	mali.as_present = rd(R_AS_PRESENT);
	mali.js_present = rd(R_JS_PRESENT);
	wr(R_GPU_IRQ_MASK, 0);
	wr(R_JOB_IRQ_MASK, 0);
	wr(R_MMU_IRQ_MASK, 0);
	mali_log("gpu %08x shaders %08x as %x js %x pool %u pages at %llx", mali.gpu_id, mali.shader_present,
	    mali.as_present, mali.js_present, pages, scratch);
	mali.up = 1;
	if (mali_power(1)) {
		mali_log("power on failed");
		return;
	}
	mali_log("powered: shader=%x tiler=%x l2=%x", rd(R_SHADER_READY), rd(R_TILER_READY), rd(R_L2_READY));
	mali_dvfs(1);
	gov_start();
	swd_start();
	(void)sweet_s21keys_start();   /* S21 side keys (0125) */
	(void)sweet_s21_battery_start();   /* iOS battery from the MAX77705 gauge (0127), sweetbattery=2 */
	mali_selftest();
	mali_selftest_heap();
	mali_log("ready, left powered (pool used %u of %u pages)", mali.pool_next, mali.pool_pages);
}

/* ---- exported API for the IOKit layer (iokit/Kernel/arm/SweetMali.cpp); the caller serializes ---- */
#define MALI_MAX_CTX 8
static struct mali_ctx ctxs[MALI_MAX_CTX];
/* skip re-activating the address space and the LOCK/FLUSH_MEM/UNLOCK sequence before a job when this context's
 * page tables did not change since its last job (the job's own START_FLUSH cleans+invalidates the GPU L2) */
static uint32_t mali_pt_gen = 1, ctx_flushed_gen[MALI_MAX_CTX];
static int ctx_used[MALI_MAX_CTX];

int sweet_mali_up(void);
void sweet_mali_get_info(uint32_t out[6]);
int sweet_mali_ctx_create(void);
void sweet_mali_ctx_destroy(int id);
int sweet_mali_ctx_map(int id, uint64_t va, uint64_t pa);
void sweet_mali_ctx_unmap(int id, uint64_t va);
uint32_t sweet_mali_submit(int id, uint32_t slot, uint64_t jc_va, uint32_t timeout_ms);
void sweet_mali_set_asflush(int on);
void sweet_mali_log_str(const char *s);

static int use_asflush = 1;
static int mali_lazy_as = 1;    /* boot-arg sweetlazyas=0: activate + flush the AS before every job as before */

void
sweet_mali_set_asflush(int on)
{
	use_asflush = on;
}

int
sweet_mali_up(void)
{
	return mali.up && mali.powered;
}

void
sweet_mali_get_info(uint32_t out[6])
{
	out[0] = mali.gpu_id;
	out[1] = mali.shader_present;
	out[2] = mali.tiler_present;
	out[3] = mali.l2_present;
	out[4] = mali.as_present;
	out[5] = mali.js_present;
}

void
sweet_mali_log_str(const char *s)
{
	mali_log("%s", s);
}

/* returns a context id (== its address space number) or -1 */
int
sweet_mali_ctx_create(void)
{
	for (int i = 0; i < MALI_MAX_CTX; i++) {
		if (!ctx_used[i] && ((mali.as_present >> i) & 1U)) {
			if (ctx_init(&ctxs[i], i)) {
				return -1;
			}
			ctx_used[i] = 1;
			return i;
		}
	}
	return -1;
}

static void
mali_as_invalidate_all(void)
{
	for (int i = 0; i < MALI_MAX_CTX; i++) {
		ctx_flushed_gen[i] = 0;
	}
}

void
sweet_mali_ctx_destroy(int id)
{
	ctx_flushed_gen[id >= 0 && id < MALI_MAX_CTX ? id : 0] = 0;
	if (id < 0 || id >= MALI_MAX_CTX || !ctx_used[id]) {
		return;
	}
	ctx_deactivate(&ctxs[id]);
	/* return the context's page-table pages (levels 0..2 tables and the level-3 leaf tables, not the mapped pages) */
	{
		uint64_t pgd = ctxs[id].pgd_pa;
		volatile uint32_t *t0 = pa2va(pgd);
		for (uint32_t a = 0; a < 512; a++) {
			uint64_t e0 = (uint64_t)t0[a * 2] | ((uint64_t)t0[a * 2 + 1] << 32);
			if ((e0 & 3ULL) != 3ULL) {
				continue;
			}
			uint64_t p1 = e0 & 0x0000FFFFFFFFF000ULL;
			volatile uint32_t *t1 = pa2va(p1);
			for (uint32_t b = 0; b < 512; b++) {
				uint64_t e1 = (uint64_t)t1[b * 2] | ((uint64_t)t1[b * 2 + 1] << 32);
				if ((e1 & 3ULL) != 3ULL) {
					continue;
				}
				uint64_t p2 = e1 & 0x0000FFFFFFFFF000ULL;
				volatile uint32_t *t2 = pa2va(p2);
				for (uint32_t c = 0; c < 512; c++) {
					uint64_t e2 = (uint64_t)t2[c * 2] | ((uint64_t)t2[c * 2 + 1] << 32);
					if ((e2 & 3ULL) == 3ULL) {
						pool_free_pa(e2 & 0x0000FFFFFFFFF000ULL);
					}
				}
				pool_free_pa(p2);
			}
			pool_free_pa(p1);
		}
		pool_free_pa(pgd);
		ctxs[id].pgd_pa = 0;
	}
	ctx_used[id] = 0;
}

int
sweet_mali_ctx_map(int id, uint64_t va, uint64_t pa)
{
	if (id < 0 || id >= MALI_MAX_CTX || !ctx_used[id]) {
		return -1;
	}
	mali_pt_gen++;
	return ctx_map(&ctxs[id], va, pa);
}

void
sweet_mali_ctx_unmap(int id, uint64_t va)
{
	if (id < 0 || id >= MALI_MAX_CTX || !ctx_used[id]) {
		return;
	}
	(void)ctx_map; /* leaf entry is rewritten to 0 by walking the existing tables */
	mali_pt_gen++;
	uint64_t t = ctxs[id].pgd_pa;
	uint32_t idx[3] = { (uint32_t)((va >> 39) & 0x1FF), (uint32_t)((va >> 30) & 0x1FF), (uint32_t)((va >> 21) & 0x1FF) };
	for (int l = 0; l < 3; l++) {
		volatile uint32_t *tb = pa2va(t);
		uint64_t e = (uint64_t)tb[idx[l] * 2] | ((uint64_t)tb[idx[l] * 2 + 1] << 32);
		if (!(e & 1ULL)) {
			return;
		}
		t = e & 0x0000FFFFFFFFF000ULL;
	}
	volatile uint32_t *leaf = pa2va(t);
	uint32_t li = (uint32_t)((va >> 12) & 0x1FF);
	leaf[li * 2] = 0;
	leaf[li * 2 + 1] = 0;
}

/* activate the context, flush its TLB, run one job chain; 0 = done, else the JS_STATUS code */
uint32_t
sweet_mali_submit(int id, uint32_t slot, uint64_t jc_va, uint32_t timeout_ms)
{
	if (id < 0 || id >= MALI_MAX_CTX || !ctx_used[id] || slot >= 3 || !mali.up || !mali.powered) {
		return 0xFFFDU;
	}
	if (mali_faults >= MALI_MAX_FAULTS) {
		return 0xFFFCU;
	}
	{ static int parsed; if (!parsed) { parsed = 1; PE_parse_boot_argn("sweetlazyas", &mali_lazy_as, sizeof(mali_lazy_as)); } }
	if (!mali_lazy_as || ctx_flushed_gen[id] != mali_pt_gen) {
		ctx_activate(&ctxs[id]);
		if (use_asflush) {
			as_flush((uint32_t)id);
		}
		ctx_flushed_gen[id] = mali_pt_gen;
	}
	uint32_t r = mali_submit_wait(&ctxs[id], slot, jc_va, timeout_ms);
	return r;
}
#endif /* ARM64_BOARD_CONFIG_SWEET */
EOF_SWEET_SRC

grep -q 'bsd/dev/sweet_mali.c' bsd/conf/files || printf 'bsd/dev/sweet_mali.c\t\t\tstandard\n' >> bsd/conf/files
