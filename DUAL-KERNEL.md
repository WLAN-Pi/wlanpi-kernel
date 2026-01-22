# Conditional kernel support for Pi 4 and Pi 5

## Overview

The WLAN Pi kernel build system creates **three separate kernel packages** to support different deployment scenarios:

1. **`wlanpi-kernel-bookworm-pi4`** - Pi 4/CM4 only (space-optimized for 8GB eMMC)
2. **`wlanpi-kernel-bookworm-pi5`** - Pi 5 only
3. **`wlanpi-kernel-bookworm`** - Unified package with both kernels (for systems with ample storage)

This conditional packaging approach allows WLAN Pi to optimize for both **space-constrained deployments** (wlanpi1-lite on 8GB eMMC) and **unified multi-platform deployments** (wlanpi2-full on 32GB+ SD cards).

## Why dual kernels?

**The Problem:** Raspberry Pi 4 and Pi 5 use different page sizes:

- **Pi 4 (BCM2711):** Uses 4KB page size (`CONFIG_ARM64_4K_PAGES`)
- **Pi 5 (BCM2712):** Uses 16KB page size (`CONFIG_ARM64_16K_PAGES`)

These are **binary incompatible** - a kernel compiled for one page size cannot boot on hardware expecting a different page size. Therefore, we must build and ship separate kernels for each platform.

## Architecture

### Kernel images

The package includes two kernel images:

| Hardware | Kernel Image | Config Base | Page Size | Local Version |
|----------|--------------|-------------|-----------|---------------|
| Pi 4, CM4 | `wlanpi-kernel8.img` | `bcm2711_defconfig` + `wlanpi_v8_defconfig` | 4KB | `-v8-wlanpi` |
| Pi 5 | `wlanpi-kernel_2712.img` | `bcm2712_defconfig` + `wlanpi_2712_defconfig` | 16KB | `-2712-wlanpi` |

### Automatic kernel selection

**The Raspberry Pi boot firmware automatically selects the correct kernel based on detected hardware:**

1. Firmware reads `/boot/firmware/config.txt`
2. Firmware detects hardware platform (BCM2711 vs BCM2712)
3. For **Pi 4/CM4:** Firmware loads `wlanpi-kernel8.img`
4. For **Pi 5:** Firmware loads `wlanpi-kernel_2712.img` (firmware override)

**No manual configuration required** - the firmware handles this transparently.

### Package structure

**Three kernel packages created:**

```
# Pi 4 only package (space-optimized)
wlanpi-kernel-bookworm-pi4_<version>_arm64.deb
├── /usr/local/lib/wlanpi-kernel/boot/firmware/
│   ├── wlanpi-kernel8.img              # Pi 4 kernel only
│   ├── *.dtb                           # Device Tree Blobs
│   └── overlays/*.dtbo                 # Device Tree overlays
└── /lib/modules/
    └── 6.17.y-v8-wlanpi/               # Pi 4 modules only

# Pi 5 only package
wlanpi-kernel-bookworm-pi5_<version>_arm64.deb
├── /usr/local/lib/wlanpi-kernel/boot/firmware/
│   ├── wlanpi-kernel_2712.img          # Pi 5 kernel only
│   ├── *.dtb                           # Device Tree Blobs
│   └── overlays/*.dtbo                 # Device Tree overlays
└── /lib/modules/
    └── 6.17.y-2712-wlanpi/             # Pi 5 modules only

# Unified dual kernel package
wlanpi-kernel-bookworm_<version>_arm64.deb
├── /usr/local/lib/wlanpi-kernel/boot/firmware/
│   ├── wlanpi-kernel8.img              # Pi 4 kernel
│   ├── wlanpi-kernel_2712.img          # Pi 5 kernel
│   ├── *.dtb                           # Device Tree Blobs (shared)
│   └── overlays/*.dtbo                 # Device Tree overlays (shared)
└── /lib/modules/
    ├── 6.17.y-v8-wlanpi/               # Pi 4 modules
    └── 6.17.y-2712-wlanpi/             # Pi 5 modules
```

**Two separate headers packages:**

- `wlanpi-kernel-headers-bookworm-pi4_<version>_arm64.deb` (~9MB)
- `wlanpi-kernel-headers-bookworm-pi5_<version>_arm64.deb` (~9MB)

## Which package should I use?

### Package selection guide

