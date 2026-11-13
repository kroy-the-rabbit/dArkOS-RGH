#!/bin/sh
# Build a dArkOS card for the Anbernic RG35XX-H (Allwinner H700) on a mainline
# kernel, without root.
#
# Bootloader, kernel, DTBs, modules and firmware come from a ROCKNIX H700 DDR4
# image (LPDDR4 boards), adbd from a muOS H700 image, userspace from a dArkOS
# RG353V image. Output in $W: boot-area.img (MBR, u-boot, FAT boot partition)
# and rootfs.ext4, written to the card by write-card.sh.
#
# usage: rg35xxh/mainline/build.sh <ROCKNIX-H700 DDR4 .img.gz> <muOS H700 .img.gz> <dArkOS RG353V .img> [card sectors]
set -e
ROCKNIX=$(readlink -f "$1")
MUOS=$(readlink -f "$2")
DARK=$(readlink -f "$3")
SECTORS=${4:-123473920}
R=$(cd "$(dirname "$0")" && pwd)
W=${W:-$R/work}
DTB=${DTB:-sun50i-h700-anbernic-rg35xx-h.dtb}
BOOT_START=32768
BOOT_SECTORS=524288    # 256 MiB FAT
ROOT_SECTORS=25165824  # 12 GiB ext4
DISKID=0x4441524b
GF=localhost/guestfs:44
DEB=docker.io/arm64v8/debian:trixie
mkdir -p "$W"
cd "$W"

guestfish() {
	podman run --rm -i --device /dev/kvm -v "$W":/w:z "$GF" guestfish "$@"
}

podman image exists "$GF" || podman build -t "$GF" "$R/../guestfs"

echo "== ROCKNIX: u-boot, kernel, DTBs, modules, firmware"
[ -f rocknix.img ] || zcat "$ROCKNIX" >rocknix.img
RO=$(sfdisk -d rocknix.img | awk -F'[=,]' '/rocknix.img1/{gsub(/ /,"",$2); print $2}')
RI="rocknix.img@@$((RO * 512))"
rm -rf rk && mkdir -p rk
mcopy -n -i "$RI" ::/KERNEL rk/KERNEL
mcopy -n -s -i "$RI" ::/device_trees rk/
[ -f rk-SYSTEM ] || mcopy -n -i "$RI" ::/SYSTEM rk-SYSTEM
podman run --rm -v "$W":/w:z "$DEB" sh -c "
	apt-get update -qq >/dev/null && apt-get install -y -qq squashfs-tools >/dev/null 2>&1
	unsquashfs -q -n -d /w/rk/sq /w/rk-SYSTEM usr/lib/kernel-overlays/base >/dev/null
	chown -R $(id -u):$(id -g) /w/rk"
KO=rk/sq/usr/lib/kernel-overlays/base/lib
KVER=$(ls "$KO/modules")

echo "== muOS: adbd"
[ -f muos-head.img ] || zcat "$MUOS" | dd bs=1M iflag=fullblock count=8500 status=none of=muos-head.img
debugfs -R 'dump /usr/bin/adbd adbd' "muos-head.img?offset=$((319488 * 512))" 2>/dev/null
[ -s adbd ]

echo "== dArkOS: btrfs root to ext4"
OFF=$(sfdisk -d "$DARK" | awk -F'[=,]' '/name="rootfs"/{gsub(/ /,"",$2); print $2}')
LEN=$(sfdisk -d "$DARK" | awk -F'[=,]' '/name="rootfs"/{gsub(/ /,"",$4); print $4}')
dd if="$DARK" bs=512 skip="$OFF" count="$LEN" status=none of=darkos-root.btrfs
rm -f rootfs.ext4 && truncate -s $((ROOT_SECTORS * 512)) rootfs.ext4
guestfish --format=raw -a /w/darkos-root.btrfs --format=raw -a /w/rootfs.ext4 <<'EOF'
run
mkfs ext4 /dev/sdb label:ROOTFS
mount /dev/sdb /
mkmountpoint /src
mount-ro /dev/sda /src
debug sh "cd /sysroot/src && tar --xattrs --acls -cpf - . | (cd /sysroot && tar --xattrs --acls -xpf -)"
umount /src
rmmountpoint /src
download /etc/emulationstation/es_input.cfg /w/es_input.cfg
EOF
tune2fs -O ^orphan_file rootfs.ext4 >/dev/null

