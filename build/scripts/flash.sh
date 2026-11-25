#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="${SDK_ROOT:-$(realpath "$SCRIPT_DIR/../..")}"
UPDATE_IMAGE="${UPDATE_IMAGE:-$SDK_ROOT/output/firmware/update.img}"
ARKT="${ARKT:-arkt}"

[ -r "$UPDATE_IMAGE" ] || {
	echo "missing update image: $UPDATE_IMAGE" >&2
	exit 1
}

"$ARKT" flash "$UPDATE_IMAGE"
