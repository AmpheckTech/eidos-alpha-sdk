#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="${SDK_ROOT:-$(realpath "$SCRIPT_DIR/../..")}"
OUTPUT_DIR="${OUTPUT_DIR:-$SDK_ROOT/output}"
RK_BIN_DIR="${RK_BIN_DIR:-$OUTPUT_DIR/rkbin}"
UBOOT_BUILD="${UBOOT_BUILD:-$OUTPUT_DIR/uboot-build}"
BOOT_MERGER="$RK_BIN_DIR/tools/boot_merger"
DDR="$RK_BIN_DIR/rk3566_ddr_1056MHz_v1.25.bin"
SPL="$RK_BIN_DIR/rk356x_spl_v1.14.bin"
USBPLUG="$RK_BIN_DIR/rk356x_usbplug_v1.17.bin"
OUTPUT="$UBOOT_BUILD/MiniLoaderAll.bin"
TMP_DIR=

cleanup()
{
	[ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
}
trap cleanup EXIT

for file in "$BOOT_MERGER" "$DDR" "$SPL" "$USBPLUG"; do
	[ -r "$file" ] || {
		echo "missing loader input: $file" >&2
		exit 1
	}
done
[ -x "$BOOT_MERGER" ] || {
	echo "boot merger is not executable: $BOOT_MERGER" >&2
	exit 1
}

mkdir -p "$UBOOT_BUILD"
TMP_DIR="$(mktemp -d "$UBOOT_BUILD/.miniloader.XXXXXX")"
mkdir -p "$TMP_DIR/bin/rk35"
for file in "$DDR" "$SPL" "$USBPLUG"; do
	ln "$file" "$TMP_DIR/bin/rk35/${file##*/}" 2>/dev/null || \
		cp -f "$file" "$TMP_DIR/bin/rk35/${file##*/}"
done

cat > "$TMP_DIR/RK3566MINIALL.ini" <<'EOF'
[CHIP_NAME]
NAME=RK3568
[VERSION]
MAJOR=1
MINOR=1
[CODE471_OPTION]
NUM=1
Path1=bin/rk35/rk3566_ddr_1056MHz_v1.25.bin
Sleep=1
[CODE472_OPTION]
NUM=1
Path1=bin/rk35/rk356x_usbplug_v1.17.bin
[LOADER_OPTION]
NUM=2
LOADER1=FlashData
LOADER2=FlashBoot
FlashData=bin/rk35/rk3566_ddr_1056MHz_v1.25.bin
FlashBoot=bin/rk35/rk356x_spl_v1.14.bin
[OUTPUT]
PATH=MiniLoaderAll.bin
[SYSTEM]
NEWIDB=true
[FLAG]
471_RC4_OFF=true
RC4_OFF=true
EOF

(cd "$TMP_DIR" && "$BOOT_MERGER" RK3566MINIALL.ini)

[ -s "$TMP_DIR/MiniLoaderAll.bin" ] || {
	echo "boot merger produced no loader" >&2
	exit 1
}
[ "$(head -c 3 "$TMP_DIR/MiniLoaderAll.bin")" = LDR ] || {
	echo "boot merger output is not a Rockchip USB loader" >&2
	exit 1
}

install -m 0644 "$TMP_DIR/MiniLoaderAll.bin" "$OUTPUT"
echo "MiniLoader ready: $OUTPUT"
