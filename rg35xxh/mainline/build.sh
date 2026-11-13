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
# add the H700 Gamepad entry just before </inputList>
awk -v f="$R/es_input-h700.xml" '/<\/inputList>/{while ((getline l < f) > 0) print l} {print}' \
	es_input.cfg >ov/etc/emulationstation/es_input.cfg
grep -q 'deviceName="H700 Gamepad"' ov/etc/emulationstation/es_input.cfg
tar -C ov --owner=0 --group=0 --numeric-owner -cf overlay.tar .
guestfish --format=raw -a /w/rootfs.ext4 <<'EOF'
run
mount /dev/sda /
tar-in /w/overlay.tar /
chown 1000 1000 /home/ark
chmod 0700 /home/ark
chown 1000 1000 /etc/emulationstation/es_input.cfg
debug sh "chown -R 1000:1000 /sysroot/home/ark/.config/retroarch/autoconfig /sysroot/home/ark/.config/retroarch32/autoconfig"
# Panfrost through Mesa instead of the Rockchip Mali blob
ln-sf libEGL.so.1.1.0 /usr/lib/aarch64-linux-gnu/libEGL.so.1
ln-sf libGLESv2.so.2.1.0 /usr/lib/aarch64-linux-gnu/libGLESv2.so.2
ln-sf libGLESv1_CM.so.1.2.0 /usr/lib/aarch64-linux-gnu/libGLESv1_CM.so.1
ln-sf libgbm.so.1.0.0 /usr/lib/aarch64-linux-gnu/libgbm.so.1
ln-sf libEGL.so.1.1.0 /usr/lib/arm-linux-gnueabihf/libEGL.so.1
ln-sf libGLESv2.so.2.1.0 /usr/lib/arm-linux-gnueabihf/libGLESv2.so.2
ln-sf libGLESv1_CM.so.1.2.0 /usr/lib/arm-linux-gnueabihf/libGLESv1_CM.so.1
ln-sf libgbm.so.1.0.0 /usr/lib/arm-linux-gnueabihf/libgbm.so.1
EOF
printf 'run\nmount-ro /dev/sda /\n' >ls.gf
for a in aarch64-linux-gnu arm-linux-gnueabihf; do
	for l in libEGL.so.1 libGLESv2.so.2 libGLESv1_CM.so.1 libgbm.so.1; do
		echo "readlink /usr/lib/$a/$l" >>ls.gf
	done
	for l in libEGL.so.1.1.0 libGLESv2.so.2.1.0 libGLESv1_CM.so.1.2.0 libgbm.so.1.0.0; do
		echo "exists /usr/lib/$a/$l" >>ls.gf
	done
done
guestfish --ro --format=raw -a /w/rootfs.ext4 <ls.gf | tr '\n' ' '; echo
guestfish --ro --format=raw -a /w/rootfs.ext4 <ls.gf | grep -qx false && { echo "a Mesa library is missing"; exit 1; }
e2fsck -fn rootfs.ext4 >/dev/null

echo "== boot partition"
rm -f boot.img && truncate -s $((BOOT_SECTORS * 512)) boot.img
mkfs.fat -F 32 -n DARKBOOT boot.img >/dev/null
mcopy -i boot.img rk/KERNEL ::/KERNEL
mcopy -i boot.img "rk/device_trees/$DTB" ::/dtb.img
mcopy -s -i boot.img rk/device_trees ::/
mcopy -s -i boot.img "$R/boot/extlinux" ::/

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
