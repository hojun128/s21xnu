#!/bin/bash
# S21 (o1s, SM-G991N) Wi-Fi: the BCM4375 B1 on Exynos 2100 PCIe channel 0.
#
# The chip driver, the station, en0, the Apple80211 answers and the WPA2 handshake are N1709/z3sios's (MIT; XNU-derived
# parts APSL 2.0; brcmfmac-derived parts ISC): the S20 Ultra port runs the same chip with the same firmware
# (18.41.117) in XNU. Those files are fetched unmodified at a pinned commit and checked by SHA-256 (credits:
# THIRD_PARTY_Z3SIOS.md). What is the S21's is bsd/dev/sweet_wifi.c below: the PCIe link on this SoC, the S2MPU
# grants for the DMA pool, and the few functions the z3sios files expect from their loader.
# dxb runs patches/*.sh from the XNU source root before applying *.patch.
set -euo pipefail
[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0
[[ -f bsd/conf/files ]] || exit 1
[[ -f iokit/Kernel/arm/SweetMali.cpp ]] || exit 1   # 0112 runs first; RedwoodWLAN.cpp is appended to it

Z3S_SHA=1323aa51d4c16816fa8fd95309f864f7e3888793
Z3S_RAW=https://raw.githubusercontent.com/N1709/z3sios/$Z3S_SHA/kernel/xnu/files
z3s_tmp=$(mktemp -d)
trap 'rm -rf "$z3s_tmp"' EXIT
while read -r sum path; do
	out="$z3s_tmp/$(basename "$path")"
	for try in 1 2 3 4 5; do
		curl -fsSL --retry 3 -o "$out" "$Z3S_RAW/$path" && break
		sleep $((try * 5))
	done
	got=$(shasum -a 256 "$out" | cut -c1-64)
	[[ "$got" == "$sum" ]] || { echo "z3sios $path: sha256 $got, want $sum" >&2; exit 1; }
done <<'EOF_SUMS'
f34eb5a7bdfd6c2efa211e3f9d1369c8d33cc1efcdddcd5512712fab653c55ed bsd/dev/redwood_bcm4375.c
9d85fe742d8992f8f6928bc2c20f03a5278d9ce73c78b4617755c1e1643b13ca bsd/dev/redwood_sta.c
7002f03c339f87d3addb19b8a184391b3b51efe094b01ff7e0422b6b0ead2756 bsd/dev/redwood_net.c
2fa706682c63f80f08a538e5d9d3a2b45f8265573b355bb585b1f3cca76b706c bsd/dev/redwood_apple80211.c
67a5511bb42330fc2158d1d86595cfc8e6db732cda559378263e37229b5117da bsd/dev/lx_wpa.c
719feef82ee63a10066cdecd4a7d62ed62d03e4811ae35cc1ecfc956bb0f9f12 bsd/dev/lx_wpa.h
f122714b56d0c22a3b546e67b6ff4d813753652e520b60d1e0c755a0102c3065 bsd/sys/redwood_net.h
6d8aebca76634178dfd0c24584dc85ceacb5b8a003b476cbf3189bb730e3d9eb bsd/sys/redwood_sta.h
5b00cd093e1b806c300d17f3d2bd0f4fbd41cb266cdf992756d88c5087ab7b02 bsd/sys/redwood_input.h
7b7b3c4dec2d5d3d1e773a41e95c5b19f6d3a93a20edc30b630c62f3bd0f784c iokit/Kernel/RedwoodWLAN.cpp
EOF_SUMS

for f in redwood_bcm4375.c redwood_sta.c redwood_net.c redwood_apple80211.c lx_wpa.c lx_wpa.h; do
	cp "$z3s_tmp/$f" bsd/dev/
done
for f in redwood_net.h redwood_sta.h redwood_input.h; do
	cp "$z3s_tmp/$f" bsd/sys/
done
# their printf lines (wifid's Apple80211 requests, en0's events) go to the console, which this kernel does not keep:
# routed to sweet_wifi_printf (bsd/dev/sweet_wifi.c: the persistent log, the first 150 lines kept)
for f in redwood_net.c redwood_apple80211.c; do
	perl -pi -e 's/\bprintf\(/sweet_wifi_printf(/g' "bsd/dev/$f"
	perl -0pi -e 's/\A/int sweet_wifi_printf(const char *, ...) __attribute__((format(printf, 1, 2)));\n/' "bsd/dev/$f"
done
# the IOKit objects iOS finds the interface by: compiled as part of SweetMali.cpp (adding a line to files.arm64 here
# breaks every later patch of that list, see 0127); its file-local helper renamed so it cannot clash
{
	printf '\n/* ---- N1709/z3sios iokit/Kernel/RedwoodWLAN.cpp (MIT), appended by 0142-s21-wifi.sh ---- */\n'
	printf 'extern "C" int sweet_wifi_printf(const char *, ...) __attribute__((format(printf, 1, 2)));\n'
	perl -pe 's/\bpublish\(/rw_publish(/g; s/\bIOLog\(/sweet_wifi_printf(/g' "$z3s_tmp/RedwoodWLAN.cpp"
} >> iokit/Kernel/arm/SweetMali.cpp

cat > bsd/dev/sweet_wifi.c <<'EOF_SWEET_SRC'
/*
 * S21 (o1s, Exynos 2100) Wi-Fi: PCIe channel 0 to the Broadcom BCM4375 B1, from S-Boot's state (no Linux before us).
 * Nothing is touched unless boot-arg sweetwifi=N asks:
 *
 *   1  survey, reads only: PMU (PHY isolation, TCXO_FAR), HSI1 sysreg, the pins (WLAN_REG_ON gpp12-2, CLKREQ gpf0-0,
 *      PERST# gpf0-1). No register of the PCIe block itself.
 *   2  + power and link: WLAN_REG_ON high, 200 ms, pins, TCXO_FAR, PHY isolation off, PHY power-down clear, the
 *      Gen2 PHY tables, soft core reset, PERST# released, root port set-up, LTSSM to L0 (3 tries), the iATU (CFG0 +
 *      memory window), the endpoint's id and BAR sizes. Want 14e4:4475.
 *   3  + the DMA pool (0x92400000, 8 MiB, below 4 GB: nothing of XNU's and no reserved-memory region of the vendor DT)
 *      granted to the PCIE_GEN2 S2MPU subsystem through Samsung's documented hypervisor call (HVC 0xC6000100,
 *      exynos_set_dev_stage2_ap(): subsystem 7, 32 KiB granules, read-write), as Samsung's own PCIe driver does
 *      before the chip may DMA. The S2MPU table at 0xC1800000 is a vendor reserved region XNU never uses.
 *   4  + the chip: redwood_bcm4375_run() (z3sios): firmware, NVRAM and CLM from /usr/local/etc/wifi on the root,
 *      the rings, an escan, then the station behind en0 for iOS's Wi-Fi.
 *
 * sweetwifi_wait=S: seconds before the work starts (default 2; the firmware needs the root mounted, waited for).
 * Register facts (offsets, values, order) from Samsung's GPL Exynos 2100 sources (pcie-exynos-host-v0.c,
 * pcie-exynos2100-v0-cal.c, exynos-s2mpu.c, the o1s device tree) and this repository's 0109 port of them; no GPL code.
 * Every line goes to the kept log ("wifi: ..."). Every wait is bounded; an MMIO access that never completes is the one
 * thing that cannot be, so blocks are touched in Samsung's order only.
 */
#if defined(ARM64_BOARD_CONFIG_SWEET)
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/errno.h>
#include <sys/kauth.h>
#include <sys/vnode.h>
#include <sys/vnode_internal.h>
#include <kern/clock.h>
#include <kern/kalloc.h>
#include <kern/thread.h>
#include <kern/sched_prim.h>
#include <kern/locks.h>
#include <machine/machine_routines.h>
#include <vm/memory_types.h>
#include <pexpert/pexpert.h>
#include <libkern/libkern.h>
#include <stdarg.h>

extern vm_offset_t ml_io_map(vm_offset_t, vm_size_t);
extern vm_offset_t ml_io_map_unmappable(vm_offset_t phys_addr, vm_size_t size, unsigned int flags);
extern void sweet_mali_log_str(const char *s);
int sweet_wifi_start(void);

/* what redwood_bcm4375.c (z3sios) takes: the same layout as its struct */
struct redwood_bcm_bus {
	volatile uint8_t *cfg;
	volatile uint8_t *dbi;
	uint32_t mem_phys, mem_size;
	uint64_t bar0_size, bar2_size;
	bool bar0_wide, bar2_wide;
	uint64_t pool_phys;
	vm_offset_t pool_virt;
	size_t pool_mapped;
};
void redwood_bcm4375_run(const struct redwood_bcm_bus *bus);

/* ---- log ------------------------------------------------------------------------------------------------- */
static void
wlog(const char *fmt, ...)
{
	char line[190];
	va_list ap;
	strlcpy(line, "wifi: ", sizeof(line));
	va_start(ap, fmt);
	vsnprintf(line + 6, sizeof(line) - 6, fmt, ap);
	va_end(ap);
	sweet_mali_log_str(line);
}

/* z3sios's loader log: their lines already begin "wifi: " and end in a newline */
void loader_log_line(const char *line);
void
loader_log_line(const char *line)
{
	char b[190];
	size_t n;
	strlcpy(b, line, sizeof(b));
	n = strlen(b);
	while (n && (b[n - 1] == '\n' || b[n - 1] == '\r')) {
		b[--n] = 0;
	}
	if (strncmp(b, "wifi", 4) != 0) {
		char c[190];
		snprintf(c, sizeof(c), "wifi: %s", b);
		sweet_mali_log_str(c);
		return;
	}
	sweet_mali_log_str(b);
}

int redwood_wifi_tell(const char *format, ...) __printflike(1, 2);
int
redwood_wifi_tell(const char *format, ...)
{
	char b[190];
	va_list ap;
	va_start(ap, format);
	vsnprintf(b, sizeof(b), format, ap);
	va_end(ap);
	loader_log_line(b);
	return 0;
}

/* no network given to the kernel: iOS's Settings joins one (redwood_bcm4375.c asks once at start) */
bool redwood_wifi_network(uint8_t *name, unsigned *name_length, uint8_t *passphrase, unsigned *passphrase_length);
bool
redwood_wifi_network(uint8_t *name, unsigned *name_length, uint8_t *passphrase, unsigned *passphrase_length)
{
	(void)name; (void)name_length; (void)passphrase; (void)passphrase_length;
	return false;
}

/* firmware files: no small image here; /usr/local/etc/wifi on the root (push_rootfs.sh puts the phone's own there) */
const uint8_t *redwood_image_file(const char *dir, const char *name, uint64_t *size, int *disk_out);
const uint8_t *
redwood_image_file(const char *dir, const char *name, uint64_t *size, int *disk_out)
{
	(void)dir; (void)name; (void)size;
	if (disk_out) {
		*disk_out = 0;
	}
	return NULL;
}

#define WF_MAX (4U * 1024 * 1024)
const uint8_t *redwood_adsp_fw_file(const char *name, uint64_t *size);
const uint8_t *
redwood_adsp_fw_file(const char *name, uint64_t *size)
{
	char path[96];
	vfs_context_t ctx = vfs_context_kernel();
	vnode_t vp = NULLVP;
	struct vnode_attr va;
	uint8_t *data;
	int left = 0, err;

	if (rootvnode == NULLVP) {
		return NULL;
	}
	snprintf(path, sizeof(path), "/usr/local/etc/wifi/%s", name);
	if (vnode_lookup(path, 0, &vp, ctx) != 0) {
		wlog("no %s", path);
		return NULL;
	}
	VATTR_INIT(&va);
	VATTR_WANTED(&va, va_data_size);
	if (vnode_getattr(vp, &va, ctx) != 0 || va.va_data_size == 0 || va.va_data_size > WF_MAX) {
		vnode_put(vp);
		return NULL;
	}
	data = kalloc_data(va.va_data_size, Z_WAITOK);
	if (data == NULL) {
		vnode_put(vp);
		return NULL;
	}
	err = vn_rdwr(UIO_READ, vp, (caddr_t)data, (int)va.va_data_size, 0, UIO_SYSSPACE, 0, vfs_context_ucred(ctx), &left,
	    vfs_context_proc(ctx));
	vnode_put(vp);
	if (err != 0 || left != 0) {
		wlog("%s: read error %d, %d left", path, err, left);
		kfree_data(data, va.va_data_size);
		return NULL;
	}
	*size = va.va_data_size;
	return data;
}

void redwood_adsp_fw_free(const uint8_t *data, uint64_t size);
void
redwood_adsp_fw_free(const uint8_t *data, uint64_t size)
{
	uint8_t *ours = __DECONST(uint8_t *, data);   /* kfree_data() erases its argument: an lvalue */
	kfree_data(ours, size);
}

/* printf of redwood_net.c / redwood_apple80211.c / RedwoodWLAN.cpp (0142 renames their calls): lines assembled across
 * calls, the first 150 as "wifi: " (kept for the recovery replay), later ones "wnet: " (persistent ring only) */
static LCK_GRP_DECLARE(wp_grp, "sweet-wifi-printf");
static LCK_MTX_DECLARE(wp_mtx, &wp_grp);
static char wp_buf[180];
static size_t wp_len;
static unsigned wp_lines;
int sweet_wifi_printf(const char *fmt, ...) __printflike(1, 2);
int
sweet_wifi_printf(const char *fmt, ...)
{
	char tmp[180];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(tmp, sizeof(tmp), fmt, ap);
	va_end(ap);
	lck_mtx_lock(&wp_mtx);
	for (const char *c = tmp; *c; c++) {
		if (*c != '\n' && wp_len < sizeof(wp_buf) - 1) {
			wp_buf[wp_len++] = *c;
		}
		if (*c == '\n' || wp_len >= sizeof(wp_buf) - 1) {
			char line[192];
			wp_buf[wp_len] = 0;
			snprintf(line, sizeof(line), "%s %s", wp_lines < 150 ? "wifi:" : "wnet:", wp_buf);
			wp_lines++;
			wp_len = 0;
			sweet_mali_log_str(line);
		}
	}
	lck_mtx_unlock(&wp_mtx);
	return 0;
}

void redwood_virtio_net_init(void);
void
redwood_virtio_net_init(void)
{
}

/* ---- the SoC --------------------------------------------------------------------------------------------- */
#define PA_ELBI         0x113b0000ULL
#define PA_PHY          0x113e0000ULL
#define PA_SYSREG_PG    0x11021000ULL   /* HSI1 sysreg: +0x044 PCS_HS, +0x050 PHY_CONTROL, +0x064 NCLK_OFF */
#define PA_DBI          0x113f0000ULL
#define PA_PCS          0x113d0000ULL
#define PA_CFG          0x20ffe000ULL   /* CFG0 window (vendor DT "config") */
#define PA_MEM          0x20000000U     /* outbound memory window, PCI address = CPU address (DT ranges) */
#define SZ_MEM          0x00ff0000U
#define PA_PMU          0x15860000ULL
#define PMU_PHY_ISO     0x71c           /* DT pmu-offset; bit 0 = 1: PHY out of isolation */
#define PMU_TCXO_FAR    0x3e10
#define PA_GPIO_HSI1    0x11040000ULL   /* gpf0 at +0x00 */
#define PA_GPIO_PERIC1  0x10730000ULL   /* gpp12 at +0x60 */
#define GPF0            0x00
#define GPP12           0x60
#define G_CON           0x0             /* 4 bits a pin */
#define G_DAT           0x4
#define G_PUD           0x8             /* 4 bits a pin, 3 = pull-up */
#define G_DRV           0xc

#define SYS_PCS_HS      0x044
#define SYS_PHY_CTRL    0x050
#define  PCS_LANE0_EN   (1U << 12)
#define SYS_NCLK        0x064

#define ELBI_IRQ_EN_PULSE   0x00c
#define ELBI_IRQ_EN_LEVEL   0x010
#define ELBI_IRQ_EN_SPECIAL 0x014
#define ELBI_SW_WAKE        0x018
#define ELBI_LTSSM_EN       0x02c
#define ELBI_TOE_PULSE2     0x034
#define ELBI_TOE_LEVEL      0x038
#define ELBI_RDLH_LINKUP    0x074
#define ELBI_APP_REQ_L1     0x0f4
#define ELBI_LINKDOWN_SEL   0x1b8
#define ELBI_SOFT_RESET     0x1d0
#define ELBI_HISTORY        0x274
#define ELBI_PHY_RST_288    0x288
#define ELBI_PHY_RST_28C    0x28c
#define ELBI_PHY_RST_290    0x290
#define ELBI_PHY_RST_294    0x294
#define ELBI_POWER_S        0x2bc
#define ELBI_POWER_M        0x2c0
#define ELBI_QCH_SEL        0x2c8

#define DBI_CMD         0x004
#define DBI_CLASS_REV   0x008
#define DBI_BAR0        0x010
#define DBI_BAR1        0x014
#define DBI_BUSES       0x018
#define DBI_CAP_PTR     0x034
#define DBI_INTR        0x03c
#define DBI_PLC         0x710
#define DBI_LWS         0x80c
#define DBI_MISC1       0x8bc
#define DBI_AUX_CLK     0xb40
#define DBI_L1SUB       0xb44
#define ATU_VIEWPORT    0x900
#define ATU_CR1         0x904
#define ATU_CR2         0x908
#define ATU_LBASE       0x90c
#define ATU_UBASE       0x910
#define ATU_LIMIT       0x914
#define ATU_LTARGET     0x918
#define ATU_UTARGET     0x91c

#define POOL_PHYS       0x92400000ULL
#define POOL_SIZE       0x00800000ULL
#define S2MPU_HVC       0xC6000100ULL   /* HVC_FID_SET_S2MPU */
#define S2MPU_PCIE_GEN2 7ULL            /* index in the vendor DT's s2mpu subsystem-names */
#define S2MPU_GRANULE   0x8000ULL
#define S2MPU_RW        3ULL

static volatile uint8_t *elbi, *phy, *sysr, *dbi, *pcs, *cfgw, *pmu, *ghsi1, *gperic1;
static struct redwood_bcm_bus bus;

static inline uint32_t rd(volatile uint8_t *b, uint32_t o) { return *(volatile uint32_t *)(b + o); }
static inline void wr(volatile uint8_t *b, uint32_t o, uint32_t v) { *(volatile uint32_t *)(b + o) = v; }
static inline void rmw(volatile uint8_t *b, uint32_t o, uint32_t clr, uint32_t set) { wr(b, o, (rd(b, o) & ~clr) | set); }

static void
udly(uint32_t us)
{
	uint64_t t0 = mach_absolute_time(), d;
	nanoseconds_to_absolutetime((uint64_t)us * 1000ULL, &d);
	while (mach_absolute_time() - t0 < d) {
	}
}
static void msleep_(uint32_t ms) { delay((int)(ms * 1000)); }

static volatile uint8_t *
mapr(uint64_t pa, uint64_t sz)
{
	uint64_t base = pa & ~0x3fffULL, off = pa - base, len = (off + sz + 0x3fffULL) & ~0x3fffULL;
	vm_offset_t v = ml_io_map((vm_offset_t)base, (vm_size_t)len);
	return v ? (volatile uint8_t *)(v + off) : NULL;
}

static void
pin_set(volatile uint8_t *bank, unsigned pin, uint32_t func, int pud, int drv, int dat)
{
	uint32_t sh = pin * 4;
	if (dat >= 0) {
		rmw(bank, G_DAT, 1U << pin, (uint32_t)dat << pin);
	}
	if (pud >= 0) {
		rmw(bank, G_PUD, 0xfU << sh, (uint32_t)pud << sh);
	}
	if (drv >= 0) {
		rmw(bank, G_DRV, 0xfU << sh, (uint32_t)drv << sh);
	}
	rmw(bank, G_CON, 0xfU << sh, func << sh);
}

static void
survey(const char *when)
{
	volatile uint8_t *f = ghsi1 + GPF0, *p = gperic1 + GPP12;
	wlog("%s: pmu iso %08x tcxo %08x | sysreg hs %08x phy %08x nclk %08x | gpf0 con %08x dat %02x pud %08x | gpp12 con %08x dat %02x pud %08x",
	    when, rd(pmu, PMU_PHY_ISO), rd(pmu, PMU_TCXO_FAR), rd(sysr, SYS_PCS_HS), rd(sysr, SYS_PHY_CTRL), rd(sysr, SYS_NCLK),
	    rd(f, G_CON), rd(f, G_DAT) & 0xff, rd(f, G_PUD), rd(p, G_CON), rd(p, G_DAT) & 0xff, rd(p, G_PUD));
}

/* Samsung pcie-exynos2100-v0-cal.c, channel 0, 26 MHz reference, Gen2 */
static const uint8_t cmn_cfg[48] = {
	0x01, 0xE1, 0x05, 0x00, 0x88, 0x88, 0x88, 0x0C, 0x91, 0x45, 0x65, 0x24, 0x33, 0x18, 0xE3, 0xFC,
	0xD8, 0x05, 0xE6, 0x80, 0x00, 0x00, 0x00, 0x00, 0x60, 0x11, 0x01, 0xA0, 0x10, 0x04, 0x27, 0x88,
	0xC0, 0xFF, 0x9B, 0x52, 0x22, 0x30, 0x4F, 0xDC, 0x40, 0x00, 0x00, 0x00, 0x00, 0x0B, 0x00, 0x80,
};
static const uint8_t trsv_cfg[80] = {
	0x31, 0x40, 0x37, 0x99, 0x85, 0x00, 0xC0, 0xFF, 0xFF, 0x3F, 0x8C, 0xC8, 0x02, 0x01, 0x88, 0x80,
	0x06, 0x90, 0x6C, 0x66, 0x09, 0x60, 0x42, 0x48, 0xC8, 0x50, 0x0E, 0x33, 0x58, 0xE7, 0x20, 0x22,
	0x80, 0x38, 0x05, 0x85, 0x00, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x55, 0x15, 0xAC, 0xAA, 0x3E, 0x00,
	0x00, 0x00, 0x20, 0x3F, 0x00, 0x03, 0x40, 0x00, 0x10, 0x07, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x05, 0x85, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00,
};

static void
phy_config(void)
{
	int i;
	rmw(sysr, SYS_PCS_HS, 0, 1U << 1);
	wr(sysr, SYS_PHY_CTRL, (((rd(sysr, SYS_PHY_CTRL) & ~(0xfU << 4)) & ~(0xfU << 2)) | (0x3U << 2)) & ~(1U << 1));
	rmw(sysr, SYS_PHY_CTRL, 0, PCS_LANE0_EN);
	wr(elbi, ELBI_PHY_RST_288, 1); wr(elbi, ELBI_PHY_RST_290, 1); wr(elbi, ELBI_PHY_RST_294, 1); wr(elbi, ELBI_PHY_RST_28C, 1);
	udly(10);
	wr(elbi, ELBI_PHY_RST_288, 0); wr(elbi, ELBI_PHY_RST_290, 0); wr(elbi, ELBI_PHY_RST_294, 0); wr(elbi, ELBI_PHY_RST_28C, 0);
	udly(10);
	wr(elbi, ELBI_PHY_RST_288, 1);
	for (i = 0; i < (int)sizeof(cmn_cfg); i++) {
		wr(phy, (uint32_t)i * 4, cmn_cfg[i]);
	}
	for (i = 0; i < (int)sizeof(trsv_cfg); i++) {
		wr(phy, (uint32_t)(0x30 + i) * 4, trsv_cfg[i]);
	}
	wr(pcs, 0xf8, 0x70);
	wr(pcs, 0x100, 0x87);
	wr(pcs, 0x104, 0x50);
	rmw(pcs, 0x0c, 1U << 1, 1U << 4);
	udly(1000);
	wr(elbi, ELBI_PHY_RST_290, 1); wr(elbi, ELBI_PHY_RST_294, 1); wr(elbi, ELBI_PHY_RST_28C, 1);
	udly(5000);
}

static uint32_t
dbi_pcie_cap(void)
{
	uint32_t p = rd(dbi, DBI_CAP_PTR) & 0xff;
	for (int n = 0; p && n < 48; n++) {
		uint32_t h = rd(dbi, p & ~3U);
		if ((h & 0xff) == 0x10) {
			return p;
		}
		p = (h >> 8) & 0xff;
	}
	return 0;
}

/* dw_pcie_setup_rc() + exynos_pcie_setup_rc() as far as a polled Gen1 x1 link needs */
static void
rc_setup(void)
{
	uint32_t v, cap;
	v = rd(dbi, DBI_PLC);
	v &= ~((1U << 7) | (0x3fU << 16));
	v |= (1U << 5) | (1U << 16);
	wr(dbi, DBI_PLC, v);
	rmw(dbi, DBI_LWS, 0x1fU << 8, 1U << 8);
	rmw(dbi, DBI_MISC1, 0, 1);
	cap = dbi_pcie_cap();
	if (cap) {
		rmw(dbi, cap + 0x0c, 0xf | (0x3fU << 4), 1 | (1U << 4));   /* LNKCAP: Gen1 (DT max-link-speed 1), x1 */
		rmw(dbi, cap + 0x30, 0xf, 1);                               /* LNKCTL2 target speed */
	}
	rmw(dbi, DBI_CLASS_REV, 0xffffff00U, 0x06040000U);
	rmw(dbi, DBI_INTR, 0xff00U, 0x0100U);
	rmw(dbi, DBI_MISC1, 1, 0);
	wr(dbi, DBI_BAR0, 0);
	wr(dbi, DBI_BAR1, 0);
	wr(dbi, DBI_BUSES, 0x00ff0100);
	rmw(dbi, DBI_CMD, 0xffff, 0x0106);
	wr(dbi, DBI_AUX_CLK, 0x1a);
	wr(dbi, DBI_L1SUB, 0xea);
}

static int
atu_out(uint32_t idx, uint32_t type, uint64_t cpu, uint64_t pci, uint64_t size)
{
	wr(dbi, ATU_VIEWPORT, idx);
	wr(dbi, ATU_LBASE, (uint32_t)cpu);
	wr(dbi, ATU_UBASE, (uint32_t)(cpu >> 32));
	wr(dbi, ATU_LIMIT, (uint32_t)(cpu + size - 1));
	wr(dbi, ATU_LTARGET, (uint32_t)pci);
	wr(dbi, ATU_UTARGET, (uint32_t)(pci >> 32));
	wr(dbi, ATU_CR1, type);
	wr(dbi, ATU_CR2, 1U << 31);
	for (int i = 0; i < 5; i++) {
		if (rd(dbi, ATU_CR2) & (1U << 31)) {
			return 0;
		}
		udly(1000);
	}
	return -1;
}

static uint64_t
bar_size(uint32_t reg, bool *wide)
{
	uint32_t old = rd(cfgw, reg), v, hi = 0xffffffffU;
	uint64_t mask;
	*wide = false;
	if (old & 1) {
		return 0;
	}
	wr(cfgw, reg, 0xffffffffU);
	v = rd(cfgw, reg);
	wr(cfgw, reg, old);
	if ((v & ~0xfU) == 0 || v == 0xffffffffU) {
		return 0;
	}
	if (((v >> 1) & 3) == 2) {
		uint32_t oh = rd(cfgw, reg + 4);
		*wide = true;
		wr(cfgw, reg + 4, 0xffffffffU);
		hi = rd(cfgw, reg + 4);
		wr(cfgw, reg + 4, oh);
	}
	mask = (v & ~0xfULL) | ((uint64_t)hi << 32);
	return ~mask + 1;
}

static int
link_once(int attempt)
{
	uint32_t v = 0;
	int i;

	rmw(pcs, 0xec, 1U << 3, 1U << 3);          /* ignore RX electrical idle while the DBI is set up */
	phy_config();
	rmw(elbi, ELBI_SW_WAKE, 1U << 1, 0);        /* bus number enable */
	wr(elbi, ELBI_SOFT_RESET, 0);
	udly(20);
	wr(elbi, ELBI_SOFT_RESET, 1);
	udly(2200);
	pin_set(ghsi1 + GPF0, 1, 1, -1, 3, 1);       /* PERST# released */
	msleep_(20);
	rmw(elbi, ELBI_APP_REQ_L1, 0, (1U << 0) | (1U << 4));
	wr(elbi, ELBI_LINKDOWN_SEL, 1U << 1);
	rmw(elbi, ELBI_QCH_SEL, 0xfff, 0);
	wr(elbi, ELBI_IRQ_EN_PULSE, 0);
	wr(elbi, ELBI_IRQ_EN_LEVEL, 0);
	wr(elbi, ELBI_IRQ_EN_SPECIAL, 0);
	wr(elbi, ELBI_TOE_PULSE2, 0);
	wr(elbi, ELBI_TOE_LEVEL, 0);
	rc_setup();
	rmw(pcs, 0xec, 1U << 3, 0);
	wr(elbi, ELBI_LTSSM_EN, 1);
	for (i = 0; i < 12000; i++) {
		v = rd(elbi, ELBI_RDLH_LINKUP);
		if ((v & 0x1f) == 0x11) {
			wlog("link up (L0) try %d after %d us, raw %08x, PLL %02x", attempt, i * 10, v, rd(phy, 0xbc));
			return 0;
		}
		udly(10);
	}
	wlog("link try %d: LTSSM %02x raw %08x PLL %02x pcs ec %08x", attempt, v & 0x1f, v, rd(phy, 0xbc), rd(pcs, 0xec));
	pin_set(ghsi1 + GPF0, 1, 1, -1, 3, 0);       /* PERST# again before the next try */
	wr(elbi, ELBI_LTSSM_EN, 0);
	msleep_(5);
	return -1;
}

static int
power_and_link(void)
{
	uint32_t id = 0, cls;
	int i;

	/* WLAN_REG_ON (gpp12-2, o1s overlay cfg_wlanen: output, no pull, drive 3), then the chip's power-on time */
	pin_set(gperic1 + GPP12, 2, 1, 0, 3, 1);
	msleep_(200);
	/* pinctrl "active": gpf0-0 CLKREQ (function 2, pull-up), gpf0-1 PERST# (output, drive 3) held low */
	pin_set(ghsi1 + GPF0, 1, 1, -1, 3, 0);
	pin_set(ghsi1 + GPF0, 0, 2, 3, 3, -1);
	rmw(pmu, PMU_TCXO_FAR, 0, 1U << 3);
	rmw(sysr, SYS_NCLK, 1U << 1, 0);             /* exynos_gen4_nclkoff() */
	rmw(pmu, PMU_PHY_ISO, 0, 1);
	survey("powered");
	/* phy_all_pwrdn_clear */
	rmw(sysr, SYS_PHY_CTRL, 0, PCS_LANE0_EN);
	rmw(pcs, 0x100, 1U << 6, 0);
	rmw(pcs, 0x104, 1U << 7, 0);
	wr(phy, 0x20 * 4, 0xc0);
	wr(phy, 0x57 * 4, 0x7e);
	rmw(sysr, SYS_PHY_CTRL, 0, PCS_LANE0_EN);
	udly(100);
	wlog("PHY %02x, elbi linkup %08x, history %08x", rd(phy, 0xbc), rd(elbi, ELBI_RDLH_LINKUP), rd(elbi, ELBI_HISTORY));
	wr(elbi, ELBI_HISTORY, 0);
	wr(elbi, ELBI_HISTORY, 3);
	wr(elbi, ELBI_POWER_S, 0x200000);
	wr(elbi, ELBI_POWER_M, 0xffffffff);
	for (i = 1; i <= 3; i++) {
		if (link_once(i) == 0) {
			break;
		}
	}
	if (i > 3) {
		wlog("W2 FAIL: no link");
		return -1;
	}
	if (atu_out(0, 0x4 /* CFG0 */, PA_CFG, 1ULL << 24, 0x1000) || atu_out(1, 0x0 /* MEM */, PA_MEM, PA_MEM, SZ_MEM)) {
		wlog("W2 FAIL: iATU");
		return -1;
	}
	msleep_(100);
	for (i = 0; i < 100; i++) {
		id = rd(cfgw, 0x00);
		if (id != 0xffffffffU && (id & 0xffff) != 0x0001) {
			break;
		}
		msleep_(10);
	}
	cls = rd(cfgw, 0x08);
	wlog("endpoint %04x:%04x (want 14e4:4475) class %06x rev %02x subsys %08x", id & 0xffff, id >> 16, cls >> 8, cls & 0xff,
	    rd(cfgw, 0x2c));
	if (id != 0x447514e4U) {
		return -1;
	}
	bus.bar0_size = bar_size(0x10, &bus.bar0_wide);
	bus.bar2_size = bar_size(0x18, &bus.bar2_wide);
	wlog("W2 PASS: BAR0 %llu KB%s BAR2 %llu KB%s", bus.bar0_size >> 10, bus.bar0_wide ? " 64-bit" : "",
	    bus.bar2_size >> 10, bus.bar2_wide ? " 64-bit" : "");
	return 0;
}

static uint64_t
hvc5(uint64_t f, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4)
{
	register uint64_t x0 __asm__("x0") = f;
	register uint64_t x1 __asm__("x1") = a1;
	register uint64_t x2 __asm__("x2") = a2;
	register uint64_t x3 __asm__("x3") = a3;
	register uint64_t x4 __asm__("x4") = a4;
	__asm__ volatile ("dsb sy\n\thvc #0\n\tdsb sy" : "+r"(x0), "+r"(x1), "+r"(x2), "+r"(x3), "+r"(x4) : :
	    "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17", "cc", "memory");
	return x0;
}

static int
dma_pool(void)
{
	uint64_t at, r, first = 0;
	unsigned ok = 0, bad = 0;
	for (at = 0; at < POOL_SIZE; at += S2MPU_GRANULE) {
		r = hvc5(S2MPU_HVC, S2MPU_PCIE_GEN2, POOL_PHYS + at, S2MPU_GRANULE, S2MPU_RW);
		if (r == 0) {
			ok++;
		} else {
			if (!bad) {
				first = r;
			}
			bad++;
			if (bad >= 4) {
				break;
			}
		}
	}
	bus.pool_phys = POOL_PHYS;
	bus.pool_mapped = POOL_SIZE;
	bus.pool_virt = ml_io_map_unmappable((vm_offset_t)POOL_PHYS, (vm_size_t)POOL_SIZE, VM_WIMG_WCOMB);
	wlog("W3 %s: pool %llx size %llx mapped %lx: %u granted, %u refused (first answer %llx)", bad ? "FAIL" : "PASS",
	    POOL_PHYS, POOL_SIZE, (unsigned long)bus.pool_virt, ok, bad, first);
	return bad || !bus.pool_virt ? -1 : 0;
}

static uint32_t wifi_level;

static void
wifi_thread(void *arg, wait_result_t wr_)
{
	uint32_t wait_s = 2;
	(void)arg; (void)wr_;
	PE_parse_boot_argn("sweetwifi_wait", &wait_s, sizeof(wait_s));
	if (wait_s > 120) {
		wait_s = 120;
	}
	delay((int)(wait_s * 1000000));
	elbi = mapr(PA_ELBI, 0x1000);
	phy = mapr(PA_PHY, 0x1000);
	sysr = mapr(PA_SYSREG_PG, 0x100);
	dbi = mapr(PA_DBI, 0x1000);
	pcs = mapr(PA_PCS, 0x200);
	cfgw = mapr(PA_CFG, 0x2000);
	pmu = mapr(PA_PMU, 0x4000);
	ghsi1 = mapr(PA_GPIO_HSI1, 0x100);
	gperic1 = mapr(PA_GPIO_PERIC1, 0x100);
	if (!elbi || !phy || !sysr || !dbi || !pcs || !cfgw || !pmu || !ghsi1 || !gperic1) {
		wlog("map failed");
		return;
	}
	survey("S-Boot left");
	if (wifi_level < 2 || power_and_link() != 0) {
		wlog("done at level %u", wifi_level);
		return;
	}
	if (wifi_level < 3 || dma_pool() != 0) {
		wlog("done at level %u", wifi_level);
		return;
	}
	if (wifi_level < 4) {
		wlog("done at level %u", wifi_level);
		return;
	}
	for (int i = 0; i < 600 && rootvnode == NULLVP; i++) {
		delay(100000);
	}
	bus.cfg = cfgw;
	bus.dbi = dbi;
	bus.mem_phys = PA_MEM;
	bus.mem_size = SZ_MEM;
	wlog("W4: chip driver (z3sios redwood_bcm4375), root %s", rootvnode ? "mounted" : "missing");
	redwood_bcm4375_run(&bus);
}

int
sweet_wifi_start(void)
{
	static int started;
	thread_t th;
	if (started) {
		return 0;
	}
	started = 1;
	PE_parse_boot_argn("sweetwifi", &wifi_level, sizeof(wifi_level));
	if (!wifi_level) {
		return 0;
	}
	wlog("start, level %u", wifi_level);
	if (kernel_thread_start(wifi_thread, NULL, &th) == KERN_SUCCESS) {
		thread_deallocate(th);
	}
	return 0;
}
#endif /* ARM64_BOARD_CONFIG_SWEET */
EOF_SWEET_SRC

for f in sweet_wifi.c redwood_bcm4375.c redwood_sta.c redwood_net.c redwood_apple80211.c lx_wpa.c; do
	grep -q "bsd/dev/$f" bsd/conf/files || printf 'bsd/dev/%s\t\tstandard\n' "$f" >> bsd/conf/files
done
