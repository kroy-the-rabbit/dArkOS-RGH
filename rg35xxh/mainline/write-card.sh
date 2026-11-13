#!/bin/sh
# Write the dArkOS mainline card. Run as root: pkexec sh rg35xxh/mainline/write-card.sh
# Writes: MBR, ROCKNIX u-boot and FAT boot partition (p1), 12 GiB dArkOS ext4
# root (p2), fresh exFAT EASYROMS (p3).
set -e
D=/dev/sdd
H=${W:-$(dirname "$(readlink -f "$0")")/work}
SECTORS=123473920
[ "$(blockdev --getsz $D)" = "$SECTORS" ] || { echo "$D is not the 64 GB card ($(blockdev --getsz $D) sectors); stopping"; exit 1; }
if grep -q "^$D" /proc/mounts; then echo "$D has mounted partitions; unmount first"; exit 1; fi
echo "1/4 boot area"
dd if="$H/boot-area.img" of=$D bs=1M conv=fsync status=none
blockdev --rereadpt $D; sleep 2
[ "$(blockdev --getsz ${D}2)" = 25165824 ] || { echo "p2 size wrong after reread"; exit 1; }
echo "2/4 rootfs (12 GiB, several minutes)"
dd if="$H/rootfs.ext4" of=${D}2 bs=4M conv=fsync status=progress
echo "3/4 EASYROMS"
grep -q "^${D}3 " /proc/mounts && umount ${D}3
mkfs.exfat -L EASYROMS ${D}3 >/dev/null
echo "4/4 sync"
sync
echo "done"
