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
#include <machine/machine_routines.h>
#include <arm/caches_internal.h>
#include <vm/pmap.h>
#include <vm/vm_kern.h>
#include <libkern/libkern.h>
#include <pexpert/pexpert.h>
#include <stdarg.h>

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
static uint32_t
wait_reg(uint32_t off, uint32_t mask, uint32_t want, uint32_t ms)
{
	for (uint32_t t = 0; t < ms; t++) {
		if ((rd(off) & mask) == want) {
			return t;
		}
		us(1000);
	}
	return (rd(off) & mask) == want ? ms : 0xFFFFFFFFU;
}

/* ---- RAM pool: page tables and GPU buffers come from the unmanaged scratch window ---- */
static uint64_t
pool_alloc(void)
{
	if (mali.pool_next >= mali.pool_pages) {
		return 0;
	}
	uint32_t i = mali.pool_next++;
	volatile uint32_t *p = (volatile uint32_t *)(mali.pool_va + ((vm_offset_t)i << 12));
	for (uint32_t k = 0; k < 1024; k++) {
		p[k] = 0;
	}
	return mali.pool_pa + ((uint64_t)i << 12);
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
static uint32_t mali_faults;     /* after MALI_MAX_FAULTS faults/timeouts the GPU is fenced off until reboot */
#define MALI_MAX_FAULTS 12

static void
mali_recover(const char *why)
{
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

/* ---- job submission (polling) ---- */
/* returns 0 on DONE, else the JS_STATUS exception code (or 0xFFFF on timeout) */
static uint32_t
mali_submit_wait(struct mali_ctx *c, uint32_t slot, uint64_t jc_va, uint32_t timeout_ms)
{
	uint32_t done = 1U << slot, fail = 1U << (slot + 16), raw = 0, t;
	wr(R_JOB_IRQ_CLEAR, 0xFFFFFFFFU);
	wr(R_MMU_IRQ_CLEAR, 0xFFFFFFFFU);
	wr(R_JS(slot, 0x40), (uint32_t)jc_va);
	wr(R_JS(slot, 0x44), (uint32_t)(jc_va >> 32));
	wr(R_JS(slot, 0x50), mali.shader_present & (~mali.shader_present + 1U));
	wr(R_JS(slot, 0x54), 0);
	wr(R_JS(slot, 0x58), ((uint32_t)c->as) | (3U << 8) | (1U << 10) | (3U << 12) | (8U << 16));
	wr(R_JS(slot, 0x60), JS_COMMAND_START);
	for (t = 0; t < timeout_ms; t++) {
		raw = rd(R_JOB_IRQ_RAW);
		if (raw & (done | fail)) {
			break;
		}
		us(1000);
	}
	if (!(raw & (done | fail))) {
		uint32_t as = (uint32_t)c->as;
		mali_log("job timeout slot %u js=%x mmu=%x fault=%x/%x", slot, rd(R_JS(slot, 0x24)), rd(R_MMU_IRQ_RAW),
		    rd(R_AS(as, 0x1C)), rd(R_AS(as, 0x20)));
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
	mali_selftest();
	mali_selftest_heap();
	mali_log("ready, left powered (pool used %u of %u pages)", mali.pool_next, mali.pool_pages);
}

/* ---- exported API for the IOKit layer (iokit/Kernel/arm/SweetMali.cpp); the caller serializes ---- */
#define MALI_MAX_CTX 8
static struct mali_ctx ctxs[MALI_MAX_CTX];
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

void
sweet_mali_ctx_destroy(int id)
{
	if (id < 0 || id >= MALI_MAX_CTX || !ctx_used[id]) {
		return;
	}
	ctx_deactivate(&ctxs[id]);
	ctx_used[id] = 0;      /* table pages stay in the pool (no free list yet) */
}

int
sweet_mali_ctx_map(int id, uint64_t va, uint64_t pa)
{
	if (id < 0 || id >= MALI_MAX_CTX || !ctx_used[id]) {
		return -1;
	}
	return ctx_map(&ctxs[id], va, pa);
}

void
sweet_mali_ctx_unmap(int id, uint64_t va)
{
	if (id < 0 || id >= MALI_MAX_CTX || !ctx_used[id]) {
		return;
	}
	(void)ctx_map; /* leaf entry is rewritten to 0 by walking the existing tables */
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
	ctx_activate(&ctxs[id]);
	if (use_asflush) {
		as_flush((uint32_t)id);
	}
	uint32_t r = mali_submit_wait(&ctxs[id], slot, jc_va, timeout_ms);
	return r;
}
#endif /* ARM64_BOARD_CONFIG_SWEET */
EOF_SWEET_SRC

grep -q 'bsd/dev/sweet_mali.c' bsd/conf/files || printf 'bsd/dev/sweet_mali.c\t\t\tstandard\n' >> bsd/conf/files
