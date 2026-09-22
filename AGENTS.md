# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## What this repo is

Build scripts and configuration for cross-compiling a custom Linux kernel for WLAN Pi devices (Raspberry Pi 4/CM4 and Pi 5). The output is installable Debian packages, not a kernel source tree — the actual kernel source is cloned from `raspberrypi/linux` at build time into a `linux/` directory.

## Build commands

```bash
# Build both kernel variants (default)
./build-kernel.sh

# Build Pi 4/CM4 kernel only (v8, 4KB pages)
./build-kernel.sh v8

# Build Pi 5 kernel only (2712, 16KB pages)
./build-kernel.sh 2712

# Target Debian Bookworm instead of the default Trixie
DEBIAN_RELEASE=bookworm ./build-kernel.sh

# Via environment variable (CI style)
BUILD_TARGET=v8 ./build-kernel.sh
```

`DEBIAN_RELEASE` defaults to `trixie`. Build output lands in `output/`. A `build_kernel.log` is written alongside. The `linux/` kernel source directory is cached between builds; `make mrproper` is run between the v8 and 2712 builds.

**Required tools:** `gcc-aarch64-linux-gnu`, `build-essential`, `git`, `libncurses-dev`, `flex`, `bison`, `libssl-dev`, `bc`, `libelf-dev`, `dpkg-dev`

## Architecture

### Two kernel variants, three packages

Pi 4 (BCM2711) uses 4KB pages; Pi 5 (BCM2712) uses 16KB pages — they are binary incompatible. The build produces (names use `$DEBIAN_RELEASE`, `trixie` by default):

| Package | Contents | Use case |
|---------|----------|----------|
| `wlanpi-kernel-trixie-v8` | Pi 4 kernel only | wlanpi1-lite (8GB eMMC, space-constrained) |
| `wlanpi-kernel-trixie-2712` | Pi 5 kernel only | Pi 5-only deployments |
| `wlanpi-kernel-trixie` | Both kernels | wlanpi2-full (32GB+ SD, boots either hardware) |

Plus separate `wlanpi-kernel-headers-trixie-v8` and `wlanpi-kernel-headers-trixie-2712` packages.

For the unified dual package, the Raspberry Pi firmware auto-selects the correct kernel at boot based on hardware detection — no manual config needed.

### Kernel customization

Each variant starts from an upstream Raspberry Pi defconfig, then merges WLAN Pi-specific options:

- **Pi 4:** `bcm2711_defconfig` + `wlanpi_v8_defconfig` → `wlanpi-kernel8.img`, local version `-v8-wlanpi`
- **Pi 5:** `bcm2712_defconfig` + `wlanpi_2712_defconfig` → `wlanpi-kernel_2712.img`, local version `-2712-wlanpi`

The `wlanpi_*_defconfig` files in this repo are fragment configs (merged via `scripts/kconfig/merge_config.sh`), not full defconfigs. They add WiFi adapter support (Atheros, Intel, MediaTek, Realtek), Bluetooth drivers, and GPIO sysfs.

Key differences between the two configs: `CONFIG_ARM64_16K_PAGES`, `CONFIG_ARM64_VA_BITS_47`, and `CONFIG_LOCALVERSION` differ; everything else should stay in sync.

### Patches

The `patches/` directory contains patches applied to the kernel source before each build:

