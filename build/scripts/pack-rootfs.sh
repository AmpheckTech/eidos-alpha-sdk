#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="${SDK_ROOT:-$(realpath "$SCRIPT_DIR/../..")}"
BOARD_FIRMWARE_DIR="${BOARD_FIRMWARE_DIR:-$SDK_ROOT/boards/ampheck/eidos-alpha/firmware}"
PARAMETER_FILE="${PARAMETER_FILE:-parameter-ubuntu-fit.txt}"
ROOTFS_ROOT="${1:-${ROOTFS_ROOT:-$SDK_ROOT/output/rootfs/root}}"
IMAGE="${2:-${ROOTFS_IMAGE:-$SDK_ROOT/output/rootfs/rootfs.ext4}}"
HEADROOM="${ROOTFS_IMAGE_HEADROOM:-512M}"
MIN_SIZE="${ROOTFS_IMAGE_MIN_SIZE:-1024M}"
LABEL="${ROOTFS_LABEL:-rootfs}"

if [ "$(id -u)" -eq 0 ]; then
	SUDO=
else
	SUDO=sudo
fi

size_mib()
{
	case "$1" in
		*[Mm]) printf '%s\n' "$((${1%[Mm]}))" ;;
		*[Gg]) printf '%s\n' "$((${1%[Gg]} * 1024))" ;;
		*)
			echo "unsupported size suffix: $1" >&2
			return 1
			;;
	esac
}

[ -x "$ROOTFS_ROOT/bin/bash" ] || {
	echo "rootfs is not configured: $ROOTFS_ROOT" >&2
	exit 1
}

if [ -n "${ROOTFS_IMAGE_SIZE:-}" ]; then
	SIZE="$ROOTFS_IMAGE_SIZE"
	SIZE_MIB="$(size_mib "$ROOTFS_IMAGE_SIZE")"
else
	USED_MIB="$($SUDO du -smx "$ROOTFS_ROOT" | awk '{print $1}')"
	HEADROOM_MIB="$(size_mib "$HEADROOM")"
	MIN_SIZE_MIB="$(size_mib "$MIN_SIZE")"
	SIZE_MIB=$(((USED_MIB + HEADROOM_MIB + 63) / 64 * 64))
	if [ "$SIZE_MIB" -lt "$MIN_SIZE_MIB" ]; then
		SIZE_MIB="$MIN_SIZE_MIB"
	fi
	SIZE="${SIZE_MIB}M"
fi

PARTITION_SECTORS="$(sed -nE \
	's/.*0x([0-9a-fA-F]+)@0x[0-9a-fA-F]+\(rootfs\).*/\1/p' \
	"$BOARD_FIRMWARE_DIR/$PARAMETER_FILE" | head -n 1)"
if [ -n "$PARTITION_SECTORS" ]; then
	PARTITION_MIB=$((16#$PARTITION_SECTORS / 2048))
	if [ "$SIZE_MIB" -gt "$PARTITION_MIB" ]; then
		echo "rootfs payload (${SIZE_MIB} MiB) exceeds partition (${PARTITION_MIB} MiB)" >&2
		exit 1
	fi
fi

mkdir -p "$(dirname "$IMAGE")"
$SUDO rm -f "$IMAGE"
echo "Packing $IMAGE from $ROOTFS_ROOT (${SIZE_MIB} MiB payload)"
$SUDO truncate -s "$SIZE" "$IMAGE"
$SUDO mke2fs -q -F -t ext4 -L "$LABEL" -d "$ROOTFS_ROOT" "$IMAGE"
$SUDO e2fsck -fn "$IMAGE" >/dev/null
$SUDO chown "$(id -u):$(id -g)" "$IMAGE"

echo "Rootfs image ready: $IMAGE"
