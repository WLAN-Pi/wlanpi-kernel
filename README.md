# Build WLAN Pi kernel

Sync and build the Kernel for WLAN Pi.

Currently the script downloads the kernel source from Raspberry Pi Linux Github page and does a
checkout to specified branch.

Then it applies the patches from `kernel-patches` folder to this kernel, updates the default
defconfig with `wlanpi_defconfig`, builds the kernel and them packages it on .deb.

Usage:
```bash
./build-kernel.sh
```

To configure the architecture for the cross compilation, use flag `--arch` with the corresponding
arch desired (either `arm` or `arm64`). Default option is `arm` (32 bits).
```bash
./build-kernel.sh --arch arm64
```

To clean the kernel for a new compilation from scratch, use the flag `--clean`.
```bash
./build-kernel.sh --clean
```

Kernel will only be cloned the first time. If you want to sync again (git fetch) and force the
update to latest commit on branch, use the flag `--force-sync`.
```bash
./build-kernel.sh --force-sync
```

The force update might fail depending on the changes made on the kernel repository. In that case,
just use both clean and force update variables together.

To set a different kernel version, use the `--branch` option, which is the branch on kernel
repository (e.g. `rpi-5.13.y`, `rpi-5.15.y`, `rpi-5.16.y`). Default option is `rpi-5.15.y`.
```bash
./build-kernel.sh --branch rpi-5.16.y
```

To set the number of cores to be used on compilation, use `-j` flag followed by the number of cores.
The default value is half the cores in the system. If used as `-jX` it will use all cores.
```bash
./build-kernel.sh -jX
```
