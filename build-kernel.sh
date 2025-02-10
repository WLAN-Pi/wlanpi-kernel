#!/bin/bash

# Build script for cross-compiling the Linux kernel for Raspberry Pi CM4/RPI4
# and packaging it into a Debian package
# Target: ARM64, Distribution: Debian Bookworm
# Author: Jerry Olla <jerryolla@gmail.com>

set -euo pipefail  # Enable strict error handling

# Enable detailed logging
LOG_FILE="build_kernel.log"
exec > >(tee -i "$LOG_FILE") 2>&1

# Determine the directory where the script resides
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration Variables
KERNEL_REPO="https://github.com/raspberrypi/linux.git"
KERNEL_BRANCH="rpi-6.12.y"
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

# Trap for error handling
trap 'echo "Error encountered at line $LINENO. Exiting."; exit 1' ERR

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
echo "Applying patches from $PATCHES_DIR..."
for patch in "$PATCHES_DIR"/*.patch; do
    if [ -f "$patch" ]; then
        echo "Applying patch: $(basename "$patch")"
        patch -p1 --ignore-whitespace -N < "$patch"
    else
        echo "No patches found in $PATCHES_DIR."
    fi
done

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
cp "$IMAGE_OUTPUT" "$PACKAGE_DIR/usr/local/lib/wlanpi-kernel/boot/firmware/"
cp "$DTB_OUTPUT_DIR"*.dtb "$PACKAGE_DIR/usr/local/lib/wlanpi-kernel/boot/firmware/"
cp "$DTBO_OUTPUT_DIR"*.dtbo "$PACKAGE_DIR/usr/local/lib/wlanpi-kernel/boot/firmware/overlays/"
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

# Variables
FIRMWARE_DIR="/boot/firmware"
PACKAGE_KERNEL_DIR="/usr/local/lib/wlanpi-kernel/boot/firmware"
CONFIG_TXT="$FIRMWARE_DIR/config.txt"
KERNEL_IMAGE="wlanpi-kernel8.img"

echo "Post-installation: Installing kernel image and DTBs to $FIRMWARE_DIR..."

# Ensure the firmware directory exists
if [ ! -d "$FIRMWARE_DIR" ]; then
    echo "ERROR: Firmware directory $FIRMWARE_DIR does not exist."
    exit 1
fi

# Ensure the overlays directory exists; create it if it doesn't
if [ ! -d "$FIRMWARE_DIR/overlays" ]; then
    echo "Overlays directory $FIRMWARE_DIR/overlays does not exist. Creating it..."
    mkdir -p "$FIRMWARE_DIR/overlays"
fi

# Copy kernel image
echo "Copying kernel image..."
cp -f "$PACKAGE_KERNEL_DIR/$KERNEL_IMAGE" "$FIRMWARE_DIR/"

# Copy DTBs
echo "Copying DTBs..."
cp -f "$PACKAGE_KERNEL_DIR/"*.dtb "$FIRMWARE_DIR/"
cp -f "$PACKAGE_KERNEL_DIR/overlays/"*.dtbo "$FIRMWARE_DIR/overlays/"

# Update config.txt with the new kernel
echo "Updating $CONFIG_TXT with the new kernel parameter..."
if grep -q "^kernel=" "$CONFIG_TXT"; then
    sed -i "s|^kernel=.*|kernel=$KERNEL_IMAGE|" "$CONFIG_TXT"
else
    echo "kernel=$KERNEL_IMAGE" >> "$CONFIG_TXT"
fi

echo "Kernel image and DTBs installed successfully."

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
Maintainer: Jerry Olla <jerryolla@gmail.com>
Depends: $PACKAGE_NAME (= $PACKAGE_VERSION), gcc, make, perl
Description: Linux kernel headers for WLAN Pi Raspberry Pi kernel
 Kernel header files and scripts for WLAN Pi custom kernel development.
EOF

# Create DEBIAN/postinst script for headers
cat <<'EOF' > "$HEADERS_PACKAGE_DIR/DEBIAN/postinst"
#!/bin/bash
set -e

KERNEL_VERSION="$2"

# Update module build symlink
if [ -d "/usr/src/linux-headers-$KERNEL_VERSION" ]; then
    rm -f "/lib/modules/$KERNEL_VERSION/build"
    ln -sf "/usr/src/linux-headers-$KERNEL_VERSION" "/lib/modules/$KERNEL_VERSION/build"
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

echo "Kernel build, module installation, and package creation completed successfully."
