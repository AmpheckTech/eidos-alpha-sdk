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
ESP_CFG="$ESP_ROOT/EFI/BOOT/grub.cfg"
ESP_ENV="$ESP_ROOT/EFI/BOOT/grubenv"
KERNEL_RELEASE="$(make -s -C "$KERNEL_DIR" --no-print-directory kernelrelease)"
ROOTFS_UUID="$(sed -n 's/^uuid:rootfs=//p' \
	"$BOARD_FIRMWARE_DIR/$PARAMETER_FILE" | head -n 1)"
ESP_KERNEL="$ESP_ROOT/EFI/BOOT/vmlinuz-$KERNEL_RELEASE"
ESP_DTB="$ESP_ROOT/EFI/BOOT/$(basename "$KERNEL_DTB")"
EMBED_CFG="$WORK_DIR/grub-embed.cfg"

require_tools()
{
	local tool
	for tool in ar curl file grub-editenv grub-mkstandalone mcopy mdir mkfs.vfat \
		sha256sum tar truncate; do
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

[ -r "$KERNEL_IMAGE" ] || {
	echo "missing kernel image: $KERNEL_IMAGE" >&2
	exit 1
}
[ -r "$KERNEL_DTB" ] || {
	echo "missing kernel DTB: $KERNEL_DTB" >&2
	exit 1
}
[ -n "$ROOTFS_UUID" ] || {
	echo "missing rootfs PARTUUID in $PARAMETER_FILE" >&2
	exit 1
}

cp "$KERNEL_IMAGE" "$ESP_KERNEL"
cp "$KERNEL_DTB" "$ESP_DTB"
grub-editenv "$ESP_ENV" create

cat > "$ESP_CFG" <<EOF
search --no-floppy --file --set=esp /EFI/BOOT/$(basename "$ESP_KERNEL")
if [ -f (\$esp)/EFI/BOOT/grubenv ]; then
	load_env -f (\$esp)/EFI/BOOT/grubenv
fi
set default=0
set timeout=3
set timeout_style=menu
if [ "\${boot_failed}" = "1" ]; then
	set default=1
fi
set fallback=1

menuentry "Ubuntu (Linux $KERNEL_RELEASE)" --class ubuntu {
	search --no-floppy --file --set=esp /EFI/BOOT/$(basename "$ESP_KERNEL")
	set boot_failed=1
	save_env -f (\$esp)/EFI/BOOT/grubenv boot_failed
	linux (\$esp)/EFI/BOOT/$(basename "$ESP_KERNEL") root=PARTUUID=$ROOTFS_UUID rootfstype=ext4 rw rootwait efi=noruntime
	devicetree (\$esp)/EFI/BOOT/$(basename "$ESP_DTB")
}

menuentry "Recovery (single user)" --class recovery {
	search --no-floppy --file --set=esp /EFI/BOOT/$(basename "$ESP_KERNEL")
	linux (\$esp)/EFI/BOOT/$(basename "$ESP_KERNEL") root=PARTUUID=$ROOTFS_UUID rootfstype=ext4 rw rootwait efi=noruntime init=/bin/bash
	devicetree (\$esp)/EFI/BOOT/$(basename "$ESP_DTB")
}
EOF

cat > "$EMBED_CFG" <<'EOF'
search --no-floppy --file --set=esp /EFI/BOOT/grub.cfg
if [ -n "$esp" ]; then
	set prefix=($esp)/EFI/BOOT
	configfile ($esp)/EFI/BOOT/grub.cfg
fi
EOF

grub-mkstandalone -O arm64-efi \
	--directory="$GRUB_MODULE_DIR" \
	--modules="normal search search_fs_file search_label linux fdt ext2 fat part_gpt efi_gop terminal serial configfile loadenv" \
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
