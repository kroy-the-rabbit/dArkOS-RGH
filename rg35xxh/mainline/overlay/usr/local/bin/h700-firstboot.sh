#!/bin/bash
# H700 replacement for dArkOS /boot/firstboot.sh: the card is already
# partitioned, so populate EASYROMS (/roms) and disable itself.
exec >>/var/log/h700-firstboot.log 2>&1
echo "=== $(date)"
mountpoint -q /roms || mount /roms
if ! mountpoint -q /roms; then echo "/roms not mounted"; exit 1; fi
tar --no-same-permissions --no-same-owner --warning=no-timestamp -xf /roms.tar -C / && echo "roms.tar extracted"
mkdir -p /roms/themes && cp -r /tempthemes/. /roms/themes/ && echo "themes copied"
sync
rm -rf /tempthemes /roms.tar
systemctl disable firstboot.service
echo done
