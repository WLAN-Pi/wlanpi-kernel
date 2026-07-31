# WLAN Pi kernel

This repository contains build scripts and configurations for the **WLAN Pi** custom Linux kernel, supporting both Raspberry Pi 4/CM4 and Raspberry Pi 5 hardware platforms.

## Building kernels

### Local build

The build script supports building kernels for different hardware variants:

```bash
./build-kernel.sh           # Build both v8 (Pi 4) and 2712 (Pi 5) kernels (default)
./build-kernel.sh v8        # Build only Pi 4/CM4 kernel (v8, 4KB pages)
./build-kernel.sh 2712      # Build only Pi 5 kernel (2712, 16KB pages)
```

**Debian release:**

```bash
# Default: Debian Trixie
./build-kernel.sh

# Explicitly target Debian Trixie
DEBIAN_RELEASE=trixie ./build-kernel.sh
DEBIAN_RELEASE=trixie ./build-kernel.sh v8
```

**Requirements:**
- Cross-compilation toolchain: `gcc-aarch64-linux-gnu`
- Build dependencies: `build-essential`, `git`, `libncurses-dev`, `flex`, `bison`, `libssl-dev`, etc.

**Output packages:**

When building **v8** only (for Trixie):
- `wlanpi-kernel-trixie-v8_*.deb`
- `wlanpi-kernel-headers-trixie-v8_*.deb`

When building **2712** only (for Trixie):
- `wlanpi-kernel-trixie-2712_*.deb`
- `wlanpi-kernel-headers-trixie-2712_*.deb`

When building **both** (for Trixie):
- All of the above, PLUS
- `wlanpi-kernel-trixie_*.deb` - Unified dual-kernel package for universal images

### CI/CD build with GitHub actions

The repository includes automated builds via GitHub Actions:

**Automatic builds:** Triggered on push to branch (builds both kernels by default)

**Manual builds:** 
1. Go to **Actions** → **Build WLAN Pi Kernel for Debian Trixie**
2. Click **"Run workflow"**
3. Select kernel variant: `both`, `v8`, or `2712`
4. Click **"Run workflow"** button

Built packages are uploaded as separate artifacts per variant for easy download.

## Kernel variants

- **v8** (Pi 4/CM4): 4KB page size, `CONFIG_ARM64_4K_PAGES`, uses `bcm2711_defconfig`
- **2712** (Pi 5): 16KB page size, `CONFIG_ARM64_16K_PAGES`, uses `bcm2712_defconfig`
- **Dual package**: Contains both kernels, firmware auto-selects based on hardware

See [DUAL-KERNEL.md](DUAL-KERNEL.md) for detailed information about the dual-kernel packaging approach.

## Quick start

1. **Clone the Repository:**
   ```bash
   git clone https://github.com/WLAN-Pi/wlanpi-kernel.git
   cd wlanpi-kernel
   ```

2. **Build kernels:**
   ```bash
   ./build-kernel.sh
   ```

3. **Install on target device:**
   ```bash
   # For Pi 4/CM4:
   sudo dpkg -i output/wlanpi-kernel-trixie-v8_*.deb

   # For Pi 5:
   sudo dpkg -i output/wlanpi-kernel-trixie-2712_*.deb

   # For universal image (works on both):
   sudo dpkg -i output/wlanpi-kernel-trixie_*.deb
   ```
