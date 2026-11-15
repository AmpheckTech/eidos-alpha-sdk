#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="${SDK_ROOT:-$(realpath "$SCRIPT_DIR/../..")}"
IMAGE="${1:-${DATA_IMAGE:-$SDK_ROOT/output/images/data.img}}"
SIZE="${DATA_IMAGE_SIZE:-8M}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$(dirname "$IMAGE")"
rm -f "$IMAGE"
truncate -s "$SIZE" "$IMAGE"
mkfs.ext4 -q -F -L data -d "$TMP" "$IMAGE"
e2fsck -fn "$IMAGE" >/dev/null

echo "Data image ready: $IMAGE"
