#!/bin/bash

BOOT_PATH="../output/boot"

if ! [ -d ${BOOT_PATH} ]; then
  printf "Can't find boot dir. Run from debian subdir\n"
  exit 1
fi

BUILD_ARMHF="0"
BUILD_ARM64="0"
case "$1" in
    *armhf*)
        BUILD_ARMHF="1"
        ;;&
    *arm64*)
        BUILD_ARM64="1"
        ;;
esac

KERNEL_IMAGES="$1"
KERNEL_IMAGES=$(echo "${KERNEL_IMAGES}" | sed "s/armhf/${BOOT_PATH//\//\\\/}\/kernel7l-wp.img/")
KERNEL_IMAGES=$(echo "${KERNEL_IMAGES}" | sed "s/arm64/${BOOT_PATH//\//\\\/}\/kernel8-wp.img/")
KERNEL_IMAGES=${KERNEL_IMAGES//,/ }
echo "KERNEL_IMAGES = ${KERNEL_IMAGES}"
echo "BUILD_ARMHF = ${BUILD_ARMHF}"
echo "BUILD_ARM64 = ${BUILD_ARM64}"

version="$(sed -n "2,4p" ../cache/kernel/Makefile | cut -d' ' -f3 | tr '\n' '.' | sed "s/.$/\n/")"

NEW_SIZE="$(du -cm ${BOOT_PATH}/*.dtb ${BOOT_PATH}/kernel*.img ${BOOT_PATH}/COPYING.linux ${BOOT_PATH}/overlays/* | tail -n1 | cut -f1)"

printf "#!/bin/sh -e\n\n" | tee wlanpi-kernel.postinst > wlanpi-kernel.preinst

cat <<EOF >> wlanpi-kernel.postinst
get_file_list() {
  cat /var/lib/dpkg/info/wlanpi-kernel.md5sums /var/lib/dpkg/info/wlanpi-kernel.md5sums 2> /dev/null | awk '/ boot/ {print "/"\$2}'
}

get_filtered_file_list() {
  for file in \$(get_file_list); do
    if [ -f "\$file" ]; then
      echo "\$file"
    fi
  done
}

get_available_space() {
  INSTALLED_SPACE="\$(get_filtered_file_list | xargs -r du -cm 2> /dev/null | tail -n1 | cut -f1)"
  FREE_SPACE="\$(df -m /boot | awk 'NR==2 {print \$4}')"
  echo \$(( INSTALLED_SPACE + FREE_SPACE ))
}

is_pifour() {
  grep -q "^Revision\s*:\s*[ 123][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]11[0-9a-fA-F]$" /proc/cpuinfo
  return \$?
}

if [ "\$(get_available_space)" -lt "$NEW_SIZE" ]; then
  echo "You do not have enough space in /boot to install this package."
  SKIP_FILES=1
  if is_pifour; then
    SKIP_PI4=0
    echo "Only adding Pi 4 support"
  else
    SKIP_PI4=1
    echo "Skipping Pi 4 support"
  fi
fi

EOF

printf "mkdir -p /usr/share/rpikernelhack/overlays\n" >> wlanpi-kernel.preinst
printf "mkdir -p /boot/overlays\n" >> wlanpi-kernel.preinst

cat <<EOF >> wlanpi-kernel.postinst
if [ "\$SKIP_FILES" != "1" ] || [ "\${SKIP_PI4}" = "0" ]; then
EOF
for FN in ${KERNEL_IMAGES}; do
  if [ -f "$FN" ]; then
    FN=${FN##${BOOT_PATH}/}
    cat << EOF >> wlanpi-kernel.postinst
  if [ -f /usr/share/rpikernelhack/$FN ]; then
    rm -f /boot/$FN
    dpkg-divert --package rpikernelhack --rename --remove /boot/$FN
    sync
  fi
EOF
  printf "dpkg-divert --package rpikernelhack --rename --divert /usr/share/rpikernelhack/%s /boot/%s\n" "$FN" "$FN" >> wlanpi-kernel.preinst
  fi
done

cat <<EOF >> wlanpi-kernel.postinst
fi

EOF

for FN in "${BOOT_PATH}"/*.dtb ${BOOT_PATH}/COPYING.linux "${BOOT_PATH}"/overlays/*; do
  if [ -f "$FN" ]; then
    FN=${FN#${BOOT_PATH}/}
    cat << EOF >> wlanpi-kernel.postinst
if [ -f /usr/share/rpikernelhack/$FN ]; then
  rm -f /boot/$FN
  dpkg-divert --package rpikernelhack --rename --remove /boot/$FN
  sync
fi
EOF
  printf "dpkg-divert --package rpikernelhack --rename --divert /usr/share/rpikernelhack/%s /boot/%s\n" "$FN" "$FN" >> wlanpi-kernel.preinst
  fi
done

cat <<EOF >> wlanpi-kernel.preinst
if [ -f /etc/default/wlanpi-kernel ]; then
  . /etc/default/wlanpi-kernel
  INITRD=\${INITRD:-"No"}
  export INITRD
  RPI_INITRD=\${RPI_INITRD:-"No"}
  export RPI_INITRD
fi
if [ -d "/etc/kernel/preinst.d" ]; then
EOF
if [ $BUILD_ARMHF -eq 1 ]; then
cat <<EOF >> wlanpi-kernel.preinst
  run-parts -v --report --exit-on-error --arg=${version}-v7l+ --arg=/boot/kernel7l-wp.img /etc/kernel/preinst.d
EOF
fi
if [ $BUILD_ARM64 -eq 1 ]; then
cat <<EOF >> wlanpi-kernel.preinst
  run-parts -v --report --exit-on-error --arg=${version}-v8+ --arg=/boot/kernel8-wp.img /etc/kernel/preinst.d
EOF
fi
cat <<EOF >> wlanpi-kernel.preinst
fi
if [ -d "/etc/kernel/preinst.d/${version}-v7l+" ]; then
  run-parts -v --report --exit-on-error --arg=${version}-v7l+ --arg=/boot/kernel7l-wp.img /etc/kernel/preinst.d/${version}-v7l+
fi
if [ -d "/etc/kernel/preinst.d/${version}-v8+" ]; then
  run-parts -v --report --exit-on-error --arg=${version}-v8+ --arg=/boot/kernel8-wp.img /etc/kernel/preinst.d/${version}-v8+
fi
EOF

cat <<EOF >> wlanpi-kernel.postinst
if [ -f /etc/default/wlanpi-kernel ]; then
  . /etc/default/wlanpi-kernel
  INITRD=\${INITRD:-"No"}
  export INITRD
  RPI_INITRD=\${RPI_INITRD:-"No"}
  export RPI_INITRD

fi
if [ -d "/etc/kernel/postinst.d" ]; then
EOF
if [ $BUILD_ARMHF -eq 1 ]; then
cat <<EOF >> wlanpi-kernel.postinst
  run-parts -v --report --exit-on-error --arg=${version}-v7l+ --arg=/boot/kernel7l-wp.img /etc/kernel/postinst.d
EOF
fi
if [ $BUILD_ARM64 -eq 1 ]; then
cat <<EOF >> wlanpi-kernel.postinst
  run-parts -v --report --exit-on-error --arg=${version}-v8+ --arg=/boot/kernel8-wp.img /etc/kernel/postinst.d
EOF
fi
cat <<EOF >> wlanpi-kernel.postinst
fi
if [ -d "/etc/kernel/postinst.d/${version}-v7l+" ]; then
  run-parts -v --report --exit-on-error --arg=${version}-v7l+ --arg=/boot/kernel7l-wp.img /etc/kernel/postinst.d/${version}-v7l+
fi
if [ -d "/etc/kernel/postinst.d/${version}-v8+" ]; then
  run-parts -v --report --exit-on-error --arg=${version}-v8+ --arg=/boot/kernel8-wp.img /etc/kernel/postinst.d/${version}-v8+
fi
EOF

cat <<EOF >> wlanpi-kernel.postinst
if [ -d /usr/share/rpikernelhack/overlays ]; then
  rmdir --ignore-fail-on-non-empty /usr/share/rpikernelhack/overlays
fi
EOF

cat <<EOF >> wlanpi-kernel.postinst
if [ -d /usr/share/rpikernelhack ]; then
  rmdir --ignore-fail-on-non-empty /usr/share/rpikernelhack
fi

touch /run/reboot-required
EOF

for pkg in wlanpi-kernel; do
cat << EOF >> "${pkg}.postinst"
if ! grep -qs "$pkg" /run/reboot-required.pkgs; then
  echo "$pkg" >> /run/reboot-required.pkgs
fi
EOF
done

printf "#DEBHELPER#\n" | tee -a wlanpi-kernel.postinst >> wlanpi-kernel.preinst

printf "#!/bin/sh\n" > wlanpi-kernel.prerm
printf "#!/bin/sh\n" > wlanpi-kernel.postrm
#printf "#!/bin/sh\n" > wlanpi-kernel-headers.postinst

cat <<EOF >> wlanpi-kernel.prerm
if [ -f /etc/default/wlanpi-kernel ]; then
  . /etc/default/wlanpi-kernel
  INITRD=\${INITRD:-"No"}
  export INITRD
  RPI_INITRD=\${RPI_INITRD:-"No"}
  export RPI_INITRD

fi
if [ -d "/etc/kernel/prerm.d" ]; then
EOF
if [ $BUILD_ARMHF -eq 1 ]; then
cat <<EOF >> wlanpi-kernel.prerm
  run-parts -v --report --exit-on-error --arg=${version}-v7l+ --arg=/boot/kernel7l-wp.img /etc/kernel/prerm.d
EOF
fi
if [ $BUILD_ARM64 -eq 1 ]; then
cat <<EOF >> wlanpi-kernel.prerm
  run-parts -v --report --exit-on-error --arg=${version}-v8+ --arg=/boot/kernel8-wp.img /etc/kernel/prerm.d
EOF
fi
cat <<EOF >> wlanpi-kernel.prerm
fi
if [ -d "/etc/kernel/prerm.d/${version}-v7l+" ]; then
  run-parts -v --report --exit-on-error --arg=${version}-v7l+ --arg=/boot/kernel7l-wp.img /etc/kernel/prerm.d/${version}-v7l+
fi
if [ -d "/etc/kernel/prerm.d/${version}-v8+" ]; then
  run-parts -v --report --exit-on-error --arg=${version}-v8+ --arg=/boot/kernel8-wp.img /etc/kernel/prerm.d/${version}-v8+
fi
EOF

cat <<EOF >> wlanpi-kernel.postrm
if [ -f /etc/default/wlanpi-kernel ]; then
  . /etc/default/wlanpi-kernel
  INITRD=\${INITRD:-"No"}
  export INITRD
  RPI_INITRD=\${RPI_INITRD:-"No"}
  export RPI_INITRD

fi
if [ -d "/etc/kernel/postrm.d" ]; then
EOF
if [ $BUILD_ARMHF -eq 1 ]; then
cat <<EOF >> wlanpi-kernel.postrm
  run-parts -v --report --exit-on-error --arg=${version}-v7l+ --arg=/boot/kernel7l-wp.img /etc/kernel/postrm.d
EOF
fi
if [ $BUILD_ARM64 -eq 1 ]; then
cat <<EOF >> wlanpi-kernel.postrm
  run-parts -v --report --exit-on-error --arg=${version}-v8+ --arg=/boot/kernel8-wp.img /etc/kernel/postrm.d
EOF
fi
cat <<EOF >> wlanpi-kernel.postrm
fi
if [ -d "/etc/kernel/postrm.d/${version}-v7l+" ]; then
  run-parts -v --report --exit-on-error --arg=${version}-v7l+ --arg=/boot/kernel7l-wp.img /etc/kernel/postrm.d/${version}-v7l+
fi
if [ -d "/etc/kernel/postrm.d/${version}-v8+" ]; then
  run-parts -v --report --exit-on-error --arg=${version}-v8+ --arg=/boot/kernel8-wp.img /etc/kernel/postrm.d/${version}-v8+
fi
EOF

# TODO: build headers
#cat <<EOF >> wlanpi-kernel-headers.postinst
#if [ -f /etc/default/wlanpi-kernel ]; then
  #. /etc/default/wlanpi-kernel
  #INITRD=\${INITRD:-"No"}
  #export INITRD
  #RPI_INITRD=\${RPI_INITRD:-"No"}
  #export RPI_INITRD
#fi
#if [ -d "/etc/kernel/header_postinst.d" ]; then
  #run-parts -v --verbose --exit-on-error --arg=${version}-v7l+ /etc/kernel/header_postinst.d
  #run-parts -v --verbose --exit-on-error --arg=${version}-v8+ /etc/kernel/header_postinst.d
#fi
#
#if [ -d "/etc/kernel/header_postinst.d/${version}-v7l+" ]; then
  #run-parts -v --verbose --exit-on-error --arg=${version}-v7l+ /etc/kernel/header_postinst.d/${version}-v7l+
#fi
#if [ -d "/etc/kernel/header_postinst.d/${version}-v8+" ]; then
  #run-parts -v --verbose --exit-on-error --arg=${version}-v8+ /etc/kernel/header_postinst.d/${version}-v8+
#fi
#EOF

printf "#DEBHELPER#\n" >> wlanpi-kernel.prerm
printf "#DEBHELPER#\n" >> wlanpi-kernel.postrm
#printf "#DEBHELPER#\n" >> wlanpi-kernel-headers.postinst
