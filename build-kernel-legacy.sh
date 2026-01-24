#!/bin/bash

# Build script for cross-compiling the Linux kernel for Raspberry Pi CM4/RPI4
# and packaging it into a Debian package
# Target: ARM64, Distribution: Debian Bookworm
# Author: Jerry Olla <jerryolla@gmail.com>

set -euo pipefail  # Enable strict error handling

# Enable detailed logging
LOG_FILE="build_kernel.log"
exec > >(tee -i "$LOG_FILE") 2>&1

# Track build timing
BUILD_START_TIME=$(date +%s)
BUILD_START_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')
echo "========================================"
echo "Kernel Build Started"
echo "========================================"
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
KERNEL_BRANCH="rpi-6.18.y"
KERNEL_SRC_DIR="$BASE_DIR/linux"
OUTPUT_PATH="$BASE_DIR/output"
CROSS_COMPILE="aarch64-linux-gnu-"
ARCH="arm64"
BASE_CONFIG="bcm2711_defconfig"
CUSTOM_CONFIG="$BASE_DIR/wlanpi_v8_defconfig"
PATCHES_DIR="$BASE_DIR/patches"
PACKAGE_DIR="$BASE_DIR/wlanpi-kernel-package"
NUM_CORES=$(nproc)

# Derived Variables
KERNEL_IMAGE_NAME="wlanpi-kernel8.img"
IMAGE_OUTPUT="$OUTPUT_PATH/boot/firmware/$KERNEL_IMAGE_NAME"
DTB_OUTPUT_DIR="$OUTPUT_PATH/boot/firmware/"
DTBO_OUTPUT_DIR="$OUTPUT_PATH/boot/firmware/overlays/"
MODULES_OUTPUT_DIR="$OUTPUT_PATH/lib/modules"
HEADERS_OUTPUT_DIR="$OUTPUT_PATH/linux-headers"

# Debian Package Metadata
PACKAGE_NAME="wlanpi-kernel-bookworm"
HEADERS_PACKAGE_NAME="wlanpi-kernel-headers-bookworm"

