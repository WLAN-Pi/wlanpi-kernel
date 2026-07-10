#!/bin/bash

# Build script for cross-compiling and packaging Linux kernels for Raspberry Pi
# Supports: Pi 4/CM4 (v8, 4KB pages) and Pi 5 (2712, 16KB pages)
# Target: ARM64, Distribution: Debian Bookworm/Trixie
# Authors: Jerry Olla <jerryolla@gmail.com>, Josh Schmelzle <josh@joshschmelzle.com>
#
# Usage: ./build-kernel.sh [TARGET]
#
# TARGET options:
#   v8|rpi4      - Build only Pi 4/CM4 kernel (v8, 4KB pages)
#   2712|rpi5    - Build only Pi 5 kernel (2712, 16KB pages)
#   both|all     - Build both kernels (default)
#
# Environment variables:
#   BUILD_TARGET    - Same as TARGET argument (env overrides CLI arg)
#   DEBIAN_RELEASE  - Target Debian release: trixie (default), bookworm
#   CI              - Set to 'true' to indicate CI environment
#
# Examples:
#   ./build-kernel.sh              # Build both kernels for trixie
#   ./build-kernel.sh v8           # Build v8 only for trixie
#   BUILD_TARGET=2712 ./build-kernel.sh  # Build 2712 via env var
#   DEBIAN_RELEASE=trixie ./build-kernel.sh  # Build for Trixie
#   DEBIAN_RELEASE=trixie ./build-kernel.sh v8  # Build v8 for Trixie

set -euo pipefail  # Enable strict error handling

# Debian release selection (for local testing of different releases)
DEBIAN_RELEASE="${DEBIAN_RELEASE:-trixie}"

# Support both CLI args and environment variables (env takes precedence for CI)
BUILD_TARGET="${BUILD_TARGET:-${1:-both}}"

case "$BUILD_TARGET" in
    v8|pi4|rpi4)
        BUILD_PI4=true
        BUILD_PI5=false
        ;;
    2712|pi5|rpi5)
        BUILD_PI4=false
        BUILD_PI5=true
        ;;
    both|all|dual)
        BUILD_PI4=true
        BUILD_PI5=true
        ;;
    *)
        echo "Usage: $0 [v8|2712|both]"
        echo ""
        echo "Arguments:"
        echo "  v8|rpi4    - Build only Pi 4/CM4 kernel (v8, 4KB pages)"
        echo "  2712|rpi5  - Build only Pi 5 kernel (2712, 16KB pages)"
        echo "  both|all   - Build both kernels (default)"
        echo ""
        echo "Environment variables:"
        echo "  BUILD_TARGET    - Override target selection (for CI)"
        echo "  DEBIAN_RELEASE  - Target Debian release: trixie (default), bookworm"
        echo ""
        echo "Examples:"
        echo "  DEBIAN_RELEASE=trixie ./build-kernel.sh v8"
        echo ""
        exit 1
        ;;
esac

# Validate DEBIAN_RELEASE
case "$DEBIAN_RELEASE" in
    bookworm|trixie)
        echo "Building for Debian release: $DEBIAN_RELEASE"
        ;;
    *)
        echo "ERROR: Invalid DEBIAN_RELEASE '$DEBIAN_RELEASE'"
        echo "Supported releases: bookworm, trixie"
        exit 1
        ;;
esac

# Enable detailed logging (unbuffered)
LOG_FILE="build_kernel.log"
exec > >(stdbuf -oL tee "$LOG_FILE") 2>&1

# Track build timing
BUILD_START_TIME=$(date +%s)
BUILD_START_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')
echo "========================================"
if [ "$BUILD_PI4" = true ] && [ "$BUILD_PI5" = true ]; then
    echo "Kernel Build Started (Pi 4 + Pi 5)"
elif [ "$BUILD_PI4" = true ]; then
    echo "Kernel Build Started (Pi 4 only)"
else
    echo "Kernel Build Started (Pi 5 only)"
fi
echo "========================================"
echo ""
echo "Started at: ${BUILD_START_TIMESTAMP}"
echo "========================================"
echo ""

# Determine the directory where the script resides
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check required tools
echo "Checking for required tools..."
MISSING_TOOLS=()
for tool in git make gcc aarch64-linux-gnu-gcc patch dpkg-deb; do
    if ! command -v "$tool" &> /dev/null; then
        MISSING_TOOLS+=("$tool")
    fi
