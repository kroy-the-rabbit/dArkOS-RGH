#!/bin/sh
# Build the ROCKNIX H700 kernel (tag 20261101) with the RG35XX-H boot logo,
# without root. Same source, patches, DTS and config as the ROCKNIX image;
# config differences: no built-in initramfs. Modules include rocknix-joypad.
#
# usage: rg35xxh/mainline/kernel/build-kernel.sh <work dir>
# Output in <work dir>/kernel: Image, dtbs/, modules/lib/modules/<ver>
set -e
R=$(cd "$(dirname "$0")" && pwd)
W=$(readlink -f "${1:?usage: build-kernel.sh <work dir>}")
TAG=20261101
LINUX_VER=7.2
LINUX_SHA=f9fef3d14c0df53819026f4be74459835c2a0b0dcbf5b5bbd9ea19f0829402b3
JOY=005033d1ddd8746c771f2c81f1174f2d892541c9
FW=$W/rk/sq/usr/lib/kernel-overlays/base/lib/firmware
K=$W/kernel
mkdir -p "$K/src"
cd "$K/src"
[ -d "$FW" ] || { echo "run build.sh once first: ROCKNIX firmware missing at $FW"; exit 1; }

[ -f linux-$LINUX_VER.tar.xz ] || curl -fsSLO https://www.kernel.org/pub/linux/kernel/v7.x/linux-$LINUX_VER.tar.xz
echo "$LINUX_SHA  linux-$LINUX_VER.tar.xz" | sha256sum -c --quiet
[ -f joypad-$JOY.tar.gz ] || curl -fsSL -o joypad-$JOY.tar.gz https://github.com/hackbar/rocknix-joypad/archive/$JOY.tar.gz
if [ ! -d rocknix ]; then
	git clone -q --depth 1 --branch $TAG --filter=blob:none --sparse https://github.com/ROCKNIX/distribution rocknix
	git -C rocknix sparse-checkout set --no-cone /projects/ROCKNIX/packages/linux/ /projects/ROCKNIX/devices/H700/ /projects/ROCKNIX/config.xml
fi

rm -rf linux && mkdir linux && tar -xJf linux-$LINUX_VER.tar.xz -C linux --strip-components=1
rm -rf joypad && mkdir joypad && tar -xzf joypad-$JOY.tar.gz -C joypad --strip-components=1
# ROCKNIX scripts/unpack order for linux on H700: package mainline/, package <version>/, device patches
P=rocknix/projects/ROCKNIX
for p in $P/packages/linux/patches/mainline/*.patch $P/packages/linux/patches/$LINUX_VER/*.patch \
	$P/devices/H700/patches/linux/*.patch; do
	[ -f "$p" ] || continue
	patch -d linux -p1 -s --no-backup-if-mismatch <"$p" || { echo "patch failed: $p"; exit 1; }
done
# post_patch: device DTS
cp -a $P/devices/H700/linux/dts/. linux/arch/arm64/boot/dts/

# DTBs: the H700 DDR4 list in ROCKNIX config.xml
DTBS=$(awk '/<DDR4 /,/<\/DDR4>/' $P/config.xml | sed -n 's|.*<file>\(.*\)</file>.*|allwinner/\1.dtb|p' | tr '\n' ' ')

cp "$R/config-7.2.0-rocknix-$TAG" linux/.config
sed -i 's|^CONFIG_INITRAMFS_SOURCE=.*|CONFIG_INITRAMFS_SOURCE=""|' linux/.config
mkdir -p linux/external-firmware && cp -a "$FW/." linux/external-firmware/
# kernel boot logo: plain PPM, at most 224 colors
magick "$R/logo-rg35xxh.png" -colors 224 -depth 8 -compress none ppm:linux/drivers/video/logo/logo_linux_clut224.ppm

podman run --rm --pull=never --platform linux/amd64 -v "$K/src":/k:z docker.io/library/debian:bookworm-slim sh -ec "
	apt-get update -qq >/dev/null
	apt-get install -y -qq --no-install-recommends gcc-aarch64-linux-gnu gcc make bc bison flex libssl-dev \
		libelf-dev cpio kmod python3 rsync xz-utils >/dev/null 2>&1
	cd /k/linux
	M='make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- KBUILD_BUILD_USER=dArkOS KBUILD_BUILD_HOST=rg35xxh'
	\$M olddefconfig >/dev/null
	\$M -j\$(nproc) Image $DTBS modules >/k/make.log 2>&1 || { tail -40 /k/make.log; exit 1; }
	\$M -C /k/linux M=/k/joypad DEVICE=H700 modules >>/k/make.log 2>&1
	rm -rf /k/out && mkdir -p /k/out
	\$M INSTALL_MOD_PATH=/k/out/modules INSTALL_MOD_STRIP=1 modules_install >>/k/make.log 2>&1
	V=\$(\$M -s kernelrelease)
	mkdir -p /k/out/modules/lib/modules/\$V/rocknix-joypad
	cp /k/joypad/*.ko /k/out/modules/lib/modules/\$V/rocknix-joypad/
	aarch64-linux-gnu-strip --strip-debug /k/out/modules/lib/modules/\$V/rocknix-joypad/*.ko
	depmod -b /k/out/modules \$V
	rm -f /k/out/modules/lib/modules/\$V/build
	cp arch/arm64/boot/Image /k/out/Image
	mkdir -p /k/out/dtbs && for d in $DTBS; do cp arch/arm64/boot/dts/\$d /k/out/dtbs/; done
	echo \$V >/k/out/release
	chown -R 0:0 /k"
rm -rf "$K/Image" "$K/dtbs" "$K/modules" "$K/release"
mv "$K/src/out/"* "$K/"
echo "kernel $(cat "$K/release"): $K/Image, $(ls "$K/dtbs" | wc -l) dtbs, $(find "$K/modules" -name '*.ko' | wc -l) modules"
