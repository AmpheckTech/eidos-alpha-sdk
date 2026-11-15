#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="${SDK_ROOT:-$(realpath "$SCRIPT_DIR/../..")}"
OUTPUT_DIR="${OUTPUT_DIR:-$SDK_ROOT/output}"
FIRMWARE_DIR="${FIRMWARE_DIR:-$OUTPUT_DIR/firmware}"
ROOTFS_IMAGE="${ROOTFS_IMAGE:-$OUTPUT_DIR/rootfs/rootfs.ext4}"
BOOT_IMAGE="${BOOT_IMAGE:-$OUTPUT_DIR/images/boot.img}"
DATA_IMAGE="${DATA_IMAGE:-$OUTPUT_DIR/images/data.img}"
ARKT="${ARKT:-arkt}"
BOARD="${BOARD:-ampheck/eidos-alpha}"
PARAMETER_FILE="${PARAMETER_FILE:-parameter-ubuntu-fit.txt}"
PACKAGE_FILE="${PACKAGE_FILE:-package-file}"

UPDATE_DIR="$OUTPUT_DIR/update"
IMAGE_DIR="$UPDATE_DIR/Image"
UPDATE_IMAGE="$FIRMWARE_DIR/update.img"
MINILOADER="${MINILOADER:-boards/ampheck/eidos-alpha/firmware/rockchip/rk3568_miniloader_ldr.bin}"
UBOOT_IMAGE="$OUTPUT_DIR/uboot-build/u-boot.itb"
PARAMETER="$SDK_ROOT/boards/$BOARD/firmware/$PARAMETER_FILE"
PACKAGE_FILE_PATH="$SDK_ROOT/boards/$BOARD/$PACKAGE_FILE"

case "$MINILOADER" in
	/*) ;;
	*) MINILOADER="$SDK_ROOT/$MINILOADER" ;;
esac

for file in "$ROOTFS_IMAGE" "$BOOT_IMAGE" "$DATA_IMAGE" "$MINILOADER" \
	"$UBOOT_IMAGE" "$PARAMETER" "$PACKAGE_FILE_PATH"; do
	[ -r "$file" ] || {
		echo "missing firmware input: $file" >&2
		exit 1
	}
done

command -v "$ARKT" >/dev/null || {
	echo "ARKT not found: $ARKT" >&2
	exit 1
}

rm -rf "$UPDATE_DIR" "$UPDATE_IMAGE"
mkdir -p "$IMAGE_DIR" "$FIRMWARE_DIR"

ln -f "$ROOTFS_IMAGE" "$IMAGE_DIR/rootfs.img" 2>/dev/null || \
	cp -f "$ROOTFS_IMAGE" "$IMAGE_DIR/rootfs.img"
ln -f "$BOOT_IMAGE" "$IMAGE_DIR/boot.img" 2>/dev/null || \
	cp -f "$BOOT_IMAGE" "$IMAGE_DIR/boot.img"
ln -f "$DATA_IMAGE" "$IMAGE_DIR/data.img" 2>/dev/null || \
	cp -f "$DATA_IMAGE" "$IMAGE_DIR/data.img"
ln -f "$UBOOT_IMAGE" "$IMAGE_DIR/uboot.img" 2>/dev/null || \
	cp -f "$UBOOT_IMAGE" "$IMAGE_DIR/uboot.img"
ln -f "$MINILOADER" "$IMAGE_DIR/MiniLoaderAll.bin" 2>/dev/null || \
	cp -f "$MINILOADER" "$IMAGE_DIR/MiniLoaderAll.bin"
cp -f "$PARAMETER" "$IMAGE_DIR/parameter.txt"
cp -f "$PACKAGE_FILE_PATH" "$IMAGE_DIR/package-file"
ln -f "$IMAGE_DIR/MiniLoaderAll.bin" "$IMAGE_DIR/BOOT"

"$ARKT" image pack "$IMAGE_DIR" "$IMAGE_DIR/update.img" \
	--chip "${BOARD_CHIP^^}" --force
ln -sfn "$IMAGE_DIR/rootfs.img" "$FIRMWARE_DIR/rootfs.img"
ln -sfn "$IMAGE_DIR/boot.img" "$FIRMWARE_DIR/boot.img"
ln -sfn "$IMAGE_DIR/data.img" "$FIRMWARE_DIR/data.img"
ln -sfn "$IMAGE_DIR/uboot.img" "$FIRMWARE_DIR/uboot.img"
ln -sfn "$IMAGE_DIR/MiniLoaderAll.bin" "$FIRMWARE_DIR/MiniLoaderAll.bin"
ln -sfn "$IMAGE_DIR/parameter.txt" "$FIRMWARE_DIR/parameter.txt"
ln -sfn "$IMAGE_DIR/update.img" "$UPDATE_IMAGE"
echo "Update image ready: $UPDATE_IMAGE"