| Deployment Scenario | Package | Installed Size | Rationale |
|---------------------|---------|----------------|-----------|
| **wlanpi1-lite** (8GB eMMC, dual-partition) | `wlanpi-kernel-bookworm-pi4` | 60 MB | Space-optimized for CM4 with constrained storage |
| **wlanpi1-full** (32GB+ SD card) | `wlanpi-kernel-bookworm` | 115 MB | Unified image boots on both Pi 4 and Pi 5 |
| **Pi 5 only** | `wlanpi-kernel-bookworm-pi5` | 60 MB | Pi 5 specific |
| **Pi 4 only** | `wlanpi-kernel-bookworm-pi4` | 60 MB | Pi 4 specific |

### In pi-gen-bookworm

The image build automatically installs the appropriate package:

**wlanpi1-lite** (`/05-kernel/00-packages`):
```
wlanpi-kernel-bookworm-pi4
```

**wlanpi2-full** (`/05-kernel/00-packages`):
```
wlanpi-kernel-bookworm
```

This ensures:

- Lite image stays under 8GB eMMC constraints
- Full image boots on both Pi 4 and Pi 5 hardware

## Building

### Build script

Use the new dual kernel build script:

```bash
./build-kernel-dual.sh
```

### Build process

The script performs the following steps:

1. **Clone/update kernel source** from raspberrypi/linux (rpi-6.17.y branch)

2. **Build Pi 4 kernel (bcm2711):**

   - Load `bcm2711_defconfig`
   - Merge `wlanpi_v8_defconfig` (WLAN Pi customizations)
   - Apply patches
   - Build kernel image, modules, DTBs
   - Install modules to `lib/modules/<version>-v8-wlanpi/`
   - Generate kernel headers

3. **Build Pi 5 kernel (bcm2712):**

   - Clean build tree (`make mrproper`)
   - Load `bcm2712_defconfig`
   - Merge `wlanpi_2712_defconfig` (WLAN Pi customizations + 16KB page config)
   - Build kernel image, modules, DTBs
   - Install modules to `lib/modules/<version>-2712-wlanpi/`
   - Generate kernel headers

4. **Create three kernel packages:**

   - **Pi 4 only:** `wlanpi-kernel-bookworm-pi4` (kernel8.img + Pi 4 modules)
   - **Pi 5 only:** `wlanpi-kernel-bookworm-pi5` (kernel_2712.img + Pi 5 modules)
   - **Unified:** `wlanpi-kernel-bookworm` (both kernels + both module sets)
   - All packages include shared DTBs and overlays
   - Each has appropriate postinst script for installation

5. **Create headers packages:**

   - Separate packages for Pi 4 and Pi 5 headers
   - Allows building kernel modules for either platform

### wlanpi_v8_defconfig (Pi 4)

Custom WLAN Pi kernel configuration for Pi 4:

- Based on `bcm2711_defconfig` (4KB pages, 39-bit VA)
- WLAN Pi-specific drivers and options
- WiFi adapter support (Atheros, Intel, MediaTek, Realtek)
- Bluetooth drivers
- GPIO sysfs support

### wlanpi_2712_defconfig (Pi 5)

Custom WLAN Pi kernel configuration for Pi 5:

- Based on `bcm2712_defconfig` (16KB pages, 47-bit VA)
- Same WLAN Pi-specific drivers as Pi 4 config
- Compatible with Pi 5 hardware architecture
- Key differences from Pi 4 config:
  - `CONFIG_ARM64_16K_PAGES=y` (instead of 4KB)
  - `CONFIG_ARM64_VA_BITS_47=y` (instead of 39-bit)
  - `CONFIG_LOCALVERSION="-2712-wlanpi"` (instead of `-v8-wlanpi`)

## Installation

### On target system

**For space-constrained systems (8GB eMMC):**

```bash
sudo dpkg -i wlanpi-kernel-bookworm-pi4_<version>_arm64.deb
```

**For systems with ample storage (32GB+ SD cards):**

```bash
sudo dpkg -i wlanpi-kernel-bookworm_<version>_arm64.deb
```

**For Pi 5 only systems:**

```bash
sudo dpkg -i wlanpi-kernel-bookworm-pi5_<version>_arm64.deb
```

Optionally install headers for your platform:

