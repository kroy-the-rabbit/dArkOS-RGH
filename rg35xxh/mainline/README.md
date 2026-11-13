# dArkOS on the RG35XX-H, mainline kernel

Anbernic RG35XX-H (Allwinner H700, LPDDR4) card with the ROCKNIX mainline boot chain and a dArkOS RK3566 userspace.

| Partition | Content |
|---|---|
| sector 16 | ROCKNIX u-boot (LPDDR4) |
| p1 FAT `DARKBOOT`, 256 MiB | ROCKNIX `KERNEL` (Linux 7.2), `dtb.img`, `device_trees/`, `extlinux/` |
| p2 ext4, 12 GiB | dArkOS trixie (from the RG353V image) |
| p3 exFAT `EASYROMS` | ROMs |

MBR disk id `4441524b`; root and fstab use `PARTUUID`.

## Build

```
podman build -t localhost/guestfs:44 rg35xxh/guestfs   # first time only
rg35xxh/mainline/build.sh ROCKNIX-H700.aarch64-20261101-DDR4.img.gz MustardOS_RG35XX-H_2601.1_FUNKY_JACARANDA-bc38efa0.img.gz dArkOS_RG353v_trixie_08282026.img
pkexec sh rg35xxh/mainline/write-card.sh [work dir]     # card must be /dev/sdd, 64 GB
```

`DTB=sun50i-h700-anbernic-rg35xx-h-rev6-panel.dtb` selects the rev6 panel. On a built card, copy it over `dtb.img` on p1.

## Boot

| Step | Detail |
|---|---|
| u-boot | extlinux on the bootable FAT partition |
| Kernel | `rdinit=/nonexistent` skips the built-in ROCKNIX initramfs; `root=PARTUUID=4441524b-02` |
| `rootdir.cpio` | Second initramfs with an empty `/root`, the mount point for `root=`; missing from the ROCKNIX one |
| `/init` | adbd on the USB gadget (serial `darkos-h700`), then systemd. Log: `/var/log/h700-init.log` |

## Build changes to the dArkOS root

| Path | Change |
|---|---|
| `/usr/lib/modules/7.2.0`, `/usr/lib/firmware` | From ROCKNIX `kernel-overlays/base` (rtw88, rtl_bt, panels, regulatory.db) |
| `libEGL.so.1.1.0`, `libGLESv2.so.2.1.0`, `libGLESv1_CM.so.1.2.0`, `libgbm.so.1.0.0` | Real files restored from the installed Debian packages; dArkOS links them to `libMali.so` |
| `libmali.so.1` | Shim linking Mesa EGL, GLES 2, GLES 1 and gbm (`malishim.c`); blob link kept as `libmali.so.1.rockchip` |
| `libEGL.so`, `libGLESv2.so`, `libGLESv3.so.3`, `libGLESv1_CM.so`, `libgbm.so`, `libmali.so` | Point at Mesa or the shim |
| `libSDL2-2.0.so.0` | Debian SDL 2.32.4; dArkOS SDL 2.32.10 (crashes in Mesa EGL init) moved to `/opt/darkos-sdl2` |
| `/etc/emulationstation/es_input.cfg` | Adds `H700 Gamepad` |
| `~/.config/retroarch{,32}/autoconfig/udev/H700 Gamepad.cfg` | RetroArch binds |
| `/etc/fstab` | p2 root, p3 `/roms` |
| `/usr/local/bin/h700-firstboot.sh`, `firstboot.service` | Fills `/roms`; replaces the RK repartition script |
| `/usr/local/bin/adbd` | From muOS |
| `/usr/local/bin/panel_set.sh` | Moved to `panel_set.sh.rk3566`: sun4i-drm has no panel colour properties, so EmulationStation hides that menu. `shutdowntasks.service.d/h700.conf` drops its shutdown save |

`H700 Gamepad` button ids match the RG353V `retrogame_joypad`: B 0, A 1, X 2, Y 3, L1 4, R1 5, L2 6, R2 7, Select 8, Start 9, Menu 10, L3 11, R3 12, d-pad 13 to 16.