done

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    echo "ERROR: The following required tools are missing:"
    printf '  - %s\n' "${MISSING_TOOLS[@]}"
    echo ""
    echo "Please install the missing tools and try again."
    exit 1
fi
echo "All required tools found."
echo ""

# Configuration Variables
KERNEL_REPO="https://github.com/raspberrypi/linux.git"
KERNEL_BRANCH="rpi-7.1.y"
KERNEL_SRC_DIR="$BASE_DIR/linux"
OUTPUT_PATH="$BASE_DIR/output"
CROSS_COMPILE="aarch64-linux-gnu-"
ARCH="arm64"
PATCHES_DIR="$BASE_DIR/patches"
NUM_CORES=$(nproc)

# Pi 4 (bcm2711) Configuration
BCM2711_BASE_CONFIG="bcm2711_defconfig"
BCM2711_CUSTOM_CONFIG="$BASE_DIR/wlanpi_v8_defconfig"
BCM2711_KERNEL_IMAGE="wlanpi-kernel8.img"

# Pi 5 (bcm2712) Configuration
BCM2712_BASE_CONFIG="bcm2712_defconfig"
BCM2712_CUSTOM_CONFIG="$BASE_DIR/wlanpi_2712_defconfig"
BCM2712_KERNEL_IMAGE="wlanpi-kernel_2712.img"

# Output directories
DTB_OUTPUT_DIR="$OUTPUT_PATH/boot/firmware/"
DTBO_OUTPUT_DIR="$OUTPUT_PATH/boot/firmware/overlays/"
MODULES_OUTPUT_DIR="$OUTPUT_PATH/lib/modules"
HEADERS_OUTPUT_DIR="$OUTPUT_PATH/linux-headers"

# Debian Package Metadata (using DEBIAN_RELEASE)
PACKAGE_NAME_V8="wlanpi-kernel-${DEBIAN_RELEASE}-v8"
PACKAGE_NAME_2712="wlanpi-kernel-${DEBIAN_RELEASE}-2712"
PACKAGE_NAME_DUAL="wlanpi-kernel-${DEBIAN_RELEASE}"
HEADERS_PACKAGE_NAME="wlanpi-kernel-headers-${DEBIAN_RELEASE}"

# Trap for error handling and timing
TERM_CALLED=false

term() {
	# Prevent double-execution when both ERR and EXIT traps fire
	if [ "$TERM_CALLED" = true ]; then
		return
	fi
	TERM_CALLED=true

	EXIT_CODE=$?
	if [ "$EXIT_CODE" -ne 0 ]; then
		BUILD_FAIL_TIME=$(date +%s)
		BUILD_FAIL_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')
		if [ -n "${BUILD_START_TIME}" ]; then
			BUILD_FAIL_DURATION=$((BUILD_FAIL_TIME - BUILD_START_TIME))
			BUILD_FAIL_FORMATTED=$(printf '%02d:%02d:%02d' $((BUILD_FAIL_DURATION/3600)) $((BUILD_FAIL_DURATION%3600/60)) $((BUILD_FAIL_DURATION%60)))
			echo ""
			echo "========================================"
			echo "Build FAILED (exit code: $EXIT_CODE)"
			echo "========================================"
			echo "Started:  ${BUILD_START_TIMESTAMP}"
			echo "Failed:   ${BUILD_FAIL_TIMESTAMP}"
			echo "Duration: ${BUILD_FAIL_FORMATTED}"
			echo "========================================"
			echo ""
		else
			echo "Build failed (exit code: $EXIT_CODE)"
		fi
	fi
}

trap 'term; echo "Error encountered at line $LINENO. Exiting."; exit 1' ERR
trap 'term' EXIT INT TERM

# Initialize output directories
echo "Creating output directories..."
mkdir -p "$(dirname "$DTB_OUTPUT_DIR")" \
         "$DTB_OUTPUT_DIR" \
         "$DTBO_OUTPUT_DIR" \
         "$MODULES_OUTPUT_DIR" \
         "$HEADERS_OUTPUT_DIR"

