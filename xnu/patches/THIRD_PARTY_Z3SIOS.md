# N1709/z3sios (Wi-Fi)

`0142-s21-wifi.sh` fetches these files unmodified from https://github.com/N1709/z3sios at commit
`1323aa51d4c16816fa8fd95309f864f7e3888793` (checked by SHA-256) and builds them into the S21 kernel:

- `kernel/xnu/files/bsd/dev/redwood_bcm4375.c` - BCM4375 PCIe msgbuf driver (follows Linux brcmfmac, ISC)
- `kernel/xnu/files/bsd/dev/redwood_sta.c`, `bsd/sys/redwood_sta.h` - the station boundary
- `kernel/xnu/files/bsd/dev/redwood_net.c`, `bsd/sys/redwood_net.h` - en0 through the BSD interface KPI
- `kernel/xnu/files/bsd/dev/redwood_apple80211.c` - Apple80211 ioctls and events for wifid
- `kernel/xnu/files/bsd/dev/lx_wpa.c`, `lx_wpa.h` - the WPA2 four-way and group-key handshakes
- `kernel/xnu/files/bsd/sys/redwood_input.h` - declarations only
- `kernel/xnu/files/iokit/Kernel/RedwoodWLAN.cpp` - the IOKit objects iOS finds the interface by (appended to
  SweetMali.cpp, its `publish` helper renamed `rw_publish`)

z3sios is MIT licensed (Copyright (c) 2026 the y2sios contributors); its XNU-derived files are under the Apple Public
Source License 2.0 and its brcmfmac-derived code under the ISC licence, as its NOTICE.md says. The S21-specific part
(`bsd/dev/sweet_wifi.c`: Exynos 2100 PCIe link, S2MPU grants, firmware loading from the root) is this repository's.
Firmware, CLM and NVRAM come from the user's own phone at install time and are never in this repository.