```bash
# For Pi 4/CM4:
sudo dpkg -i wlanpi-kernel-headers-bookworm-pi4_<version>_arm64.deb

# For Pi 5:
sudo dpkg -i wlanpi-kernel-headers-bookworm-pi5_<version>_arm64.deb
```

The postinst script will:

1. Copy appropriate kernel image(s) to `/boot/firmware/`
2. Copy DTBs and overlays to `/boot/firmware/`
3. Update `/boot/firmware/config.txt` with kernel directive
4. Add comments about kernel configuration

**Reboot to use the new kernel.** The firmware will automatically load the correct kernel for your hardware (for dual-kernel package).

### In pi-gen image build

The pi-gen-bookworm stages install the appropriate package for each image:

**wlanpi1-lite** (`05-kernel/00-packages`):

```
wlanpi-kernel-bookworm-pi4
```
- Installs: 60 MB
- Target: CM4 with 8GB eMMC (space-constrained)
- Boots on: Pi 4, CM4 only

**wlanpi2-full** (`05-kernel/00-packages`):

```
wlanpi-kernel-bookworm
```

- Installs: 115 MB
- Target: Pi 4/5 with 32GB+ SD card
- Boots on: Pi 4, CM4, Pi 5 (unified)

## Verification

### Check installed kernels

```bash
ls -lh /boot/firmware/wlanpi-kernel*.img
```

Expected output:
```
-rw-r--r-- 1 root root 29M Jan 20 12:00 /boot/firmware/wlanpi-kernel8.img
-rw-r--r-- 1 root root 29M Jan 20 12:00 /boot/firmware/wlanpi-kernel_2712.img
```

### Check loaded kernel

After booting, verify which kernel is running:

```bash
uname -r
```

Expected output:
- On Pi 4/CM4: `6.17.y-v8-wlanpi`
- On Pi 5: `6.17.y-2712-wlanpi`

### Check module directories

```bash
ls /lib/modules/
```

Expected output:
```
6.17.y-v8-wlanpi/
6.17.y-2712-wlanpi/
```

## Maintenance

### Updating custom configs

When updating WLAN Pi-specific kernel configurations:

**For changes affecting both platforms:**

1. Update both `wlanpi_v8_defconfig` and `wlanpi_2712_defconfig`
2. Ensure consistency between the two configs (except page size settings)

**For Pi 4-specific changes:**

1. Only update `wlanpi_v8_defconfig`

**For Pi 5-specific changes:**

1. Only update `wlanpi_2712_defconfig`

### Kernel version updates

When updating the kernel version (e.g., from rpi-6.17.y to rpi-6.18.y):

1. Update `KERNEL_BRANCH` in `build-kernel-dual.sh`
2. Verify both `bcm2711_defconfig` and `bcm2712_defconfig` still exist upstream
3. Test build both kernels
4. Test boot on both Pi 4 and Pi 5 hardware (if available)

### Troubleshooting build issues

**Issue: "bcm2712_defconfig not found"**

- Solution: Ensure kernel source is from a recent enough branch

**Issue: Build fails on second kernel (bcm2712)**

- Solution: Check for patches that assume bcm2711 config - may need conditional patch application

**Issue: Module conflicts between kernel versions**

- Solution: Ensure module directories use full kernel version (including localversion suffix)

## Upstream alignment

This conditional kernel packaging approach provides flexibility similar to Raspberry Pi OS:

| Raspberry Pi OS | WLAN Pi Equivalent | Purpose |
|----------------|-------------------|---------|
| `linux-image-rpi-v8` | `wlanpi-kernel-bookworm-pi4` | Pi 4/CM4 kernel only |
| `linux-image-rpi-2712` | `wlanpi-kernel-bookworm-pi5` | Pi 5 kernel only |
| Both installed | `wlanpi-kernel-bookworm` | Unified package (both in one) |

**Key difference:** WLAN Pi offers three package options to accommodate both space-constrained (8GB eMMC) and unified (32GB+ SD) deployment scenarios, whereas upstream expects users to install both packages separately.

## References

- Raspberry Pi kernel documentation: https://github.com/raspberrypi/linux
- Raspberry Pi OS kernel packages: `linux-image-rpi-v8`, `linux-image-rpi-2712`
- Page size differences: BCM2711 (4KB) vs BCM2712 (16KB)
- Firmware kernel selection: Automatic based on hardware detection

