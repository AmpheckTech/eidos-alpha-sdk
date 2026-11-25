#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
SDK_ROOT="$(realpath "$SCRIPT_DIR/../..")"
LINUX_VERSION="${KERNEL_VERSION:?KERNEL_VERSION is required}"
KERNEL_DIR="${KERNEL_DIR:-$SDK_ROOT/kernel}"
BOARD_KERNEL_DIR="${BOARD_KERNEL_DIR:-$SDK_ROOT/boards/ampheck/eidos-alpha/kernel}"
patch_root="${BOARD_KERNEL_PATCH_DIR:-$BOARD_KERNEL_DIR/patches}"
patch_series="${LINUX_VERSION%.*}"
BOARD_PATCH_DIR="$patch_root"
if [ -d "$patch_root/$patch_series" ]; then
	BOARD_PATCH_DIR="$patch_root/$patch_series"
fi
KERNEL_REPO_URL="${KERNEL_REPO_URL:-}"
KERNEL_REPO_REF="${KERNEL_REPO_REF:-}"
KERNEL_REPO_COMMIT="${KERNEL_REPO_COMMIT:-}"
DTS="${KERNEL_DTS:-rk3566-ampheck-eidos-alpha}.dts"
DEFCONFIG="${KERNEL_DEFCONFIG:-eidos_alpha_defconfig}"
TMP_DIR=

cleanup()
{
	[ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fetch_kernel()
{
	if [ -z "$KERNEL_REPO_URL" ] || [ -z "$KERNEL_REPO_COMMIT" ]; then
		echo "Kernel git source requires URL and commit" >&2
		exit 1
	fi
	if [ -d "$KERNEL_DIR" ] && [ -n "$(ls -A "$KERNEL_DIR")" ]; then
		echo "Kernel directory is not empty and has no Makefile: $KERNEL_DIR" >&2
		exit 1
	fi

	TMP_DIR="$(mktemp -d "$(dirname "$KERNEL_DIR")/.kernel-$LINUX_VERSION.XXXXXX")"
	echo "Fetching Linux $LINUX_VERSION from $KERNEL_REPO_URL at $KERNEL_REPO_COMMIT"
	git -C "$TMP_DIR" init --quiet
	git -C "$TMP_DIR" remote add origin "$KERNEL_REPO_URL"
	git -C "$TMP_DIR" fetch --depth 1 origin "$KERNEL_REPO_COMMIT"
	git -C "$TMP_DIR" checkout --quiet --detach FETCH_HEAD
	actual_commit="$(git -C "$TMP_DIR" rev-parse HEAD)"
	if [ "$actual_commit" != "$KERNEL_REPO_COMMIT" ]; then
		echo "Unexpected kernel commit: $actual_commit (expected $KERNEL_REPO_COMMIT)" >&2
		exit 1
	fi
	rmdir "$KERNEL_DIR" 2>/dev/null || true
	mv "$TMP_DIR" "$KERNEL_DIR"
	TMP_DIR=
}

source_input_hash()
{
	local patch_file

	{
		printf '%s\n' "$LINUX_VERSION" "$KERNEL_REPO_URL" "$KERNEL_REPO_REF" \
			"$KERNEL_REPO_COMMIT"
		if [ -d "$BOARD_PATCH_DIR" ]; then
			while IFS= read -r patch_file; do
				printf '%s  ' "${patch_file##*/}"
				sha256sum "$patch_file" | cut -d' ' -f1
			done < <(find "$BOARD_PATCH_DIR" -maxdepth 1 -type f \
				-name '*.patch' -print | sort)
		fi
	} | sha256sum | cut -d' ' -f1
}

kernel_source_version()
{
	awk '
		/^VERSION = / { version = $3 }
		/^PATCHLEVEL = / { patchlevel = $3 }
		/^SUBLEVEL = / { sublevel = $3 }
		END {
			if (version != "" && patchlevel != "" && sublevel != "")
				print version "." patchlevel "." sublevel
		}
	' "$1/Makefile"
}

SOURCE_INPUT_HASH="$(source_input_hash)"
SOURCE_STAMP="$KERNEL_DIR/.eidos-kernel-source.sha256"
PATCHES_APPLIED=false

# The board defconfig and DTS are installed in place after the source check so an
# incremental kernel rebuild stays incremental.  Kernel patches are part of the
# source stamp because a changed patch requires a pristine source tree.
if [ -r "$KERNEL_DIR/Makefile" ] && [ -r "$SOURCE_STAMP" ]; then
	if [ "$(cat "$SOURCE_STAMP")" = "$SOURCE_INPUT_HASH" ]; then
		PATCHES_APPLIED=true
	else
		echo "Kernel source inputs changed; resetting generated kernel tree"
		rm -rf "$KERNEL_DIR"
	fi
elif [ -r "$KERNEL_DIR/Makefile" ]; then
	echo "Kernel source inputs changed; resetting generated kernel tree"
	rm -rf "$KERNEL_DIR"
fi

if [ ! -r "$KERNEL_DIR/Makefile" ]; then
	fetch_kernel
fi

source_version="$(kernel_source_version "$KERNEL_DIR")"
if [ "$source_version" != "$LINUX_VERSION" ]; then
	echo "Unexpected kernel source in $KERNEL_DIR (expected $LINUX_VERSION)" >&2
	exit 1
fi

if [ "$PATCHES_APPLIED" = false ]; then
	eidos_apply_patches "$KERNEL_DIR" "kernel" "$BOARD_PATCH_DIR"
fi

[ -r "$BOARD_KERNEL_DIR/$DTS" ] || {
	echo "Missing board device tree: $BOARD_KERNEL_DIR/$DTS" >&2
	exit 1
}
board_defconfig="$BOARD_KERNEL_DIR/$DEFCONFIG"
upstream_defconfig="$KERNEL_DIR/arch/arm64/configs/$DEFCONFIG"
if [ ! -r "$board_defconfig" ] && [ ! -r "$upstream_defconfig" ]; then
	echo "Missing kernel defconfig: $DEFCONFIG" >&2
	exit 1
fi

source_dts="$BOARD_KERNEL_DIR/$DTS"
dest_dts="$KERNEL_DIR/arch/arm64/boot/dts/rockchip/$DTS"
if ! cmp -s "$source_dts" "$dest_dts"; then
	install -m 0644 "$source_dts" "$dest_dts"
fi

source_defconfig="$board_defconfig"
dest_defconfig="$upstream_defconfig"
if [ -r "$source_defconfig" ] && ! cmp -s "$source_defconfig" "$dest_defconfig"; then
	install -m 0644 "$source_defconfig" "$dest_defconfig"
fi

dtb="${DTS%.dts}.dtb"
if ! grep -qF "$dtb" \
	"$KERNEL_DIR/arch/arm64/boot/dts/rockchip/Makefile"; then
	printf '\ndtb-$(CONFIG_ARCH_ROCKCHIP) += %s\n' "$dtb" \
		>> "$KERNEL_DIR/arch/arm64/boot/dts/rockchip/Makefile"
fi

printf '%s\n' "$SOURCE_INPUT_HASH" > "$SOURCE_STAMP"

echo "Linux $LINUX_VERSION kernel tree ready: $KERNEL_DIR"
