#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
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
MINILOADER="${MINILOADER:-$OUTPUT_DIR/uboot-build/MiniLoaderAll.bin}"
UBOOT_IMAGE="${UBOOT_IMAGE:-$OUTPUT_DIR/uboot-build/u-boot.itb}"
PARAMETER="$SDK_ROOT/boards/$BOARD/firmware/$PARAMETER_FILE"
PACKAGE_FILE_PATH="$SDK_ROOT/boards/$BOARD/$PACKAGE_FILE"
UPDATE_STAMP="${UPDATE_IMAGE_STAMP:-$OUTPUT_DIR/.update-image.sha256}"

for file in "$ROOTFS_IMAGE" "$BOOT_IMAGE" "$DATA_IMAGE" "$IDBLOADER" \
	"$MINILOADER" "$UBOOT_IMAGE" "$PARAMETER" "$PACKAGE_FILE_PATH"; do
	[ -r "$file" ] || {
		echo "missing firmware input: $file" >&2
		exit 1
	}
done

[ "$(head -c 3 "$MINILOADER")" = LDR ] || {
	echo "not a Rockchip USB loader: $MINILOADER" >&2
	exit 1
}
[ "$(head -c 4 "$IDBLOADER")" = RKNS ] || {
	echo "not a Rockchip idbloader image: $IDBLOADER" >&2
	exit 1
}

command -v "$ARKT" >/dev/null || {
	echo "firmware packing tool not found: $ARKT" >&2
	exit 1
}

link_firmware_outputs()
{
	ln -sfn "$IMAGE_DIR/rootfs.img" "$FIRMWARE_DIR/rootfs.img"
	ln -sfn "$IMAGE_DIR/boot.img" "$FIRMWARE_DIR/boot.img"
	ln -sfn "$IMAGE_DIR/data.img" "$FIRMWARE_DIR/data.img"
	ln -sfn "$IMAGE_DIR/uboot.img" "$FIRMWARE_DIR/uboot.img"
	ln -sfn "$MINILOADER" "$FIRMWARE_DIR/MiniLoaderAll.bin"
	ln -sfn "$IMAGE_DIR/parameter.txt" "$FIRMWARE_DIR/parameter.txt"
	ln -sfn "$IMAGE_DIR/update.img" "$UPDATE_IMAGE"
}

input_hash="$({
	printf '%s\n' "format=2" "ARKT_VERSION=$("$ARKT" --version 2>&1)"
	eidos_hash_files "$ROOTFS_IMAGE" "$BOOT_IMAGE" "$DATA_IMAGE" \
		"$IDBLOADER" "$MINILOADER" "$UBOOT_IMAGE" "$PARAMETER" \
		"$PACKAGE_FILE_PATH" "$SCRIPT_DIR/pack-update.sh" "$SCRIPT_DIR/lib.sh"
} | sha256sum | cut -d' ' -f1)"

if [ "${FORCE:-0}" != 1 ] && [ -s "$IMAGE_DIR/update.img" ] && \
	[ -s "$UPDATE_STAMP" ] && [ "$(cat "$UPDATE_STAMP")" = "$input_hash" ]; then
	link_firmware_outputs
	echo "Update image is up to date: $IMAGE_DIR/update.img"
	exit 0
fi

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

ln -f "$MINILOADER" "$IMAGE_DIR/BOOT" 2>/dev/null || \
	cp -f "$MINILOADER" "$IMAGE_DIR/BOOT"
ln -f "$IDBLOADER" "$IMAGE_DIR/idbloader.img" 2>/dev/null || \
	cp -f "$IDBLOADER" "$IMAGE_DIR/idbloader.img"
"$ARKT" image pack "$IMAGE_DIR" "$IMAGE_DIR/update.img" \
	--chip "${BOARD_CHIP^^}" --force

link_firmware_outputs
"$ARKT" verify "$UPDATE_IMAGE"
printf '%s\n' "$input_hash" > "$UPDATE_STAMP"
echo "Update image ready: $UPDATE_IMAGE"
