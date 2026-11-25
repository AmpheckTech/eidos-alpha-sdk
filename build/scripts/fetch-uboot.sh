#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
SDK_ROOT="$(realpath "$SCRIPT_DIR/../..")"
UBOOT_VERSION="${UBOOT_VERSION:-2026.10}"
UBOOT_SRC="${UBOOT_SRC:-$SDK_ROOT/output/uboot-src}"
BOARD_UBOOT_DIR="${BOARD_UBOOT_DIR:-$SDK_ROOT/boards/ampheck/eidos-alpha/uboot}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$SDK_ROOT/output/downloads}"
TARBALL="$DOWNLOAD_DIR/${UBOOT_TARBALL:-u-boot-$UBOOT_VERSION.tar.gz}"
URL="${UBOOT_URL:-https://codeload.github.com/u-boot/u-boot/tar.gz/refs/tags/v$UBOOT_VERSION}"
SHA256="${UBOOT_SHA256:-f943a88389c8fd70a6b0d061a88267465e143c7ca6ea2b75837ab20f5b60c739}"
COMMON_PATCH_DIR="${COMMON_UBOOT_PATCH_DIR:-$SDK_ROOT/common/uboot/patches}"
BOARD_PATCH_DIR="${BOARD_UBOOT_PATCH_DIR:-$BOARD_UBOOT_DIR/patches}"
TMP_DIR=
INPUT_STAMP="$UBOOT_SRC/.eidos-uboot-input.sha256"

cleanup()
{
	[ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
}
trap cleanup EXIT

verify_source()
{
	[ -r "$UBOOT_SRC/Makefile" ] || return 1
	grep -q '^VERSION = 2026$' "$UBOOT_SRC/Makefile" &&
		grep -q '^PATCHLEVEL = 10$' "$UBOOT_SRC/Makefile"
}

board_uboot_files()
{
	find "$BOARD_UBOOT_DIR/configs" "$BOARD_UBOOT_DIR/dts" \
		-type f -print 2>/dev/null | sort
}

apply_uboot_patches()
{
	eidos_apply_patches "$UBOOT_SRC" "U-Boot" \
		"$COMMON_PATCH_DIR" "$BOARD_PATCH_DIR"
}

input_hash()
{
	local patch_dir patch_file file rel

	{
		printf '%s\n' "$UBOOT_VERSION" "$SHA256"
		for patch_dir in "$COMMON_PATCH_DIR" "$BOARD_PATCH_DIR"; do
			[ -d "$patch_dir" ] || continue
			for patch_file in "$patch_dir"/*.patch; do
				[ -r "$patch_file" ] || continue
				printf '%s  ' "$patch_file"
				sha256sum "$patch_file" | cut -d' ' -f1
			done
		done
		while IFS= read -r file; do
			rel="${file#"$BOARD_UBOOT_DIR"/}"
			printf '%s  ' "$rel"
			sha256sum "$file" | cut -d' ' -f1
		done < <(board_uboot_files)
	} | sha256sum | cut -d' ' -f1
}

INPUT_HASH="$(input_hash)"
PATCHES_APPLIED=false

if [ -d "$UBOOT_SRC" ] && [ -n "$(ls -A "$UBOOT_SRC")" ]; then
	if ! verify_source; then
		echo "U-Boot directory is not empty and is not v$UBOOT_VERSION: $UBOOT_SRC" >&2
		exit 1
	fi
	if [ ! -r "$INPUT_STAMP" ] || [ "$(cat "$INPUT_STAMP")" != "$INPUT_HASH" ]; then
		echo "U-Boot inputs changed; resetting generated source tree"
		rm -rf "$UBOOT_SRC"
	fi
fi

if ! verify_source; then
	eidos_download_verified "$URL" "$TARBALL" "$SHA256" 5 "U-Boot $UBOOT_VERSION"

	TMP_DIR="$(mktemp -d "$(dirname "$UBOOT_SRC")/.u-boot-$UBOOT_VERSION.XXXXXX")"
	echo "Extracting U-Boot $UBOOT_VERSION into $UBOOT_SRC"
	tar -xzf "$TARBALL" -C "$TMP_DIR" --strip-components=1
	rmdir "$UBOOT_SRC" 2>/dev/null || true
	mv "$TMP_DIR" "$UBOOT_SRC"
	TMP_DIR=
fi

verify_source || {
	echo "Unexpected U-Boot source in $UBOOT_SRC (expected v$UBOOT_VERSION)" >&2
	exit 1
}

if [ -r "$INPUT_STAMP" ] && [ "$(cat "$INPUT_STAMP")" = "$INPUT_HASH" ]; then
	echo "U-Boot inputs already applied"
	PATCHES_APPLIED=true
fi

if [ "$PATCHES_APPLIED" = false ]; then
	apply_uboot_patches
fi

while IFS= read -r file; do
	rel="${file#"$BOARD_UBOOT_DIR"/}"
	case "$rel" in
		configs/*)
			install -m 0644 "$file" "$UBOOT_SRC/$rel"
			;;
		dts/*)
			install -m 0644 "$file" "$UBOOT_SRC/arch/arm/dts/${rel#dts/}"
			;;
		*)
			echo "Unsupported board U-Boot file: $rel" >&2
			exit 1
			;;
	esac
done < <(board_uboot_files)
printf '%s\n' "$INPUT_HASH" > "$INPUT_STAMP"

echo "U-Boot $UBOOT_VERSION source ready: $UBOOT_SRC"
