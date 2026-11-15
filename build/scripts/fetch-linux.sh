#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
SDK_ROOT="$(realpath "$SCRIPT_DIR/../..")"
LINUX_VERSION="${KERNEL_VERSION:-7.3.4}"
KERNEL_DIR="${KERNEL_DIR:-$SDK_ROOT/kernel}"
COMMON_DIR="${COMMON_DIR:-$SDK_ROOT/common}"
BOARD_KERNEL_DIR="${BOARD_KERNEL_DIR:-$SDK_ROOT/boards/ampheck/eidos-alpha/kernel}"
COMMON_PATCH_DIR="${COMMON_PATCH_DIR:-$COMMON_DIR/kernel/patches}"
COMMON_FILES_DIR="${COMMON_FILES_DIR:-$COMMON_DIR/kernel/files}"
BOARD_PATCH_DIR="${BOARD_PATCH_DIR:-$BOARD_KERNEL_DIR/patches}"
BOARD_FILES_DIR="${BOARD_FILES_DIR:-$BOARD_KERNEL_DIR/files}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$SDK_ROOT/output/downloads}"
TARBALL="$DOWNLOAD_DIR/${KERNEL_TARBALL:-linux-$LINUX_VERSION.tar.xz}"
URL="${KERNEL_URL:-https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-$LINUX_VERSION.tar.xz}"
SHA256="${KERNEL_SHA256:-b11b6df8295e8e991ff040b71aaa4994a8b55caa23b6b092907f195b5840fd1f}"
DTS="${KERNEL_DTS:-rk3566-ampheck-eidos-alpha}.dts"
DEFCONFIG="${KERNEL_DEFCONFIG:-eidos_alpha_defconfig}"
TMP_DIR=

