#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="${SDK_ROOT:-$(realpath "$SCRIPT_DIR/../..")}"
ROOTFS_ROOT="${1:-${ROOTFS_ROOT:-$SDK_ROOT/output/rootfs/root}}"
IMAGE="${2:-${ROOTFS_IMAGE:-$SDK_ROOT/output/rootfs/rootfs.ext4}}"
SIZE="${ROOTFS_SIZE:-4096M}"
LABEL="${ROOTFS_LABEL:-rootfs}"

if [ "$(id -u)" -eq 0 ]; then
	SUDO=
else
	SUDO=sudo
fi

[ -x "$ROOTFS_ROOT/bin/bash" ] || {
	echo "rootfs is not configured: $ROOTFS_ROOT" >&2
	exit 1
}

mkdir -p "$(dirname "$IMAGE")"
$SUDO rm -f "$IMAGE"
echo "Packing $IMAGE from $ROOTFS_ROOT ($SIZE)"
$SUDO truncate -s "$SIZE" "$IMAGE"
$SUDO mke2fs -q -F -t ext4 -L "$LABEL" -d "$ROOTFS_ROOT" "$IMAGE"
$SUDO e2fsck -fn "$IMAGE" >/dev/null
$SUDO chown "$(id -u):$(id -g)" "$IMAGE"

echo "Rootfs image ready: $IMAGE"
