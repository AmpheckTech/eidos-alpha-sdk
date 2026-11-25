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
BOARD_CHIP="${BOARD_CHIP:-rk3566}"
PARAMETER_FILE="${PARAMETER_FILE:-parameter-ubuntu-fit.txt}"
PACKAGE_FILE="${PACKAGE_FILE:-package-file}"

UPDATE_DIR="$OUTPUT_DIR/update"
IMAGE_DIR="$UPDATE_DIR/Image"
UPDATE_IMAGE="$FIRMWARE_DIR/update.img"
IDBLOADER="${IDBLOADER:-$OUTPUT_DIR/uboot-build/idbloader.img}"
UBOOT_IMAGE="$OUTPUT_DIR/uboot-build/u-boot.itb"
PARAMETER="$SDK_ROOT/boards/$BOARD/firmware/$PARAMETER_FILE"
PACKAGE_FILE_PATH="$SDK_ROOT/boards/$BOARD/$PACKAGE_FILE"

for file in "$ROOTFS_IMAGE" "$BOOT_IMAGE" "$DATA_IMAGE" "$IDBLOADER" \
	"$UBOOT_IMAGE" "$PARAMETER" "$PACKAGE_FILE_PATH"; do
	[ -r "$file" ] || {
		echo "missing firmware input: $file" >&2
		exit 1
	}
done

command -v "$ARKT" >/dev/null || {
	echo "firmware packing tool not found: $ARKT" >&2
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
cp -f "$PARAMETER" "$IMAGE_DIR/parameter.txt"
cp -f "$PACKAGE_FILE_PATH" "$IMAGE_DIR/package-file"

ln -f "$IDBLOADER" "$IMAGE_DIR/BOOT" 2>/dev/null || \
	cp -f "$IDBLOADER" "$IMAGE_DIR/BOOT"
"$ARKT" image pack "$IMAGE_DIR" "$IMAGE_DIR/update.img" \
	--chip "${BOARD_CHIP^^}" --force

ln -sfn "$IMAGE_DIR/rootfs.img" "$FIRMWARE_DIR/rootfs.img"
ln -sfn "$IMAGE_DIR/boot.img" "$FIRMWARE_DIR/boot.img"
ln -sfn "$IMAGE_DIR/data.img" "$FIRMWARE_DIR/data.img"
ln -sfn "$IMAGE_DIR/uboot.img" "$FIRMWARE_DIR/uboot.img"
ln -sfn "$IMAGE_DIR/parameter.txt" "$FIRMWARE_DIR/parameter.txt"
ln -sfn "$IMAGE_DIR/update.img" "$UPDATE_IMAGE"
"$ARKT" verify "$UPDATE_IMAGE"
echo "Update image ready: $UPDATE_IMAGE"
