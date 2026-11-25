#!/bin/bash
set -euo pipefail

arch="${1:-${RK_UBUNTU_ARCH:-arm64}}"
qemu="${2:-}"

case "$arch" in
	arm64) qemu="${qemu:-qemu-aarch64-static}" ;;
	armhf) qemu="${qemu:-qemu-arm-static}" ;;
	*) echo "Unsupported Ubuntu architecture: $arch" >&2; exit 1 ;;
esac

missing=
for tool in chroot curl dpkg-deb e2fsck mke2fs mount mountpoint sha256sum \
	findmnt flock tar zstd; do
	command -v "$tool" &>/dev/null || missing="$missing $tool"
done
command -v "$qemu" &>/dev/null || missing="$missing $qemu"
if [ "$(id -u)" -ne 0 ] && ! command -v sudo &>/dev/null; then
	missing="$missing sudo"
fi

if [ "$missing" ]; then
	echo "Missing Ubuntu rootfs build dependencies:$missing" >&2
	echo "Install qemu-user-static, e2fsprogs and curl on the host." >&2
	exit 1
fi
