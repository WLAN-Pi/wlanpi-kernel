#!/bin/bash

PARSED_ARGS=$(getopt -o cfb:hj: --long clean,force-sync,branch:,help --long arch:,git:,skip-patches -- "$@")
VALID_ARGS=$?

SCRIPT_PATH="$(dirname $(realpath "$0"))"
KERNEL_PATH="${SCRIPT_PATH}/cache/kernel"
LOG_PATH="${SCRIPT_PATH}/logs"
PATCHES_PATH="${SCRIPT_PATH}/kernel-patches"
OUTPUT_PATH="${SCRIPT_PATH}/output"
DEB_PATH="${SCRIPT_PATH}/debian/wlanpi-kernel"

# Set default values for configurations
KERNEL_URL="https://github.com/raspberrypi/linux.git"
KERNEL_BRANCH="rpi-5.15.y"
KERNEL_ARCH="arm"
KERNEL_DEFCONFIG="bcm2711_defconfig"
WLANPI_DEFCONFIG="wlanpi_v7l_defconfig"
KERNEL_FORCE_SYNC="0"
CLEAN_KERNEL="0"
SKIP_PATCHES="0"
EXEC_FUNC=""
NUM_CORES=$(($(nproc)/2))
DEBFULLNAME="Daniel Finimundi"
DEBEMAIL="daniel@finimundi.com"

mkdir -p "${LOG_PATH}"

usage()
{
    echo "Usage: $0 [ -c | --clean ] [ -f | --force-sync ]
                    [ --arch ARCH ]
                    [ --git URL ]
                    [ -b | --branch BRANCH ]
                    [ -j CORES ]
                    [ --skip-patches ]
                    [ -h | --help ]"
}

process_options()
{
    if [ "$VALID_ARGS" != 0 ]; then
        usage
        exit 1
    fi

    eval set -- "${PARSED_ARGS}"

    while true; do
        case "$1" in
            --arch )
                KERNEL_ARCH="$2"
                shift 2
                ;;
            --git )
                KERNEL_URL="$2"
                shift 2
                ;;
            -b | --branch )
                KERNEL_BRANCH="$2"
                shift 2
                ;;
            -c | --clean )
                CLEAN_KERNEL="1"
                shift 1
                ;;
            -f | --force-sync )
                KERNEL_FORCE_SYNC="1"
                shift 1
                ;;
            --skip-patches )
                SKIP_PATCHES="1"
                shift 1
                ;;
            -j )
                case "$2" in
                    x|X) NUM_CORES=$(nproc) ;;
                    *) NUM_CORES="$2" ;;
                esac
                shift 2
                ;;
            -h | --help )
                usage
                exit 0
                ;;
            -- )
                EXEC_FUNC="$2"
                shift 2
                break
                ;;
            *) usage; exit 1 ;;
        esac
    done

    case "${KERNEL_ARCH}" in
        arm | armhf )
            export ARCH="arm"
            export CROSS_COMPILE="arm-linux-gnueabihf-"
            export KERNEL="kernel7l-wp"
            KERNEL_IMAGE="zImage"
            WLANPI_DEFCONFIG="wlanpi_v7l_defconfig"
            ;;
        arm64 )
            export ARCH="arm64"
            export CROSS_COMPILE="aarch64-linux-gnu-"
            export KERNEL="kernel8-wp"
            KERNEL_IMAGE="Image"
            WLANPI_DEFCONFIG="wlanpi_v8_defconfig"
            ;;
        * )
            log "error" "Arch ${KERNEL_ARCH} not recognized."
            ;;
    esac

    log "ok" "Configs used:"
    echo "\
KERNEL_URL="${KERNEL_URL}"
KERNEL_BRANCH="${KERNEL_BRANCH}"
KERNEL_ARCH="${KERNEL_ARCH}"
KERNEL_DEFCONFIG="${KERNEL_DEFCONFIG}"
KERNEL_FORCE_SYNC="${KERNEL_FORCE_SYNC}"
CLEAN_KERNEL="${CLEAN_KERNEL}"
NUM_CORES="${NUM_CORES}"
"
}

run_all()
{
    download_source

    if [ "${CLEAN_KERNEL}" == "1" ]; then
        clean_kernel
    fi

    if [ "${SKIP_PATCHES}" != "1" ]; then
        apply_patches
    fi

    generate_config
    build_kernel
    copy_output
    build_package

    log "ok" "All done, enjoy :)"
}

build_kernel()
{
    pushd "${KERNEL_PATH}" >/dev/null

    log "ok" "Compile kernel"
    make -j${NUM_CORES} ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" "${KERNEL_IMAGE}" modules dtbs | tee "${LOG_PATH}"/compilation.log 2>&1

    log "ok" "Finished"

    popd >/dev/null
}