# Trap for error handling and timing
term() {
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
mkdir -p "$(dirname "$IMAGE_OUTPUT")" \
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
    git fetch origin "$KERNEL_BRANCH"
    git checkout "$KERNEL_BRANCH"
    git reset --hard "origin/$KERNEL_BRANCH"
    cd "$BASE_DIR"
fi

# Configure the kernel
echo "Configuring the kernel..."
cd "$KERNEL_SRC_DIR"

export ARCH="$ARCH"
export CROSS_COMPILE="$CROSS_COMPILE"

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

# Apply patches
echo "Checking for patches in $PATCHES_DIR..."
shopt -s nullglob  # Make globs expand to nothing if no matches
patches=("$PATCHES_DIR"/*.patch)
if [ ${#patches[@]} -gt 0 ]; then
    echo "Applying ${#patches[@]} patch(es)..."
    for patch in "${patches[@]}"; do
        echo "Applying patch: $(basename "$patch")"
        patch -p1 --ignore-whitespace -N < "$patch"
    done
else
    echo "No patches found in $PATCHES_DIR, skipping patch application."
fi
shopt -u nullglob  # Restore default glob behavior

# Build the kernel, modules, and DTBs
echo "Starting kernel build..."

echo "Building Image..."
make -j"$NUM_CORES" Image

echo "Building modules..."
make -j"$NUM_CORES" modules

echo "Installing modules to $MODULES_OUTPUT_DIR..."
make INSTALL_MOD_PATH="$OUTPUT_PATH" modules_install

echo "Building Device Tree Blobs (DTBs)..."
make -j"$NUM_CORES" dtbs

# Collect build artifacts
echo "Collecting build artifacts..."

if [ ! -f "arch/arm64/boot/Image" ]; then
    echo "ERROR: Kernel image not found!"
    exit 1
fi

cp arch/arm64/boot/Image "$IMAGE_OUTPUT"

find arch/arm64/boot/dts/ -name '*.dtb' -exec cp {} "$DTB_OUTPUT_DIR" \;
find arch/arm64/boot/dts/overlays/ -name '*.dtbo' -exec cp {} "$DTBO_OUTPUT_DIR" \;

prepare_kernel_headers() {
    echo "Preparing kernel headers..."
    
    mkdir -p "$HEADERS_OUTPUT_DIR/usr/src/linux-headers-$KERNEL_VERSION"
    mkdir -p "$HEADERS_OUTPUT_DIR/lib/modules/$KERNEL_VERSION/build"

    echo "Copying kernel headers..."
    make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
        INSTALL_HDR_PATH="$HEADERS_OUTPUT_DIR/usr" \
        headers_install

    echo "Copying kernel source for headers..."
    cp -a "include" "$HEADERS_OUTPUT_DIR/usr/src/linux-headers-$KERNEL_VERSION/"
    cp -a "arch/$ARCH/include" "$HEADERS_OUTPUT_DIR/usr/src/linux-headers-$KERNEL_VERSION/arch/"
    
    cp Makefile "$HEADERS_OUTPUT_DIR/usr/src/linux-headers-$KERNEL_VERSION/"
    cp .config "$HEADERS_OUTPUT_DIR/usr/src/linux-headers-$KERNEL_VERSION/"
    cp -a scripts "$HEADERS_OUTPUT_DIR/usr/src/linux-headers-$KERNEL_VERSION/"

    ln -sf "/usr/src/linux-headers-$KERNEL_VERSION" \
        "$HEADERS_OUTPUT_DIR/lib/modules/$KERNEL_VERSION/build"
}

# Prepare Debian package
echo "Preparing Debian package..."

# Retrieve kernel version and set package version
KERNEL_VERSION=$(make kernelrelease)
BUILD_DATE=$(date +%Y%m%d)
PACKAGE_VERSION="${KERNEL_VERSION}-${BUILD_DATE}"

echo "Kernel Version: $KERNEL_VERSION"
echo "Build Date: $BUILD_DATE"
echo "Package Name: $PACKAGE_NAME"
echo "Package Version: $PACKAGE_VERSION"

# Clean previous package directory
rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR/DEBIAN" \
         "$PACKAGE_DIR/usr/local/lib/wlanpi-kernel/boot/firmware/overlays" \
         "$PACKAGE_DIR/lib/modules/$KERNEL_VERSION"

# Copy files to package directory
echo "Copying kernel image..."
cp "$IMAGE_OUTPUT" "$PACKAGE_DIR/usr/local/lib/wlanpi-kernel/boot/firmware/"

echo "Copying DTB files..."
if compgen -G "$DTB_OUTPUT_DIR"*.dtb > /dev/null; then
    cp "$DTB_OUTPUT_DIR"*.dtb "$PACKAGE_DIR/usr/local/lib/wlanpi-kernel/boot/firmware/"
else
    echo "Warning: No DTB files found in $DTB_OUTPUT_DIR"
fi

echo "Copying DTBO overlay files..."
if compgen -G "$DTBO_OUTPUT_DIR"*.dtbo > /dev/null; then
    cp "$DTBO_OUTPUT_DIR"*.dtbo "$PACKAGE_DIR/usr/local/lib/wlanpi-kernel/boot/firmware/overlays/"
else
    echo "Warning: No DTBO files found in $DTBO_OUTPUT_DIR"
fi

echo "Copying kernel modules..."
cp -r "$MODULES_OUTPUT_DIR/$KERNEL_VERSION" "$PACKAGE_DIR/lib/modules/."

# Create DEBIAN/control file
cat <<EOF > "$PACKAGE_DIR/DEBIAN/control"
Package: $PACKAGE_NAME
Version: $PACKAGE_VERSION
Section: kernel
Priority: optional
Architecture: arm64
Maintainer: Jerry Olla <jerryolla@gmail.com>
Conflicts: wlanpi-kernel
Replaces: wlanpi-kernel
Depends: libc6 (>= 2.29)
Description: Custom Linux kernel for Raspberry Pi CM4/RPI4 with WLAN Pi v8 configuration for Debian Bookworm
 This package contains a custom-built Linux kernel image, Device Tree Blobs (DTBs),
 and kernel modules tailored for the WLAN Pi v8 configuration on Raspberry Pi CM4/RPI4 running Debian Bookworm.
EOF

# Create DEBIAN/postinst script
cat <<'EOF' > "$PACKAGE_DIR/DEBIAN/postinst"
#!/bin/bash
set -e

PACKAGE_KERNEL_DIR="/usr/local/lib/wlanpi-kernel/boot/firmware"
KERNEL_IMAGE="wlanpi-kernel8.img"

if [ ! -d "$PACKAGE_KERNEL_DIR" ]; then
    echo "ERROR: Package directory $PACKAGE_KERNEL_DIR not found"
    exit 1
fi

if [ ! -f "$PACKAGE_KERNEL_DIR/$KERNEL_IMAGE" ]; then
    echo "ERROR: Kernel image $KERNEL_IMAGE not found in package"
    exit 1
fi

# Detect boot partition location
# Priority: existing kernel location, then /boot/firmware, then /boot
if [ -f "/boot/firmware/$KERNEL_IMAGE" ]; then
    FIRMWARE_DIR="/boot/firmware"
elif [ -f "/boot/$KERNEL_IMAGE" ]; then
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

echo "Installing kernel to $FIRMWARE_DIR..."

if [ ! -f "$CONFIG_TXT" ]; then
    echo "ERROR: $CONFIG_TXT not found"
    exit 1
fi

if [ ! -f "$CONFIG_TXT.wlanpi-kernel.bak" ]; then
    cp -f "$CONFIG_TXT" "$CONFIG_TXT.wlanpi-kernel.bak"
fi
mkdir -p "$FIRMWARE_DIR/overlays"

# Install kernel
echo "Installing $KERNEL_IMAGE..."
cp -f "$PACKAGE_KERNEL_DIR/$KERNEL_IMAGE" "$FIRMWARE_DIR/"

# Install DTBs
shopt -s nullglob
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

# Update config.txt
echo "Configuring boot to use $KERNEL_IMAGE..."
if grep -q "^kernel=" "$CONFIG_TXT"; then
    sed -i "s|^kernel=.*|kernel=$KERNEL_IMAGE|" "$CONFIG_TXT"
else
    echo "kernel=$KERNEL_IMAGE" >> "$CONFIG_TXT"
fi

echo "Installation complete"
exit 0
EOF

# Make postinst script executable
chmod 755 "$PACKAGE_DIR/DEBIAN/postinst"

prepare_kernel_headers

# Create headers package directory
HEADERS_PACKAGE_DIR="$BASE_DIR/wlanpi-kernel-headers-package"
rm -rf "$HEADERS_PACKAGE_DIR"
mkdir -p "$HEADERS_PACKAGE_DIR/DEBIAN" \
         "$HEADERS_PACKAGE_DIR/usr/src/linux-headers-$KERNEL_VERSION" \
         "$HEADERS_PACKAGE_DIR/lib/modules/$KERNEL_VERSION"

# Copy headers to package directory
cp -r "$HEADERS_OUTPUT_DIR/usr/src/linux-headers-$KERNEL_VERSION"/* \
    "$HEADERS_PACKAGE_DIR/usr/src/linux-headers-$KERNEL_VERSION/"
cp -r "$HEADERS_OUTPUT_DIR/lib/modules/$KERNEL_VERSION/build" \
    "$HEADERS_PACKAGE_DIR/lib/modules/$KERNEL_VERSION/"

# Create DEBIAN/control file for headers package
cat <<EOF > "$HEADERS_PACKAGE_DIR/DEBIAN/control"
Package: $HEADERS_PACKAGE_NAME
Version: $PACKAGE_VERSION
Section: kernel
Priority: optional
Architecture: arm64
Maintainer: Josh Schmelzle <josh@joshschmelzle.com>
Depends: gcc, make, perl
Description: Linux kernel headers for WLAN Pi Raspberry Pi kernel
 Kernel header files and scripts for WLAN Pi custom kernel development.
EOF

# Create DEBIAN/postinst script for headers
cat <<EOF > "$HEADERS_PACKAGE_DIR/DEBIAN/postinst"
#!/bin/bash
set -e

# Extract kernel version from package (matches the installed modules directory)
KERNEL_VERSION="$KERNEL_VERSION"

# Update module build symlink
if [ -d "/usr/src/linux-headers-\$KERNEL_VERSION" ]; then
    rm -f "/lib/modules/\$KERNEL_VERSION/build"
    ln -sf "/usr/src/linux-headers-\$KERNEL_VERSION" "/lib/modules/\$KERNEL_VERSION/build"
    echo "Kernel headers symlink created for \$KERNEL_VERSION"
else
    echo "Warning: Kernel headers directory not found for \$KERNEL_VERSION"
fi

exit 0
EOF

# Make postinst script executable
chmod 755 "$HEADERS_PACKAGE_DIR/DEBIAN/postinst"

# Build the Debian package
echo "Building Debian package..."
dpkg-deb --build "$PACKAGE_DIR" "$OUTPUT_PATH/${PACKAGE_NAME}_${PACKAGE_VERSION}_arm64.deb"

# Build the headers Debian package
echo "Building Kernel Headers Debian package..."
dpkg-deb --build "$HEADERS_PACKAGE_DIR" \
    "$OUTPUT_PATH/${HEADERS_PACKAGE_NAME}_${PACKAGE_VERSION}_arm64.deb"

echo "Debian packages created successfully in $OUTPUT_PATH:"
echo "- ${PACKAGE_NAME}_${PACKAGE_VERSION}_arm64.deb"
echo "- ${HEADERS_PACKAGE_NAME}_${PACKAGE_VERSION}_arm64.deb"

# Clean up temporary package directories
echo "Cleaning up temporary package directories..."
rm -rf "$PACKAGE_DIR"
rm -rf "$HEADERS_PACKAGE_DIR"

# Calculate and display build timing
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
echo ""
echo "Kernel build, module installation, and package creation completed successfully."
