#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="${SDK_ROOT:-$(realpath "$SCRIPT_DIR/../..")}"
SOURCE_OUTPUT_DIR="${SOURCE_OUTPUT_DIR:-$SDK_ROOT/output}"
IDBLOADER="${IDBLOADER:-$SOURCE_OUTPUT_DIR/uboot-build/idbloader.img}"
MINILOADER="${MINILOADER:-$SOURCE_OUTPUT_DIR/uboot-build/MiniLoaderAll.bin}"
UBOOT_IMAGE="${UBOOT_IMAGE:-$SOURCE_OUTPUT_DIR/uboot-build/u-boot.itb}"
ARKT="${ARKT:-arkt}"

for file in "$IDBLOADER" "$MINILOADER" "$UBOOT_IMAGE"; do
	[ -r "$file" ] || {
		echo "missing packaging test input: $file" >&2
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

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/eidos-pack-update.XXXXXX")"
cleanup()
{
	rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

ROOTFS_IMAGE="$TEST_ROOT/rootfs/rootfs.ext4"
BOOT_IMAGE="$TEST_ROOT/images/boot.img"
DATA_IMAGE="$TEST_ROOT/images/data.img"
FIRMWARE_DIR="$TEST_ROOT/firmware"
UPDATE_STAMP="$TEST_ROOT/.update-image.sha256"

mkdir -p "$(dirname "$ROOTFS_IMAGE")" "$(dirname "$BOOT_IMAGE")" "$FIRMWARE_DIR"
printf 'rootfs packaging test\n' > "$ROOTFS_IMAGE"
printf 'boot packaging test\n' > "$BOOT_IMAGE"
printf 'data packaging test\n' > "$DATA_IMAGE"

run_pack()
{
	ROOTFS_IMAGE="$ROOTFS_IMAGE" BOOT_IMAGE="$BOOT_IMAGE" \
		DATA_IMAGE="$DATA_IMAGE" UBOOT_IMAGE="$UBOOT_IMAGE" \
		IDBLOADER="$IDBLOADER" MINILOADER="$MINILOADER" \
		OUTPUT_DIR="$TEST_ROOT" FIRMWARE_DIR="$FIRMWARE_DIR" \
		UPDATE_IMAGE_STAMP="$UPDATE_STAMP" ARKT="$ARKT" \
		"$SCRIPT_DIR/pack-update.sh"
}

run_pack
first_stamp="$(cat "$UPDATE_STAMP")"
first_image_sha256="$(sha256sum "$FIRMWARE_DIR/update.img" | cut -d' ' -f1)"

touch -r "$ROOTFS_IMAGE" "$TEST_ROOT/rootfs.timestamp"
printf X | dd of="$ROOTFS_IMAGE" bs=1 seek=0 conv=notrunc status=none
touch -r "$TEST_ROOT/rootfs.timestamp" "$ROOTFS_IMAGE"

run_pack
second_stamp="$(cat "$UPDATE_STAMP")"
second_image_sha256="$(sha256sum "$FIRMWARE_DIR/update.img" | cut -d' ' -f1)"

[ "$first_stamp" != "$second_stamp" ] || {
	echo "packaging cache ignored a rootfs content change" >&2
	exit 1
}
[ "$first_image_sha256" != "$second_image_sha256" ] || {
	echo "update image was not rebuilt after a rootfs content change" >&2
	exit 1
}

echo "Update packaging smoke test passed"