# Clone or update the kernel source repository
if [ ! -d "$KERNEL_SRC_DIR" ]; then
    echo "Cloning kernel source from $KERNEL_REPO..."
    git clone --depth=1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_SRC_DIR"
else
    echo "Kernel source directory exists. Updating..."
    cd "$KERNEL_SRC_DIR"

    # Fetch the branch
    git fetch --depth=1 origin "$KERNEL_BRANCH":"$KERNEL_BRANCH" 2>/dev/null || \
    git fetch --depth=1 origin "$KERNEL_BRANCH"

    # Clean working directory before checkout
    git reset --hard HEAD 2>/dev/null || true
    git clean -fdx 2>/dev/null || true

    # Force checkout the branch (-B creates or resets branch)
    git checkout -B "$KERNEL_BRANCH" FETCH_HEAD
    cd "$BASE_DIR"
fi

# Export environment variables
export ARCH="$ARCH"
export CROSS_COMPILE="$CROSS_COMPILE"

# Function to build a kernel variant
build_kernel_variant() {
    local VARIANT="$1"
    local BASE_CONFIG="$2"
    local CUSTOM_CONFIG="$3"
    local KERNEL_IMAGE_NAME="$4"

    echo ""
    echo "========================================"
    echo "Building Kernel: $VARIANT"
    echo "========================================"
    echo "Base config: $BASE_CONFIG"
    echo "Custom config: $(basename "$CUSTOM_CONFIG")"
    echo "Output kernel: $KERNEL_IMAGE_NAME"
    echo "========================================"
    echo ""

    cd "$KERNEL_SRC_DIR"

    # Clean previous build artifacts
    echo "Cleaning previous build artifacts..."
    make mrproper

    # Configure the kernel
    echo "Loading base config: $BASE_CONFIG..."
    make "$BASE_CONFIG"

    echo "Merging custom config: $(basename "$CUSTOM_CONFIG")..."
    if [ -f "$CUSTOM_CONFIG" ]; then
        ./scripts/kconfig/merge_config.sh "arch/$ARCH/configs/$BASE_CONFIG" "$CUSTOM_CONFIG"
        make olddefconfig
    else
        echo "ERROR: Custom config file $CUSTOM_CONFIG not found."
        exit 1
    fi

    # Apply patches (only on first build)
    if [ "$VARIANT" == "bcm2711" ]; then
        echo "Checking for patches in $PATCHES_DIR..."
        shopt -s nullglob
        patches=("$PATCHES_DIR"/*.patch)
        if [ ${#patches[@]} -gt 0 ]; then
            echo "Applying ${#patches[@]} patch(es)..."
            for patch in "${patches[@]}"; do
                echo "Applying patch: $(basename "$patch")"
                patch -p1 --ignore-whitespace -N < "$patch" || true
            done
        else
            echo "No patches found in $PATCHES_DIR."
        fi
        shopt -u nullglob
    fi

    # Build the kernel
    echo "Building kernel Image..."
    make -j"$NUM_CORES" Image

    echo "Building modules..."
    make -j"$NUM_CORES" modules

    # Get kernel version BEFORE installing modules
    KERNEL_VERSION=$(make kernelrelease)
    echo "Kernel version: $KERNEL_VERSION"

    echo "Installing modules to $MODULES_OUTPUT_DIR/$KERNEL_VERSION..."
    make INSTALL_MOD_PATH="$OUTPUT_PATH" modules_install

    echo "Building Device Tree Blobs (DTBs)..."
    make -j"$NUM_CORES" dtbs

    # Collect kernel image
    echo "Collecting kernel image..."
    if [ ! -f "arch/arm64/boot/Image" ]; then
        echo "ERROR: Kernel image not found!"
        exit 1
    fi

    local IMAGE_OUTPUT="$OUTPUT_PATH/boot/firmware/$KERNEL_IMAGE_NAME"
    mkdir -p "$(dirname "$IMAGE_OUTPUT")"
    cp arch/arm64/boot/Image "$IMAGE_OUTPUT"

    # Collect DTBs and overlays (first variant only to avoid duplicates)
    if [ "$VARIANT" == "bcm2711" ]; then
        echo "Collecting DTBs and overlays..."
        find arch/arm64/boot/dts/ -name '*.dtb' -exec cp {} "$DTB_OUTPUT_DIR" \;
        find arch/arm64/boot/dts/overlays/ -name '*.dtbo' -exec cp {} "$DTBO_OUTPUT_DIR" \; || true
    fi

    # Prepare kernel headers
    echo "Preparing kernel headers for $KERNEL_VERSION..."
    local VARIANT_HEADERS_DIR="$HEADERS_OUTPUT_DIR/$KERNEL_VERSION"
    mkdir -p "$VARIANT_HEADERS_DIR/usr/src/linux-headers-$KERNEL_VERSION"
    mkdir -p "$VARIANT_HEADERS_DIR/lib/modules/$KERNEL_VERSION"

    make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
        INSTALL_HDR_PATH="$VARIANT_HEADERS_DIR/usr" \
        headers_install

    cp -a "include" "$VARIANT_HEADERS_DIR/usr/src/linux-headers-$KERNEL_VERSION/"
    cp -a "arch/$ARCH/include" "$VARIANT_HEADERS_DIR/usr/src/linux-headers-$KERNEL_VERSION/arch/"
    cp Makefile "$VARIANT_HEADERS_DIR/usr/src/linux-headers-$KERNEL_VERSION/"
    cp .config "$VARIANT_HEADERS_DIR/usr/src/linux-headers-$KERNEL_VERSION/"
    cp -a scripts "$VARIANT_HEADERS_DIR/usr/src/linux-headers-$KERNEL_VERSION/"

    # Create build symlink
    ln -sf "/usr/src/linux-headers-$KERNEL_VERSION" \
        "$VARIANT_HEADERS_DIR/lib/modules/$KERNEL_VERSION/build"

    echo ""
    echo "✓ $VARIANT kernel build complete"
    echo ""

    # Return kernel version via global variable (avoid capturing all echo output)
    BUILT_KERNEL_VERSION="$KERNEL_VERSION"
}

# Build kernel variants based on target selection
# Initialize version variables
BCM2711_VERSION=""
BCM2712_VERSION=""

if [ "$BUILD_PI4" = true ]; then
    build_kernel_variant "bcm2711" "$BCM2711_BASE_CONFIG" "$BCM2711_CUSTOM_CONFIG" "$BCM2711_KERNEL_IMAGE"
    BCM2711_VERSION="$BUILT_KERNEL_VERSION"
fi

if [ "$BUILD_PI5" = true ]; then
    build_kernel_variant "bcm2712" "$BCM2712_BASE_CONFIG" "$BCM2712_CUSTOM_CONFIG" "$BCM2712_KERNEL_IMAGE"
    BCM2712_VERSION="$BUILT_KERNEL_VERSION"
fi

echo ""
echo "========================================"
echo "Kernel Builds Complete"
echo "========================================"
if [ "$BUILD_PI4" = true ]; then
    echo "Pi 4 kernel version:  $BCM2711_VERSION"
fi
if [ "$BUILD_PI5" = true ]; then
    echo "Pi 5 kernel version:  $BCM2712_VERSION"
fi
echo "========================================"
echo ""

# Function to build a kernel package
build_kernel_package() {
    local PKG_NAME="$1"
    local PKG_DESC="$2"
    local INCLUDE_PI4="$3"      # yes/no
    local INCLUDE_PI5="$4"      # yes/no
    local PKG_VERSION="$5"      # variant-specific version
    local PKG_DIR="$BASE_DIR/package-${PKG_NAME}"

    echo ""
    echo "========================================"
    echo "Building package: $PKG_NAME"
    echo "========================================"

    rm -rf "$PKG_DIR"
    mkdir -p "$PKG_DIR/DEBIAN" \
             "$PKG_DIR/usr/local/lib/wlanpi-kernel/boot/firmware/overlays" \
             "$PKG_DIR/lib/modules"

    # Copy kernel images based on what's included
    if [ "$INCLUDE_PI4" == "yes" ]; then
        echo "Including Pi 4 kernel: $BCM2711_KERNEL_IMAGE"
        cp "$OUTPUT_PATH/boot/firmware/$BCM2711_KERNEL_IMAGE" \
           "$PKG_DIR/usr/local/lib/wlanpi-kernel/boot/firmware/"
    fi

    if [ "$INCLUDE_PI5" == "yes" ]; then
        echo "Including Pi 5 kernel: $BCM2712_KERNEL_IMAGE"
        cp "$OUTPUT_PATH/boot/firmware/$BCM2712_KERNEL_IMAGE" \
           "$PKG_DIR/usr/local/lib/wlanpi-kernel/boot/firmware/"
    fi

    # Copy DTBs and overlays (shared by all packages)
    echo "Copying DTBs and overlays..."
    if compgen -G "$DTB_OUTPUT_DIR"*.dtb > /dev/null; then
        cp "$DTB_OUTPUT_DIR"*.dtb "$PKG_DIR/usr/local/lib/wlanpi-kernel/boot/firmware/"
    fi
    if compgen -G "$DTBO_OUTPUT_DIR"*.dtbo > /dev/null; then
        cp "$DTBO_OUTPUT_DIR"*.dtbo "$PKG_DIR/usr/local/lib/wlanpi-kernel/boot/firmware/overlays/"
    fi

    # Copy kernel modules
    if [ "$INCLUDE_PI4" == "yes" ]; then
        echo "Including Pi 4 modules: $BCM2711_VERSION"
        cp -r "$MODULES_OUTPUT_DIR/$BCM2711_VERSION" "$PKG_DIR/lib/modules/"
    fi

    if [ "$INCLUDE_PI5" == "yes" ]; then
        echo "Including Pi 5 modules: $BCM2712_VERSION"
        cp -r "$MODULES_OUTPUT_DIR/$BCM2712_VERSION" "$PKG_DIR/lib/modules/"
    fi

    # Determine conflicts
    local CONFLICTS=""
    if [ "$PKG_NAME" == "$PACKAGE_NAME_V8" ]; then
        CONFLICTS="Conflicts: wlanpi-kernel, $PACKAGE_NAME_2712"
    elif [ "$PKG_NAME" == "$PACKAGE_NAME_2712" ]; then
        CONFLICTS="Conflicts: wlanpi-kernel, $PACKAGE_NAME_V8"
    else
        # Dual package conflicts with variant-specific packages
        CONFLICTS="Conflicts: wlanpi-kernel, $PACKAGE_NAME_V8, $PACKAGE_NAME_2712"
    fi

    # Create control file
    cat <<EOF > "$PKG_DIR/DEBIAN/control"
Package: $PKG_NAME
Version: $PKG_VERSION
Section: kernel
Priority: optional
Architecture: arm64
Maintainer: Jerry Olla <jerryolla@gmail.com>
$CONFLICTS
Replaces: wlanpi-kernel
Provides: wlanpi-kernel
Depends: libc6 (>= 2.29)
Description: $PKG_DESC
EOF

    if [ "$INCLUDE_PI4" == "yes" ] && [ "$INCLUDE_PI5" == "no" ]; then
        cat <<EOF >> "$PKG_DIR/DEBIAN/control"
 This package contains a custom Linux kernel for Raspberry Pi 4/CM4 only.
 .
 Optimized for space-constrained deployments (e.g., 8GB eMMC).
 Kernel version: $BCM2711_VERSION
 Kernel image: $BCM2711_KERNEL_IMAGE
EOF
    elif [ "$INCLUDE_PI4" == "no" ] && [ "$INCLUDE_PI5" == "yes" ]; then
        cat <<EOF >> "$PKG_DIR/DEBIAN/control"
 This package contains a custom Linux kernel for Raspberry Pi 5 only.
 .
 Kernel version: $BCM2712_VERSION
 Kernel image: $BCM2712_KERNEL_IMAGE
EOF
    else
        cat <<EOF >> "$PKG_DIR/DEBIAN/control"
 This package contains custom Linux kernels for both Raspberry Pi 4 and Pi 5.
 The firmware automatically selects the appropriate kernel at boot.
 .
 Pi 4/CM4: $BCM2711_VERSION ($BCM2711_KERNEL_IMAGE)
 Pi 5:     $BCM2712_VERSION ($BCM2712_KERNEL_IMAGE)
EOF
    fi

    # Create postinst script
    cat > "$PKG_DIR/DEBIAN/postinst" <<'POSTINST_EOF'
#!/bin/bash
set -e

PACKAGE_KERNEL_DIR="/usr/local/lib/wlanpi-kernel/boot/firmware"

if [ ! -d "$PACKAGE_KERNEL_DIR" ]; then
    echo "ERROR: Package directory $PACKAGE_KERNEL_DIR not found"
    exit 1
fi

# Detect boot partition location
# Priority: existing kernel location, then /boot/firmware, then /boot
if [ -f "/boot/firmware/wlanpi-kernel8.img" ] || [ -f "/boot/firmware/wlanpi-kernel_2712.img" ]; then
    FIRMWARE_DIR="/boot/firmware"
elif [ -f "/boot/wlanpi-kernel8.img" ] || [ -f "/boot/wlanpi-kernel_2712.img" ]; then
    FIRMWARE_DIR="/boot"
elif [ -d "/boot/firmware" ]; then
    FIRMWARE_DIR="/boot/firmware"
elif [ -d "/boot" ]; then
    FIRMWARE_DIR="/boot"
else
    echo "ERROR: Boot partition not found"
    exit 1
fi

CONFIG_TXT="$FIRMWARE_DIR/config.txt"

echo "Installing WLAN Pi kernel to $FIRMWARE_DIR..."

if [ ! -f "$CONFIG_TXT" ]; then
    echo "ERROR: $CONFIG_TXT not found"
    exit 1
fi

if [ ! -f "$CONFIG_TXT.wlanpi-kernel.bak" ]; then
    cp -f "$CONFIG_TXT" "$CONFIG_TXT.wlanpi-kernel.bak"
fi
mkdir -p "$FIRMWARE_DIR/overlays"

# Install kernel images
shopt -s nullglob
kernel_images=("$PACKAGE_KERNEL_DIR"/*.img)
if [ ${#kernel_images[@]} -eq 0 ]; then
    echo "ERROR: No kernel images found in package"
    exit 1
fi

for img in "${kernel_images[@]}"; do
    echo "Installing $(basename "$img")..."
    cp -f "$img" "$FIRMWARE_DIR/"
done

# Install DTBs
dtb_files=("$PACKAGE_KERNEL_DIR"/*.dtb)
if [ ${#dtb_files[@]} -gt 0 ]; then
    echo "Installing ${#dtb_files[@]} DTB files..."
    cp -f "$PACKAGE_KERNEL_DIR/"*.dtb "$FIRMWARE_DIR/"
fi

# Install overlays
dtbo_files=("$PACKAGE_KERNEL_DIR/overlays/"*.dtbo)
if [ ${#dtbo_files[@]} -gt 0 ]; then
    echo "Installing ${#dtbo_files[@]} overlay files..."
    cp -f "$PACKAGE_KERNEL_DIR/overlays/"*.dtbo "$FIRMWARE_DIR/overlays/"
fi
shopt -u nullglob

# Select kernel for config.txt
if [ -f "$FIRMWARE_DIR/wlanpi-kernel8.img" ]; then
    KERNEL_IMG="wlanpi-kernel8.img"
elif [ -f "$FIRMWARE_DIR/wlanpi-kernel_2712.img" ]; then
    KERNEL_IMG="wlanpi-kernel_2712.img"
else
    echo "ERROR: No kernel image found after installation"
    exit 1
fi

# Update config.txt
echo "Configuring boot to use $KERNEL_IMG..."
if grep -q "^kernel=" "$CONFIG_TXT"; then
    sed -i "s|^kernel=.*|kernel=$KERNEL_IMG|" "$CONFIG_TXT"
else
    echo "kernel=$KERNEL_IMG" >> "$CONFIG_TXT"
fi

echo "Installation complete"
exit 0
POSTINST_EOF

    chmod 755 "$PKG_DIR/DEBIAN/postinst"

    # Build the package
    dpkg-deb --build "$PKG_DIR" "$OUTPUT_PATH/${PKG_NAME}_${PKG_VERSION}_arm64.deb"

    rm -rf "$PKG_DIR"

    echo "✓ Package built: ${PKG_NAME}_${PKG_VERSION}_arm64.deb"
}

# Prepare Debian packages (three variants: Pi 4 only, Pi 5 only, and dual)
echo ""
echo "========================================"
echo "Building Conditional Kernel Packages"
echo "========================================"

BUILD_DATE=$(date +%Y%m%d)

# Create variant-specific package versions
PACKAGE_VERSION_V8="${BCM2711_VERSION}-${BUILD_DATE}"
PACKAGE_VERSION_2712="${BCM2712_VERSION}-${BUILD_DATE}"
# For dual package, use v8 version as base (following RPi convention)
PACKAGE_VERSION_DUAL="${BCM2711_VERSION}-${BUILD_DATE}"

echo "Building packages for selected target(s)..."
echo ""

# Build packages based on what was compiled
if [ "$BUILD_PI4" = true ] && [ "$BUILD_PI5" = false ]; then
    # Pi 4 only build
    echo "Creating v8 package: $PACKAGE_NAME_V8"
    build_kernel_package \
        "$PACKAGE_NAME_V8" \
        "WLAN Pi kernel for Raspberry Pi 4/CM4 (v8, 4KB pages)" \
        "yes" \
        "no" \
        "$PACKAGE_VERSION_V8"

elif [ "$BUILD_PI5" = true ] && [ "$BUILD_PI4" = false ]; then
    # Pi 5 only build
    echo "Creating 2712 package: $PACKAGE_NAME_2712"
    build_kernel_package \
        "$PACKAGE_NAME_2712" \
        "WLAN Pi kernel for Raspberry Pi 5 (2712, 16KB pages)" \
        "no" \
        "yes" \
        "$PACKAGE_VERSION_2712"

else
    echo "Creating all three package variants..."

    # Build v8 package
    build_kernel_package \
        "$PACKAGE_NAME_V8" \
        "WLAN Pi kernel for Raspberry Pi 4/CM4 (v8, 4KB pages)" \
        "yes" \
        "no" \
        "$PACKAGE_VERSION_V8"

    # Build 2712 package
    build_kernel_package \
        "$PACKAGE_NAME_2712" \
        "WLAN Pi kernel for Raspberry Pi 5 (2712, 16KB pages)" \
        "no" \
        "yes" \
        "$PACKAGE_VERSION_2712"

    # Build dual kernel package
    build_kernel_package \
        "$PACKAGE_NAME_DUAL" \
        "WLAN Pi kernel for Raspberry Pi 4/5 (unified)" \
        "yes" \
        "yes" \
        "$PACKAGE_VERSION_DUAL"
fi

# Build headers packages
echo ""
echo "========================================"
echo "Building Kernel Headers Packages"
echo "========================================"

# Prepare headers packages (only for kernels that were built)
HEADER_VERSIONS=()
[ "$BUILD_PI4" = true ] && HEADER_VERSIONS+=("$BCM2711_VERSION")
[ "$BUILD_PI5" = true ] && HEADER_VERSIONS+=("$BCM2712_VERSION")

for KVER in "${HEADER_VERSIONS[@]}"; do
    HEADERS_PKG_DIR="$BASE_DIR/wlanpi-kernel-headers-package-$KVER"
    rm -rf "$HEADERS_PKG_DIR"
    mkdir -p "$HEADERS_PKG_DIR/DEBIAN"

    # Copy headers from output directory
    cp -r "$HEADERS_OUTPUT_DIR/$KVER"/* "$HEADERS_PKG_DIR/"

    # Determine variant name and corresponding kernel package
    if [[ "$KVER" == *"v8-wlanpi"* ]]; then
        VARIANT_NAME="v8"
        KERNEL_PKG_NAME="$PACKAGE_NAME_V8"
        VARIANT_PKG_VERSION="$PACKAGE_VERSION_V8"
    else
        VARIANT_NAME="2712"
        KERNEL_PKG_NAME="$PACKAGE_NAME_2712"
        VARIANT_PKG_VERSION="$PACKAGE_VERSION_2712"
    fi

    # Create control file
    cat <<EOF > "$HEADERS_PKG_DIR/DEBIAN/control"
Package: $HEADERS_PACKAGE_NAME-$VARIANT_NAME
Version: $VARIANT_PKG_VERSION
Section: kernel
Priority: optional
Architecture: arm64
Maintainer: Josh Schmelzle <josh@joshschmelzle.com>
Depends: gcc, make, perl
Description: Linux kernel headers for WLAN Pi Raspberry Pi $VARIANT_NAME kernel
 Kernel header files and scripts for WLAN Pi custom kernel development ($VARIANT_NAME variant).
 Version: $KVER
EOF

    # Create postinst
    cat <<EOF > "$HEADERS_PKG_DIR/DEBIAN/postinst"
#!/bin/bash
set -e

KERNEL_VERSION="$KVER"

if [ -d "/usr/src/linux-headers-\$KERNEL_VERSION" ]; then
    rm -f "/lib/modules/\$KERNEL_VERSION/build"
    ln -sf "/usr/src/linux-headers-\$KERNEL_VERSION" "/lib/modules/\$KERNEL_VERSION/build"
    echo "Kernel headers symlink created for \$KERNEL_VERSION"
else
    echo "Warning: Kernel headers directory not found for \$KERNEL_VERSION"
fi

exit 0
EOF

    chmod 755 "$HEADERS_PKG_DIR/DEBIAN/postinst"

    # Build headers package
    echo "Building kernel headers package for $VARIANT_NAME ($KVER)..."
    dpkg-deb --build "$HEADERS_PKG_DIR" \
        "$OUTPUT_PATH/${HEADERS_PACKAGE_NAME}-${VARIANT_NAME}_${VARIANT_PKG_VERSION}_arm64.deb"

    rm -rf "$HEADERS_PKG_DIR"
done

echo ""
echo "========================================"
echo "Packages Created Successfully"
echo "========================================"
echo "Kernel packages:"
if [ "$BUILD_PI4" = true ] && [ "$BUILD_PI5" = false ]; then
    echo "  - ${PACKAGE_NAME_V8}_${PACKAGE_VERSION_V8}_arm64.deb (~30MB)"
elif [ "$BUILD_PI5" = true ] && [ "$BUILD_PI4" = false ]; then
    echo "  - ${PACKAGE_NAME_2712}_${PACKAGE_VERSION_2712}_arm64.deb (~30MB)"
else
    echo "  - ${PACKAGE_NAME_V8}_${PACKAGE_VERSION_V8}_arm64.deb (~30MB)"
    echo "  - ${PACKAGE_NAME_2712}_${PACKAGE_VERSION_2712}_arm64.deb (~30MB)"
    echo "  - ${PACKAGE_NAME_DUAL}_${PACKAGE_VERSION_DUAL}_arm64.deb (~58MB)"
fi
echo ""
echo "Headers packages:"
[ "$BUILD_PI4" = true ] && echo "  - ${HEADERS_PACKAGE_NAME}-v8_${PACKAGE_VERSION_V8}_arm64.deb (~9MB)"
[ "$BUILD_PI5" = true ] && echo "  - ${HEADERS_PACKAGE_NAME}-2712_${PACKAGE_VERSION_2712}_arm64.deb (~9MB)"
echo "========================================"
echo ""

BUILD_END_TIME=$(date +%s)
BUILD_END_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')
BUILD_DURATION=$((BUILD_END_TIME - BUILD_START_TIME))
BUILD_DURATION_FORMATTED=$(printf '%02d:%02d:%02d' $((BUILD_DURATION/3600)) $((BUILD_DURATION%3600/60)) $((BUILD_DURATION%60)))

echo ""
echo "========================================"
echo "Build Summary"
echo "========================================"
echo "Started:  ${BUILD_START_TIMESTAMP}"
echo "Finished: ${BUILD_END_TIMESTAMP}"
echo "Duration: ${BUILD_DURATION_FORMATTED}"
echo "========================================"
echo "Kernels built:"
[ "$BUILD_PI4" = true ] && echo "  Pi 4:  $BCM2711_VERSION -> $BCM2711_KERNEL_IMAGE"
[ "$BUILD_PI5" = true ] && echo "  Pi 5:  $BCM2712_VERSION -> $BCM2712_KERNEL_IMAGE"
echo "========================================"
if [ "$BUILD_PI4" = true ] && [ "$BUILD_PI5" = false ]; then
    echo "Total: 1 kernel package + 1 headers package"
elif [ "$BUILD_PI5" = true ] && [ "$BUILD_PI4" = false ]; then
    echo "Total: 1 kernel package + 1 headers package"
else
    echo "Total: 3 kernel packages + 2 headers packages"
fi
echo "========================================"
echo ""
echo "✓ Build completed successfully."
echo ""