cleanup()
{
	[ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
}
trap cleanup EXIT

download_tarball()
{
	eidos_download_verified "$URL" "$TARBALL" "$SHA256" 3 "Linux $LINUX_VERSION"
}

extract_kernel()
{
	download_tarball

	if [ -d "$KERNEL_DIR" ] && [ -n "$(ls -A "$KERNEL_DIR")" ]; then
		echo "Kernel directory is not empty and has no Makefile: $KERNEL_DIR" >&2
		exit 1
	fi

	TMP_DIR="$(mktemp -d "$(dirname "$KERNEL_DIR")/.kernel-$LINUX_VERSION.XXXXXX")"
	echo "Extracting Linux $LINUX_VERSION into $KERNEL_DIR"
	tar -xJf "$TARBALL" -C "$TMP_DIR" --strip-components=1
	rmdir "$KERNEL_DIR" 2>/dev/null || true
	mv "$TMP_DIR" "$KERNEL_DIR"
	TMP_DIR=
}

input_hash()
{
	{
		local patch_dir patch_file input files_dir file rel scope
		printf '%s\n' "$LINUX_VERSION" "$SHA256" "$DTS" "$DEFCONFIG"
		for patch_dir in "$COMMON_PATCH_DIR" "$BOARD_PATCH_DIR"; do
			for patch_file in "$patch_dir"/*.patch; do
				[ -r "$patch_file" ] || continue
				printf '%s  ' "$patch_file"
				sha256sum "$patch_file" | cut -d' ' -f1
			done
		done
		for input in "$BOARD_KERNEL_DIR/$DTS" "$BOARD_KERNEL_DIR/$DEFCONFIG"; do
			[ -r "$input" ] || continue
			printf '%s  ' "$input"
			sha256sum "$input" | cut -d' ' -f1
		done
		for files_dir in "$COMMON_FILES_DIR" "$BOARD_FILES_DIR"; do
			[ -d "$files_dir" ] || continue
			case "$files_dir" in
				"$COMMON_FILES_DIR") scope=common ;;
				*) scope=board ;;
			esac
			while IFS= read -r -d '' file; do
				rel="${file#"$files_dir"/}"
				printf '%s  ' "$scope:$rel"
				sha256sum "$file" | cut -d' ' -f1
			done < <(find "$files_dir" -type f -print0 | sort -z)
		done
	} | sha256sum | cut -d' ' -f1
}

apply_kernel_patches()
{
	eidos_apply_patches "$KERNEL_DIR" "kernel" \
		"$COMMON_PATCH_DIR" "$BOARD_PATCH_DIR"
}

install_kernel_files()
{
	local refresh="$1"
	local files_dir source rel dest scope

	for files_dir in "$COMMON_FILES_DIR" "$BOARD_FILES_DIR"; do
		[ -d "$files_dir" ] || continue
		case "$files_dir" in
			"$COMMON_FILES_DIR") scope=common ;;
			*) scope=board ;;
		esac

		while IFS= read -r -d '' source; do
			rel="${source#"$files_dir"/}"
			dest="$KERNEL_DIR/$rel"
			if [ -e "$dest" ] && [ "$refresh" != true ]; then
				if [ "$scope" != board ] || \
					[ ! -e "$COMMON_FILES_DIR/$rel" ]; then
					echo "Kernel file would overwrite an upstream file: $rel" >&2
					exit 1
				fi
			fi
			if cmp -s "$source" "$dest"; then
				continue
			fi
			mkdir -p "$(dirname "$dest")"
			install -m 0644 "$source" "$dest"
		done < <(find "$files_dir" -type f -print0 | sort -z)
	done
}

INPUT_HASH="$(input_hash)"
PATCH_STAMP="$KERNEL_DIR/.eidos-kernel-input.sha256"

# If the configured inputs changed, discard the generated kernel tree and extract a
# pristine tarball again. Once the stamp matches, the kernel is already in the
# expected post-patch state; skip replaying patches so later patches may safely
# build on files introduced by earlier ones.
PATCHES_APPLIED=false
if [ -r "$KERNEL_DIR/Makefile" ] && [ -r "$PATCH_STAMP" ]; then
	if [ "$(cat "$PATCH_STAMP")" != "$INPUT_HASH" ]; then
		echo "Kernel inputs changed; resetting generated kernel tree"
		rm -rf "$KERNEL_DIR"
	else
		PATCHES_APPLIED=true
	fi
elif [ -r "$KERNEL_DIR/Makefile" ] && \
	[ -r "$KERNEL_DIR/.eidos-patchset.sha256" ]; then
	echo "Migrating legacy kernel patch stamp"
	PATCHES_APPLIED=true
fi

if [ ! -r "$KERNEL_DIR/Makefile" ]; then
	extract_kernel
fi

source_version="$(
	awk '
		/^VERSION = / { version = $3 }
		/^PATCHLEVEL = / { patchlevel = $3 }
		/^SUBLEVEL = / { sublevel = $3 }
		END {
			if (version != "" && patchlevel != "" && sublevel != "")
				print version "." patchlevel "." sublevel
		}
	' "$KERNEL_DIR/Makefile"
)"
if [ "$source_version" != "$LINUX_VERSION" ]; then
	echo "Unexpected kernel source in $KERNEL_DIR (expected $LINUX_VERSION)" >&2
	exit 1
fi

if [ "$PATCHES_APPLIED" = false ]; then
	apply_kernel_patches
fi
install_kernel_files "$PATCHES_APPLIED"
printf '%s\n' "$INPUT_HASH" > "$PATCH_STAMP"

[ -r "$BOARD_KERNEL_DIR/$DTS" ] || {
	echo "Missing board device tree: $BOARD_KERNEL_DIR/$DTS" >&2
	exit 1
}
[ -r "$BOARD_KERNEL_DIR/$DEFCONFIG" ] || {
	echo "Missing board kernel defconfig: $BOARD_KERNEL_DIR/$DEFCONFIG" >&2
	exit 1
}

install -m 0644 "$BOARD_KERNEL_DIR/$DTS" \
	"$KERNEL_DIR/arch/arm64/boot/dts/rockchip/$DTS"
install -m 0644 "$BOARD_KERNEL_DIR/$DEFCONFIG" \
	"$KERNEL_DIR/arch/arm64/configs/$DEFCONFIG"

dtb="${DTS%.dts}.dtb"
if ! grep -qF "$dtb" \
	"$KERNEL_DIR/arch/arm64/boot/dts/rockchip/Makefile"; then
	printf '\ndtb-$(CONFIG_ARCH_ROCKCHIP) += %s\n' "$dtb" \
		>> "$KERNEL_DIR/arch/arm64/boot/dts/rockchip/Makefile"
fi

echo "Linux $LINUX_VERSION kernel tree ready: $KERNEL_DIR"
