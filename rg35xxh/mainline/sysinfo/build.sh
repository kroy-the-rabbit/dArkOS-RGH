#!/bin/sh
# Build h700-sysinfo (aarch64) in a Debian trixie container. Output: $1 (default ./h700-sysinfo)
set -e
D=$(cd "$(dirname "$0")" && pwd)
O=$(readlink -f "${1:-$D/h700-sysinfo}")
mkdir -p "$(dirname "$O")"
podman run --rm -v "$D":/src:ro,z -v "$(dirname "$O")":/out:z docker.io/arm64v8/debian:trixie sh -c "
	apt-get update -qq >/dev/null && apt-get install -y -qq gcc libc6-dev libsdl2-dev libsdl2-ttf-dev >/dev/null 2>&1
	gcc -O2 -Wall -o /out/$(basename "$O") /src/sysinfo.c \$(sdl2-config --cflags --libs) -lSDL2_ttf
	chown $(id -u):$(id -g) /out/$(basename "$O")"
