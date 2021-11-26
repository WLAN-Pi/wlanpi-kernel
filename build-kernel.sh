#!/bin/bash

SCRIPT_PATH="$(dirname $(realpath "$0"))"
KERNEL_PATH="${SCRIPT_PATH}/cache/kernel"
LOG_PATH="${SCRIPT_PATH}/logs"
PATCHES_PATH="${SCRIPT_PATH}/kernel-patches"

KERNEL_URL="https://github.com/raspberrypi/linux.git"
KERNEL_BRANCH="rpi-5.15.y"

mkdir -p "${LOG_PATH}"

run_all()
{
    download_source

    if [ "${CLEAN_KERNEL}" == "true" ]; then
        clean_kernel
    fi

    apply_patches
    generate_config
    build_kernel
}

build_kernel()
{
    pushd "${KERNEL_PATH}"

    log "ok" "Compile kernel"
    make -j4 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image modules dtbs | tee "${LOG_PATH}"/compilation.log 2>&1

    log "ok" "Make kernel package"
    make -j1 bindeb-pkg ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- DEBFULLNAME="Daniel Finimundi" DEBEMAIL="daniel@finimundi.com" | tee "${LOG_PATH}"/packaging.log 2>&1

    log "ok" "Finished"

    popd >/dev/null
}

apply_patches()
{
    pushd "${KERNEL_PATH}"

    patches="$(find "${PATCHES_PATH}" -name "*.patch")"

    log "ok" "Will apply patches:"
    echo "${patches}"

    for patch in "${patches[@]}"; do
        if patch --no-backup-if-mismatch --silent --batch -R --dry-run -p1 -N < "${patch}"; then
            log "warn" "Patch already applied, skipping ${patch}"
            continue
        fi

        log "ok" "Applying patch ${patch}"
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
    export ARCH=arm64
    export CROSS_COMPILE=aarch64-linux-gnu-
    export KERNEL=kernel8

    cp  "${SCRIPT_PATH}/wlanpi_defconfig" "${KERNEL_PATH}/arch/arm64/configs/"

    pushd "${KERNEL_PATH}"

    log "ok" "Customize defconfig"
    "${KERNEL_PATH}"/scripts/kconfig/merge_config.sh "${KERNEL_PATH}"/arch/arm64/configs/{bcm2711,wlanpi}_defconfig | tee "${LOG_PATH}"/update-config.log 2>&1

    if grep -q "Actual value:" "${LOG_PATH}"/update-config.log; then
        log "error" "Error updating defconfig. See above log to check which configs had conflicts."
        exit 1
    fi

    popd >/dev/null
}

download_source()
{
    log "ok" "Downloading kernel source from ${KERNEL_URL}, branch ${KERNEL_BRANCH}"

    if [ ! -d "${KERNEL_PATH}" ]; then
        git clone --depth=1 -b "${KERNEL_BRANCH}" "${KERNEL_URL}" "${KERNEL_PATH}" | tee "${LOG_PATH}"/clone.log 2>&1
    elif [ "${FORCE_UPDATE_KERNEL}" == "true" ]
        pushd "${KERNEL_PATH}"

        git fetch -q origin "${KERNEL_BRANCH}" | tee "${LOG_PATH}"/force-update-fetch.log 2>&1
        git co -B "${KERNEL_BRANCH}" origin/"${KERNEL_BRANCH}" | tee "${LOG_PATH}"/force-update-checkout.log 2>&1

        if [ $? -ne 0 ]; then
            log "error" "Couldn't checkout to new kernel version. Try setting variable CLEAN_KERNEL to reset the workspace"
            exit 3
        fi

        popd >/dev/null
    fi

    echo
}

clean_kernel()
{
    pushd "${KERNEL_PATH}"

    log "ok" "Reseting kernel to upstream original code"

    make -j4 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- clean
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

run_all

