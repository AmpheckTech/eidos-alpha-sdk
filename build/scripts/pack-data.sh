#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
SDK_ROOT="${SDK_ROOT:-$(realpath "$SCRIPT_DIR/../..")}"
IMAGE="${1:-${DATA_IMAGE:-$SDK_ROOT/output/images/data.img}}"
SIZE="${DATA_IMAGE_SIZE:-8M}"
IMAGE_STAMP="${DATA_IMAGE_STAMP:-$IMAGE.inputs.sha256}"
input_hash="$({
	printf '%s\n' "format=1" "SIZE=$SIZE"
	eidos_hash_files "$SCRIPT_DIR/pack-data.sh" "$SCRIPT_DIR/lib.sh"
} | sha256sum | cut -d' ' -f1)"

if [ "${FORCE:-0}" != 1 ] && [ -s "$IMAGE" ] && \
	[ -s "$IMAGE_STAMP" ] && [ "$(cat "$IMAGE_STAMP")" = "$input_hash" ]; then
	echo "Data image is up to date: $IMAGE"
	exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$(dirname "$IMAGE")"
rm -f "$IMAGE"
truncate -s "$SIZE" "$IMAGE"
mkfs.ext4 -q -F -L data -d "$TMP" "$IMAGE"
e2fsck -fn "$IMAGE" >/dev/null
printf '%s\n' "$input_hash" > "$IMAGE_STAMP"

echo "Data image ready: $IMAGE"
