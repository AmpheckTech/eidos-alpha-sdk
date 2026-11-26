#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

ARKT_VERSION="${ARKT_VERSION:-v0.1.3-rc.2}"
ARKT_DOWNLOAD_URL="${ARKT_DOWNLOAD_URL:-https://github.com/AmpheckTech/RockchipToolkit/releases/download/$ARKT_VERSION/arkt-$ARKT_VERSION-linux-x64}"
ARKT_SHA256="${ARKT_SHA256:-6ccbcf0bed2748492fefceb43a03ee919eae8e92c04a206056b18848963c2d86}"
ARKT_CACHE_DIR="${ARKT_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/eidos/arkt}"
ARKT_INSTALL_DIR="${ARKT_INSTALL_DIR:-/usr/local/bin}"
CACHE_FILE="$ARKT_CACHE_DIR/arkt-$ARKT_VERSION-linux-x64"
ARKT_BIN="$ARKT_INSTALL_DIR/arkt"

eidos_download_verified "$ARKT_DOWNLOAD_URL" "$CACHE_FILE" "$ARKT_SHA256" \
	3 "ARKT $ARKT_VERSION" || {
	echo "failed to download or verify ARKT $ARKT_VERSION" >&2
	exit 1
}

install -d -m 0755 "$ARKT_INSTALL_DIR"
install -m 0755 "$CACHE_FILE" "$ARKT_BIN"

"$ARKT_BIN" --version
"$ARKT_BIN" assets ensure --help >/dev/null
"$ARKT_BIN" image --help >/dev/null
"$ARKT_BIN" image pack --help >/dev/null
"$ARKT_BIN" verify --help >/dev/null
