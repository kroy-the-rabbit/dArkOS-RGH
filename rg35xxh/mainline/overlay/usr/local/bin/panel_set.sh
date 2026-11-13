#!/bin/bash
# RG35XX-H (mainline sun4i-drm): the panel has no brightness, contrast,
# saturation or hue properties. Keep the values EmulationStation reads and
# sets in panel_settings.txt so its menus get numbers; they do not change
# the picture. Backlight is separate (/sys/class/backlight).
F=/home/ark/.config/panel_settings.txt
[ -f "$F" ] || printf 'brightness: 50\ncontrast: 50\nsaturation: 50\nhue: 50\n' >"$F"

get() {
	v=$(awk -v k="$1:" '$1 == k {print $2}' "$F")
	echo "${v:-50}"
}

put() {
	[[ "$2" =~ ^[0-9]+$ ]] || return 0
	if grep -q "^$1:" "$F"; then
		sed -i "s/^$1:.*/$1: $2/" "$F"
	else
		echo "$1: $2" >>"$F"
	fi
}

case "$1" in
	get_brightness | get_contrast | get_saturation | get_hue) get "${1#get_}" ;;
	set_brightness | set_contrast | set_saturation | set_hue) put "${1#set_}" "$2" ;;
	*) ;;
esac
exit 0
