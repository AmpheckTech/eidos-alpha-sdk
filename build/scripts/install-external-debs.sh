#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="${SDK_ROOT:-$(realpath "$SCRIPT_DIR/../..")}"
BOARD_DIR="${BOARD_DIR:-$SDK_ROOT/boards/ampheck/eidos-alpha}"
ROOTFS_ROOT="${ROOTFS_ROOT:-$SDK_ROOT/output/rootfs/root}"
COMMON_DEB_DIR="${COMMON_DEB_DIR:-$SDK_ROOT/common/packages/debs}"
BOARD_DEB_DIR="${BOARD_DEB_DIR:-$BOARD_DIR/packages/debs}"
TARGET_DEB_DIR="/tmp/eidos-packages"

sudo_run()
{
	if [ "$(id -u)" -eq 0 ]; then
		"$@"
	else
		sudo "$@"
	fi
}

cleanup()
{
	sudo_run rm -f "$ROOTFS_ROOT/run/qemu-aarch64-static"
}
trap cleanup EXIT

[ -x "$ROOTFS_ROOT/bin/bash" ] || {
	echo "rootfs is not bootstrapped: $ROOTFS_ROOT" >&2
	exit 1
}

deb_dirs=()
for dir in "$COMMON_DEB_DIR" "$BOARD_DEB_DIR"; do
	[ -d "$dir" ] && deb_dirs+=("$dir")
done
mapfile -d '' -t debs < <(
	[ "${#deb_dirs[@]}" -eq 0 ] ||
		find "${deb_dirs[@]}" -maxdepth 1 \
			-type f -name '*_arm64.deb' -print0 | sort -z
)
if [ "${#debs[@]}" -eq 0 ]; then
	echo "No external debs found; skipping"
	exit 0
fi

declare -A seen_packages=()
for deb in "${debs[@]}"; do
	package="$(dpkg-deb -f "$deb" Package)"
	if [ -n "${seen_packages[$package]:-}" ]; then
		echo "duplicate prebuilt deb package: $package" >&2
		exit 1
	fi
	seen_packages[$package]=1
done

echo "Installing external debs into rootfs"
sudo_run install -D -m 0755 /usr/bin/qemu-aarch64-static \
	"$ROOTFS_ROOT/run/qemu-aarch64-static"
sudo_run rm -rf "$ROOTFS_ROOT$TARGET_DEB_DIR"
sudo_run mkdir -p "$ROOTFS_ROOT$TARGET_DEB_DIR"
for deb in "${debs[@]}"; do
	sudo_run cp "$deb" "$ROOTFS_ROOT$TARGET_DEB_DIR/"
done

sudo_run chroot "$ROOTFS_ROOT" /run/qemu-aarch64-static /usr/bin/env \
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	DEBIAN_FRONTEND=noninteractive \
	/bin/sh -c 'dpkg -i "$1"/*.deb && rm -rf "$1"' sh "$TARGET_DEB_DIR"
cleanup
trap - EXIT
