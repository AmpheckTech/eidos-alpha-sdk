#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="${SDK_ROOT:-$(realpath "$SCRIPT_DIR/../..")}"
RK_BIN_DIR="${RK_BIN_DIR:-$SDK_ROOT/output/rkbin}"
RK_BIN_MANIFEST="${RK_BIN_MANIFEST:-$SDK_ROOT/boards/ampheck/eidos-alpha/firmware/rkbin.toml}"
ARKT="${ARKT:-arkt}"

command -v "$ARKT" >/dev/null || {
	echo "ARKT not found: $ARKT" >&2
	exit 1
}

[ -r "$RK_BIN_MANIFEST" ] || {
	echo "missing rkbin manifest: $RK_BIN_MANIFEST" >&2
	exit 1
}

"$ARKT" assets ensure \
	--manifest "$RK_BIN_MANIFEST" \
	--output "$RK_BIN_DIR" \
	--hardlink

for file in \
	rk3566_ddr_1056MHz_v1.25.bin \
	rk3568_bl31_v1.46.elf \
	rk3568_bl32_v2.16.bin; do
	[ -r "$RK_BIN_DIR/$file" ] || {
		echo "missing rkbin asset: $RK_BIN_DIR/$file" >&2
		exit 1
	}
done

echo "Rockchip boot firmware ready: $RK_BIN_DIR"