copy_output()
{
    pushd "${KERNEL_PATH}" >/dev/null

    log "ok" "Copying generated files to output directory"

    mkdir -p "${OUTPUT_PATH}/root"
    mkdir -p "${OUTPUT_PATH}/boot/overlays"

    env PATH="${PATH}" make -j${NUM_CORES} ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" INSTALL_MOD_PATH="${OUTPUT_PATH}/root" modules_install | tee "${LOG_PATH}"/modules_install.log 2>&1

    cp "${KERNEL_PATH}/arch/${ARCH}/boot/${KERNEL_IMAGE}" "${OUTPUT_PATH}/boot/${KERNEL}.img"
    cp "${KERNEL_PATH}/arch/${ARCH}/boot/dts/overlays/"*.dtb* "${OUTPUT_PATH}/boot/overlays/"
    cp "${KERNEL_PATH}/arch/${ARCH}/boot/dts/overlays/README"  "${OUTPUT_PATH}/boot/overlays/"
    cp "${SCRIPT_PATH}/debian/COPYING.linux" "${OUTPUT_PATH}/boot/"
    if [ "${ARCH}" == "arm64" ]; then
        cp "${KERNEL_PATH}"/arch/${ARCH}/boot/dts/broadcom/*.dtb "${OUTPUT_PATH}/boot/"
    else
        cp "${KERNEL_PATH}"/arch/${ARCH}/boot/dts/*.dtb "${OUTPUT_PATH}/boot/"
    fi

    popd >/dev/null
}

build_package()
{
    log "ok" "Building package"

    DATE="$(cd ${KERNEL_PATH}; git show -s --format=%ct HEAD)"
    RELEASE="$(date -d "@$DATE" -u +1.%Y%m%d)"
    DEBVER="1:${RELEASE}-1"

    (cd debian; ./gen_bootloader_postinst_preinst.sh)
    dch "Kernel version ${KERNEL_VERSION}"
    dch -v "$DEBVER" -D bullseye --force-distribution

    dpkg-buildpackage -us -uc
}

apply_patches()
{
    pushd "${KERNEL_PATH}" >/dev/null

    patches="$(find "${PATCHES_PATH}" -name "*.patch")"

    if [ "${patches}" == "" ]; then
        log "ok" "No patches to apply"
        popd >/dev/null
        return
    fi

    log "ok" "Will apply patches:"
    echo "${patches}"

    for patch in "${patches[@]}"; do
        if [ ! -f "${patch}" ]; then
            continue
        fi

        patch_name="$(basename "${patch}")"
        if patch --no-backup-if-mismatch --silent --batch -R --dry-run -p1 -N < "${patch}"; then
            log "warn" "Patch already applied, skipping ${patch_name}"
            continue
        fi

        log "ok" "Applying patch ${patch_name}"
        patch --no-backup-if-mismatch --silent --batch -p1 -N < "${patch}"

        if [ $? -ne 0 ]; then
            log "error" "Failed applying patch. Please fix it before trying again."
            exit 2
        fi
    done

    popd >/dev/null
}

generate_config()
{
    cp  "${SCRIPT_PATH}/${WLANPI_DEFCONFIG}" "${KERNEL_PATH}/arch/${ARCH}/configs/"

    pushd "${KERNEL_PATH}" >/dev/null

    log "ok" "Customize defconfig"
    scripts/kconfig/merge_config.sh "${KERNEL_PATH}"/arch/"${ARCH}"/configs/{${KERNEL_DEFCONFIG},${WLANPI_DEFCONFIG}} | tee "${LOG_PATH}"/update-config.log 2>&1

    if grep -q "Actual value:" "${LOG_PATH}"/update-config.log; then
        log "error" "Error updating defconfig. See above log to check which configs had conflicts."
        exit 1
    fi

    popd >/dev/null
}

download_source()
{
    if [ ! -d "${KERNEL_PATH}" ]; then
        log "ok" "Downloading kernel source from ${KERNEL_URL}, branch ${KERNEL_BRANCH}"
        git clone --depth=1 -b "${KERNEL_BRANCH}" "${KERNEL_URL}" "${KERNEL_PATH}" | tee "${LOG_PATH}"/clone.log 2>&1
    elif [ "${KERNEL_FORCE_SYNC}" == "1" ]; then
        log "ok" "Fetching new kernel version on branch ${KERNEL_BRANCH}"
        pushd "${KERNEL_PATH}" >/dev/null

        git fetch -q --depth 1 origin "${KERNEL_BRANCH}" | tee "${LOG_PATH}"/force-update-fetch.log 2>&1
        git co -B "${KERNEL_BRANCH}" origin/"${KERNEL_BRANCH}" | tee "${LOG_PATH}"/force-update-checkout.log 2>&1

        if [ $? -ne 0 ]; then
            log "error" "Couldn't checkout to new kernel version. Try setting variable CLEAN_KERNEL to reset the workspace"
            exit 3
        fi

        KERNEL_VERSION="$(sed -n "2,4p" "${KERNEL_PATH}/Makefile" | cut -d' ' -f3 | tr '\n' '.' | sed "s/.$/\n/")"
        log "ok" "Using kernel version ${KERNEL_VERSION}"

        popd >/dev/null
    else
        log "warn" "Kernel already downloaded. Please use --force-sync if you want to update it."
    fi
}

clean_kernel()
{
    pushd "${KERNEL_PATH}" >/dev/null

    log "ok" "Reseting kernel to upstream original code"

    make -j${NUM_CORES} ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" clean
    git clean -fdx
    git reset --hard
    git co -B "${KERNEL_BRANCH}" origin/"${KERNEL_BRANCH}"

    popd >/dev/null
}

log()
{
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    ORANGE='\033[0;33m'
    NC='\033[0m'

    if [ "$1" == "ok" ]; then
        echo -en "${GREEN}[ OK ]${NC} "
    elif [ "$1" == "error" ]; then
        echo -en "${RED}[ ERROR ]${NC} "
    elif [ "$1" == "warn" ]; then
        echo -en "${ORANGE}[ WARN ]${NC} "
    fi
    echo "$2"
}

process_options

if [ -z "${EXEC_FUNC}" ]; then
    run_all 2>&1 | tee "${LOG_PATH}"/full-log.log 2>&1
else
    eval "${EXEC_FUNC}" 2>&1 | tee "${LOG_PATH}"/func-log.log 2>&1
fi

