#!/bin/bash

PARSED_ARGS=$(getopt -o cfb:j: --long clean,force-sync,branch: --long arch:,git: -- "$@")
VALID_ARGS=$?

SCRIPT_PATH="$(dirname $(realpath "$0"))"
KERNEL_PATH="${SCRIPT_PATH}/cache/kernel"
LOG_PATH="${SCRIPT_PATH}/logs"
PATCHES_PATH="${SCRIPT_PATH}/kernel-patches"

# Set default values for configurations
KERNEL_URL="https://github.com/raspberrypi/linux.git"
KERNEL_BRANCH="rpi-5.15.y"
KERNEL_ARCH="arm"
KERNEL_DEFCONFIG="bcm2711_defconfig"
WLANPI_DEFCONFIG="wlanpi_v7l_defconfig"
KERNEL_FORCE_SYNC="0"
CLEAN_KERNEL="0"
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
                    [ -j CORES ]"
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
            -j )
                case "$2" in
                    x|X) NUM_CORES=$(nproc) ;;
                    *) NUM_CORES="$2" ;;
                esac
                shift 2
                ;;
            -- ) shift; break ;;
            *) usage; break ;;
        esac
    done

    case "${KERNEL_ARCH}" in
        arm | armhf )
            export ARCH="arm"
            export CROSS_COMPILE="arm-linux-gnueabihf-"
            export KERNEL="kernel7l"
            KERNEL_IMAGE="zImage"
            WLANPI_DEFCONFIG="wlanpi_v7l_defconfig"
            ;;
        arm64 )
            export ARCH="arm64"
            export CROSS_COMPILE="aarch64-linux-gnu-"
            export KERNEL="kernel8"
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
    process_options

    download_source

    if [ "${CLEAN_KERNEL}" == "1" ]; then
        clean_kernel
    fi

    apply_patches
    generate_config
    build_kernel
}

build_kernel()
{
    pushd "${KERNEL_PATH}" >/dev/null

    log "ok" "Build and package kernel"
    make -j${NUM_CORES} bindeb-pkg ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" DEBFULLNAME="${DEBFULLNAME}" DEBEMAIL="${DEBEMAIL}" | tee "${LOG_PATH}"/packaging.log 2>&1

    log "ok" "Finished"

    popd >/dev/null
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

run_all | tee "${LOG_PATH}"/full-log.log 2>&1