echo "== overlay"
rm -rf ov && mkdir -p ov && cp -a "$R/overlay/." ov/
rm -f ov/var/log/journal/.keep
mkdir -p ov/usr/lib/modules ov/usr/lib/firmware ov/usr/local/bin ov/etc/emulationstation
cp -a "$KO/modules/$KVER" "ov/usr/lib/modules/$KVER"
cp -a "$KO/firmware/." ov/usr/lib/firmware/
install -m 755 adbd ov/usr/local/bin/adbd
# dArkOS replaces Mesa's EGL, GLES and gbm files with links to the Rockchip
# Mali blob. Restore the real files from the installed package versions, and
# replace libmali.so.1 with a shim that pulls in Mesa.
printf 'run\nmount-ro /dev/sda /\ndownload /var/lib/dpkg/status /w/rootfs-dpkg-status\n' |
	guestfish --ro --format=raw -a /w/rootfs.ext4
rm -rf mesa && mkdir -p mesa/debs
PKGS=$(for a in arm64 armhf; do for p in libegl1 libgles1 libgles2 libgbm1; do
	v=$(awk -v p="$p" -v a="$a" '/^Package: /{n=$2} /^Architecture: /{r=$2} /^Version: /{if (n==p && r==a) print $2}' rootfs-dpkg-status)
	[ -n "$v" ] && echo "$p:$a=$v"
done; done)
echo "$PKGS" | tr '\n' ' '; echo
cp "$R/malishim.c" mesa/
podman run --rm -v "$W":/w:z "$DEB" sh -c "
	dpkg --add-architecture armhf && apt-get update -qq >/dev/null
	cd /w/mesa/debs && apt-get download -q $(echo $PKGS) >/dev/null 2>&1
	for d in /w/mesa/debs/*.deb; do dpkg-deb -x \$d /w/ov; done
	rm -rf /w/ov/usr/share/doc /w/ov/usr/share/lintian
	apt-get install -y -qq gcc libc6-dev libegl-dev libgles-dev libgbm-dev >/dev/null 2>&1
	gcc -shared -fPIC -o /w/ov/usr/lib/aarch64-linux-gnu/libmali.so.1 /w/mesa/malishim.c \
		-Wl,-soname,libmali.so.1 -Wl,--no-as-needed -lEGL -lGLESv2 -lGLESv1_CM -lgbm
	chown -R $(id -u):$(id -g) /w/ov /w/mesa"
podman run --rm --platform linux/arm/v7 -v "$W":/w:z docker.io/arm32v7/debian:trixie sh -c "
	apt-get update -qq >/dev/null && apt-get install -y -qq gcc libc6-dev libegl-dev libgles-dev libgbm-dev >/dev/null 2>&1
	gcc -shared -fPIC -o /w/ov/usr/lib/arm-linux-gnueabihf/libmali.so.1 /w/mesa/malishim.c \
		-Wl,-soname,libmali.so.1 -Wl,--no-as-needed -lEGL -lGLESv2 -lGLESv1_CM -lgbm
	chown $(id -u):$(id -g) /w/ov/usr/lib/arm-linux-gnueabihf/libmali.so.1"
[ -s ov/usr/lib/aarch64-linux-gnu/libmali.so.1 ] && [ -s ov/usr/lib/arm-linux-gnueabihf/libmali.so.1 ]

tar -C ov --owner=0 --group=0 --numeric-owner -cf overlay.tar .
{
	printf 'run\nmount /dev/sda /\n'
	for a in aarch64-linux-gnu arm-linux-gnueabihf; do
		L=/usr/lib/$a
		# keep the blob's links reachable under a new name
		echo "ln-sf libMali.so $L/libmali.so.1.rockchip"
		echo "rm-f $L/libmali.so.1"
		# dArkOS SDL2 2.32.10 is built for the Mali blob; use Debian's
		echo "mkdir-p /opt/darkos-sdl2/$a"
		echo "mv $L/libSDL2-2.0.so.0.3200.10 /opt/darkos-sdl2/$a/libSDL2-2.0.so.0.3200.10"
	done
	echo "tar-in /w/overlay.tar /"
	for a in aarch64-linux-gnu arm-linux-gnueabihf; do
		L=/usr/lib/$a
		for l in libEGL.so:libEGL.so.1 libGLESv2.so:libGLESv2.so.2 libGLESv3.so.3:libGLESv2.so.2 \
			libGLESv1_CM.so:libGLESv1_CM.so.1 libgbm.so:libgbm.so.1 libmali.so:libmali.so.1 \
			libSDL2-2.0.so.0:libSDL2-2.0.so.0.3200.4 libSDL2.so:libSDL2-2.0.so.0; do
			echo "ln-sf ${l#*:} $L/${l%%:*}"
		done
	done
	echo "chown 1000 1000 /home/ark"
	echo "chmod 0700 /home/ark"
	echo "chown 1000 1000 /etc/emulationstation/es_input.cfg"
	echo 'debug sh "chown -R 1000:1000 /sysroot/home/ark/.config/retroarch/autoconfig /sysroot/home/ark/.config/retroarch32/autoconfig"'
} >ov.gf
guestfish --format=raw -a /w/rootfs.ext4 <ov.gf
{
	printf 'run\nmount-ro /dev/sda /\n'
	for a in aarch64-linux-gnu arm-linux-gnueabihf; do
		for f in libEGL.so.1.1.0 libGLESv2.so.2.1.0 libGLESv1_CM.so.1.2.0 libgbm.so.1.0.0 libmali.so.1 libSDL2-2.0.so.0.3200.4; do
			echo "is-file /usr/lib/$a/$f"
		done
	done
} >chk.gf
guestfish --ro --format=raw -a /w/rootfs.ext4 <chk.gf | tr '\n' ' '; echo
guestfish --ro --format=raw -a /w/rootfs.ext4 <chk.gf | grep -qx false && { echo "a Mesa or SDL library is missing"; exit 1; }
e2fsck -fn rootfs.ext4 >/dev/null

echo "== boot partition"
rm -f boot.img && truncate -s $((BOOT_SECTORS * 512)) boot.img
mkfs.fat -F 32 -n DARKBOOT boot.img >/dev/null
mcopy -i boot.img rk/KERNEL ::/KERNEL
mcopy -i boot.img "rk/device_trees/$DTB" ::/dtb.img
mcopy -s -i boot.img rk/device_trees ::/
mcopy -s -i boot.img "$R/boot/extlinux" ::/
# ROCKNIX's built-in initramfs has no /root, where the kernel mounts root=;
# u-boot loads this cpio as a second initramfs to add it.
mkdir -p rootdir/root && (cd rootdir && echo root | cpio -o -H newc -R 0:0 --quiet) >rootdir.cpio
mcopy -i boot.img rootdir.cpio ::/rootdir.cpio

echo "== card head"
rm -f card.img && truncate -s $((SECTORS * 512)) card.img
dd if=rocknix.img of=card.img bs=512 count=$BOOT_START conv=notrunc status=none
sfdisk --no-reread --no-tell-kernel card.img >/dev/null <<EOF
label: dos
label-id: $DISKID
start=$BOOT_START, size=$BOOT_SECTORS, type=c, bootable
start=$((BOOT_START + BOOT_SECTORS)), size=$ROOT_SECTORS, type=83
start=$((BOOT_START + BOOT_SECTORS + ROOT_SECTORS)), type=7
EOF
dd if=boot.img of=card.img bs=512 seek=$BOOT_START conv=notrunc status=none
dd if=card.img bs=512 count=$((BOOT_START + BOOT_SECTORS)) status=none of=boot-area.img
rm -f card.img
sfdisk -l boot-area.img 2>/dev/null | tail -4 || true
echo "built: $W/boot-area.img $W/rootfs.ext4"