- `0001-MAX3421_NAK_fix_and_shutdown_crash.patch` — fixes NAK retry storm and a spinlock ordering crash in the MAX3421 USB host driver
- `ath12k-0001` … `ath12k-0036` — pending ath12k fixes for WCN7850/WCN7851 (QCN7851 modules), each one a commit from `ath/ath-next` that has not reached rpi-7.2.y: RX monitor TLV bounds check, monitor-mode rx_status handling, monitor destination ring size, MLO peer delete race, `dp_link_peer` dangling references, the MLO peer-ID series (`host_alloc_ml_id`, `MLO_PEER_MAP` handling, deferred `dp_peer` registration), survey indexing across bands, CSA event overreads, encrypted EAPOL TX in encap offload mode, threaded NAPI without DP IRQ affinity, REOQ LUT reset before firmware stop, WCN7850 MAC buffer ring 4096, RX SRNG interrupt timer 200 µs, WMI scan hint-BSSID copy, WMI rx/TPC-stats overread guards, `mac_phy_caps_parse` stride, the regd/country-code series (`regd_update_completed` signalling, per-radio `ab`, `new_alpha2` locking, skip-unchanged country), channel-pointer cleanup on error, the wifi7 TX descriptor trio (DMA unwind on ext-MSDU retry, stale skb pointers after payload shift, truncated >32-bit DMA address), CE/external IRQ release on `request_irq()` failure, and PPDU state across monitor status buffers. Filenames carry the upstream numbering. The gaps (`0004`–`0017`, `0022`–`0025`) are already upstream in rpi-7.2.y, so they are intentionally absent; `0005` is likewise absent (already in rpi-7.1.y). Every patch keeps its upstream commit SHA in the `From` line — verify provenance by fetching `https://git.kernel.org/pub/scm/linux/kernel/git/ath/ath.git` and checking the SHA exists. `ath12k-0001` is hand-adapted for rpi-7.2.y (its trailer explains why: 7.2 predates the 32-bit TLV header series). `ath12k-0032` carries the full upstream form here because rpi-7.2.y (unlike 7.1) includes the multicast Ethernet encapsulation offload commit that introduces the `eth` variable. `ath12k-0018-genirq-…` is the one-line `irq_can_set_affinity()` export from ath-next that `ath12k-0018-wifi-…` needs (same number so it sorts first)
- `ath12k-wlanpi-disable-aspm-wcn7850.patch` — WLAN Pi local patch (not from ath-next): sets `supports_aspm = false` for `wcn7850 hw2.0` so ath12k never restores PCIe ASPM L0s/L1 after firmware boot. On the BCM2711 bridge the card stops delivering events once ASPM is re-enabled (WMI credit timeouts, country 00, no scan/capture). Re-derive on every kernel bump; the hunk lives in `wifi7/hw.c` next to the WCN7850 `hw_params`
- `iwlwifi-enable-320mhz.patch` — forces `slow_pcie = false` in the Intel iwlwifi driver to enable 320 MHz EHT channels regardless of PCIe link speed

Patches are applied in filename order with `patch -p1 --ignore-whitespace -N`, **once on the shared source tree after checkout and before any variant is built**, so the `v8`, `2712`, and `both` targets are all patched. A failed hunk fails the build: the script counts failures and exits non-zero. Re-verify every patch by hand after a kernel version bump. GNU `patch` also drops `<file>.orig` backups whenever a hunk applies with an offset; those are harmless to the build but must not be captured into new patch files.

### Package installation

The `postinst` script in each generated package:
1. Copies kernel image(s) to `/boot/firmware/` (supports both `/boot` and `/boot/firmware` layouts)
2. Copies DTBs and overlays to `/boot/firmware/`
3. Updates `/boot/firmware/config.txt` with the appropriate `kernel=` directive

### CI

GitHub Actions (`.github/workflows/build-and-archive-kernel-package.yml`) runs on `ubuntu-24.04-arm` and triggers on pushes to `7.2-trixie` that touch `patches/`, `wlanpi_*_defconfig`, or `build-kernel*.sh`. Artifacts are uploaded per variant. Slack notifications go to the WLAN-Pi org webhook on completion.

## Updating the kernel version

When bumping to a new kernel branch (e.g., `rpi-7.3.y`):
1. Update `KERNEL_BRANCH` in `build-kernel.sh`
2. Verify `bcm2711_defconfig` and `bcm2712_defconfig` still exist in that branch
3. Re-check every patch: drop the ones now upstream and re-adapt the local ones
4. Test boot on both Pi 4 and Pi 5
