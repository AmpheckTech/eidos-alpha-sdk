#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="${SDK_ROOT:-$(realpath "$SCRIPT_DIR/../..")}"
OUTPUT_DIR="${OUTPUT_DIR:-$SDK_ROOT/output}"
CACHE_DIR="${CACHE_DIR:-$OUTPUT_DIR/cache}"
BOOT_IMAGE="${BOOT_IMAGE:-$OUTPUT_DIR/images/boot.img}"

GRUB_DEB_NAME="${BOOT_ESP_GRUB_DEB_URL##*/}"
GRUB_DEB="$CACHE_DIR/$GRUB_DEB_NAME"
GRUB_UNPACK="$CACHE_DIR/grub-efi-arm64"
GRUB_MODULE_DIR="$GRUB_UNPACK/usr/lib/grub/arm64-efi"
WORK_DIR="$OUTPUT_DIR/efi-boot"
ESP_ROOT="$WORK_DIR/root"
BOOTAA64_EFI="$ESP_ROOT/EFI/BOOT/BOOTAA64.EFI"
EMBED_CFG="$WORK_DIR/grub-embed.cfg"

require_tools()
{
	local tool
	for tool in ar curl file grub-mkstandalone mcopy mdir mkfs.vfat sha256sum \
		tar truncate; do
		command -v "$tool" >/dev/null || {
			echo "missing ESP build tool: $tool" >&2
			exit 1
		}
	done
}

download_grub()
{
	local part="$GRUB_DEB.part"
	if [ -s "$GRUB_DEB" ] && \
		echo "$BOOT_ESP_GRUB_DEB_SHA256  $GRUB_DEB" | sha256sum -c - >/dev/null 2>&1; then
		return 0
	fi
	mkdir -p "$CACHE_DIR"
	rm -f "$GRUB_DEB" "$part"
	echo "Downloading GRUB ARM64"
	curl -fL --retry 3 --retry-delay 2 -o "$part" "$BOOT_ESP_GRUB_DEB_URL"
	echo "$BOOT_ESP_GRUB_DEB_SHA256  $part" | sha256sum -c -
	mv "$part" "$GRUB_DEB"
}

unpack_grub()
{
	local data_member tmp stamp
	stamp="$GRUB_UNPACK/.deb-sha256"
	if [ -r "$GRUB_MODULE_DIR/moddep.lst" ] && [ -r "$stamp" ] && \
		[ "$(cat "$stamp")" = "$BOOT_ESP_GRUB_DEB_SHA256" ]; then
		return 0
	fi
	rm -rf "$GRUB_UNPACK"
	mkdir -p "$GRUB_UNPACK"
	tmp="$(mktemp -d)"
	trap 'rm -rf "$tmp"' EXIT
	data_member="$(ar t "$GRUB_DEB" | grep '^data\.tar' | head -n 1)"
	[ -n "$data_member" ] || {
		echo "GRUB package has no data archive" >&2
		exit 1
	}
	(
		cd "$tmp"
		ar x "$GRUB_DEB" "$data_member"
	)
	tar -xf "$tmp/$data_member" -C "$GRUB_UNPACK"
	printf '%s\n' "$BOOT_ESP_GRUB_DEB_SHA256" > "$stamp"
	rm -rf "$tmp"
	trap - EXIT
}

require_tools
download_grub
unpack_grub
rm -rf "$WORK_DIR"
mkdir -p "$(dirname "$BOOTAA64_EFI")"

cat > "$EMBED_CFG" <<'EOF'
search --no-floppy --label rootfs --set=root
set prefix=($root)/boot/grub
configfile ($root)/boot/grub/grub.cfg
EOF

grub-mkstandalone -O arm64-efi \
	--directory="$GRUB_MODULE_DIR" \
	--modules="normal search search_label linux fdt ext2 fat part_gpt efi_gop terminal serial configfile" \
	-o "$BOOTAA64_EFI" \
	"boot/grub/grub.cfg=$EMBED_CFG"

case "$(file -b "$BOOTAA64_EFI")" in
	*PE32+*AArch64*|*PE32+*Aarch64*|*PE32+*ARM64*) ;;
	*)
		echo "BOOTAA64.EFI is not an ARM64 EFI binary" >&2
		exit 1
		;;
esac

mkdir -p "$(dirname "$BOOT_IMAGE")"
rm -f "$BOOT_IMAGE"
truncate -s "$BOOT_ESP_SIZE" "$BOOT_IMAGE"
mkfs.vfat -F 32 -n boot "$BOOT_IMAGE"
MTOOLS_SKIP_CHECK=1 mcopy -bspmn -D s -i "$BOOT_IMAGE" "$ESP_ROOT"/* ::/
mdir -i "$BOOT_IMAGE" ::/EFI/BOOT/BOOTAA64.EFI >/dev/null
echo "EFI image ready: $BOOT_IMAGE"
