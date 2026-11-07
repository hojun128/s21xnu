#!/bin/bash
# Mirror the SWEET console log into the Samsung ramoops pmsg zone (phys 0x8f020000,
# 128 KiB, persistent_ram_buffer layout) so a recovery can read it from
# /sys/fs/pstore/pmsg-ramoops-0 after a panic or reset without filming the screen.
# dxb runs patches/*.sh from the XNU source root before applying *.patch.
set -euo pipefail

[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0
[[ -f bsd/conf/files ]] || exit 1

cat > bsd/dev/sweet_ramoops.c <<'EOC'
/*
 * SWEET: console log mirror into the ramoops pmsg zone.
 * persistent_ram_buffer: u32 sig 'DBGC' | u32 start | u32 size | data[]
 */
#include <sys/param.h>
#include <sys/systm.h>
#include <machine/machine_routines.h>
#include <pexpert/pexpert.h>

extern vm_offset_t ml_io_map(vm_offset_t phys_addr, vm_size_t size);

#define SWEET_RR_PHYS   0x8f020000UL
#define SWEET_RR_SIZE   0x20000UL
#define SWEET_RR_HDR    12UL
#define SWEET_RR_DATA   (SWEET_RR_SIZE - SWEET_RR_HDR)

volatile uint8_t *sweet_rr;

void sweet_ramoops_put(uint64_t at, const char *c, int size);
void sweet_ramoops_init(const char *ring, uint64_t total);

void
sweet_ramoops_put(uint64_t at, const char *c, int size)
{
	volatile uint8_t *d = sweet_rr + SWEET_RR_HDR;
	volatile uint32_t *h = (volatile uint32_t *)sweet_rr;
	for (int i = 0; i < size; i++) {
		d[(at + (uint64_t)i) % SWEET_RR_DATA] = (uint8_t)c[i];
	}
	uint64_t total = at + (uint64_t)size;
	h[1] = (total >= SWEET_RR_DATA) ? (uint32_t)(total % SWEET_RR_DATA) : 0;
	h[2] = (total >= SWEET_RR_DATA) ? (uint32_t)SWEET_RR_DATA : (uint32_t)total;
}

/* Called once the console ring holds the boot log so far (UFS init time). */
void
sweet_ramoops_init(const char *ring, uint64_t total)
{
	if (sweet_rr) {
		return;
	}
	vm_offset_t va = ml_io_map(SWEET_RR_PHYS, SWEET_RR_SIZE);
	if (!va) {
		return;
	}
	volatile uint8_t *rr = (volatile uint8_t *)va;
	volatile uint32_t *h = (volatile uint32_t *)rr;
	h[0] = 0x43474244U;     /* 'DBGC' */
	h[1] = 0;
	h[2] = 0;
	sweet_rr = rr;
	/* backfill what was printed before the mapping existed */
	uint64_t from = total > SWEET_RR_DATA ? total - SWEET_RR_DATA : 0;
	if (total <= (4u << 20) && total > from) {
		sweet_ramoops_put(from, ring + from, (int)(total - from));
	}
}
EOC

grep -q 'bsd/dev/sweet_ramoops.c' bsd/conf/files || printf 'bsd/dev/sweet_ramoops.c\t\t\tstandard\n' >> bsd/conf/files
