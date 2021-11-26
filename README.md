# Build WLAN Pi kernel

Sync and build the Kernel for WLAN Pi.

Currently the script downloads the kernel source from Raspberry Pi Linux Github page and does a
checkout to specified branch.

Then it applies the patches from `kernel-patches` folder to this kernel, updates the default
defconfig with `wlanpi_defconfig`, builds the kernel and them packages it on .deb.

This is a initial version, to be extended with more configuration options.

Usage:
```bash
./build-kernel.sh
```

To clean the kernel for a new compilation from scratch, just set environmental variable CLEAN_KERNEL
to true.
```bash
CLEAN_KERNEL=true ./build-kernel.sh
```

Kernel will only be cloned the first time. If you want to sync again (git fetch) and force the
update to latest commit on branch, set variable FORCE_UPDATE_KERNEL to true.
```bash
FORCE_UPDATE_KERNEL=true ./build-kernel.sh
```

The force update might fail depending on the changes made on the kernel repository. In that case,
just use both clean and force update variables together.

To be continued...
