#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
SDK_ROOT="${SDK_ROOT:-$(realpath "$SCRIPT_DIR/../..")}"
BOARD_FIRMWARE_DIR="${BOARD_FIRMWARE_DIR:-$SDK_ROOT/boards/ampheck/eidos-alpha/firmware}"
PARAMETER_FILE="${PARAMETER_FILE:-parameter-ubuntu-fit.txt}"
ROOTFS_ROOT="${1:-${ROOTFS_ROOT:-$SDK_ROOT/output/rootfs/root}}"
IMAGE="${2:-${ROOTFS_IMAGE:-$SDK_ROOT/output/rootfs/rootfs.ext4}}"
HEADROOM="${ROOTFS_IMAGE_HEADROOM:-512M}"
MIN_SIZE="${ROOTFS_IMAGE_MIN_SIZE:-1024M}"
LABEL="${ROOTFS_LABEL:-rootfs}"
IMAGE_STAMP="${ROOTFS_IMAGE_STAMP:-$(dirname "$IMAGE")/.rootfs-image.sha256}"

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

input_hash="$({
	printf '%s\n' \
		"format=1" \
		"HEADROOM=$HEADROOM" "MIN_SIZE=$MIN_SIZE" \
		"ROOTFS_IMAGE_SIZE=${ROOTFS_IMAGE_SIZE:-}" "LABEL=$LABEL"
	eidos_hash_files "$SCRIPT_DIR/pack-rootfs.sh" "$SCRIPT_DIR/lib.sh"
	eidos_hash_tree "$ROOTFS_ROOT" "$SUDO"
} | sha256sum | cut -d' ' -f1)"

if [ "${FORCE:-0}" != 1 ] && [ -s "$IMAGE" ] && \
	[ -s "$IMAGE_STAMP" ] && [ "$(cat "$IMAGE_STAMP")" = "$input_hash" ]; then
	echo "Rootfs image is up to date: $IMAGE"
	exit 0
fi

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
printf '%s\n' "$input_hash" > "$IMAGE_STAMP"

echo "Rootfs image ready: $IMAGE"
