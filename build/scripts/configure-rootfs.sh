#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="${SDK_ROOT:-$(realpath "$SCRIPT_DIR/../..")}"
TARGET="${1:-${ROOTFS_ROOT:-$SDK_ROOT/output/rootfs/root}}"
BOARD_DIR="${BOARD_DIR:-$SDK_ROOT/boards/ampheck/eidos-alpha}"
COMMON_OVERLAY_DIR="${COMMON_OVERLAY_DIR:-$SDK_ROOT/common/overlays/rootfs}"
BOARD_OVERLAY_DIR="${BOARD_OVERLAY_DIR:-$BOARD_DIR/overlays/rootfs}"
BOARD_FIRMWARE_DIR="${BOARD_FIRMWARE_DIR:-$BOARD_DIR/firmware}"
LEGAL_DIR="${LEGAL_DIR:-$SDK_ROOT/legal}"

if [ "$(id -u)" -eq 0 ]; then
	SUDO=
else
	SUDO=sudo
fi

copy_tree()
{
	local source="$1"
	local dest="$2"
	[ -d "$source" ] || return 0
	$SUDO mkdir -p "$dest"
	$SUDO cp -a --no-preserve=ownership "$source/." "$dest/"
}

install_root_file()
{
	local mode="$1"
	local source="$2"
	local dest="$3"
	$SUDO install -D -m "$mode" "$source" "$TARGET$dest"
}

enable_unit()
{
	local unit="$1"
	local target="$2"
	local unit_file="$TARGET/usr/lib/systemd/system/$unit"

	[ -r "$unit_file" ] || {
		echo "missing systemd unit: $unit_file" >&2
		exit 1
	}
	$SUDO mkdir -p "$TARGET/etc/systemd/system/$target.wants"
	$SUDO ln -sfn "/usr/lib/systemd/system/$unit" \
		"$TARGET/etc/systemd/system/$target.wants/$unit"
}

if [ ! -x "$TARGET/bin/bash" ]; then
	echo "rootfs is not bootstrapped: $TARGET" >&2
	exit 1
fi

echo "Configuring rootfs: $TARGET"

printf '%s\n' "$ROOTFS_HOSTNAME" | $SUDO tee "$TARGET/etc/hostname" >/dev/null
$SUDO touch "$TARGET/etc/hosts"
$SUDO sed -i '/^127\.0\.1\.1[[:space:]]/d' "$TARGET/etc/hosts"
printf '127.0.1.1\t%s\n' "$ROOTFS_HOSTNAME" | \
	$SUDO tee -a "$TARGET/etc/hosts" >/dev/null

$SUDO mkdir -p "$TARGET/etc/default" "$TARGET/etc/profile.d"
if [ -f "$TARGET/etc/default/locale" ]; then
	$SUDO sed -i '/^LANG=/d' "$TARGET/etc/default/locale"
	printf 'LANG=%s\n' "$ROOTFS_LOCALE" | \
		$SUDO tee -a "$TARGET/etc/default/locale" >/dev/null
else
	printf 'export LANG=%s\n' "$ROOTFS_LOCALE" | \
		$SUDO tee "$TARGET/etc/profile.d/lang.sh" >/dev/null
fi

if [ -f "$TARGET/etc/os-release" ]; then
	$SUDO sed -i '/^ID_LIKE=/d' "$TARGET/etc/os-release"
	printf 'ID_LIKE="debian"\n' | $SUDO tee -a "$TARGET/etc/os-release" >/dev/null
fi

$SUDO mkdir -p "$TARGET/etc"
$SUDO tee "$TARGET/etc/fstab" >/dev/null <<'EOF'
/dev/root	/	ext4	defaults	0 1
proc	/proc	proc	defaults	0 0
devtmpfs	/dev	devtmpfs	defaults	0 0
devpts	/dev/pts	devpts	mode=0620,ptmxmode=0000,gid=5	0 0
tmpfs	/dev/shm	tmpfs	nosuid,nodev,noexec	0 0
sysfs	/sys	sysfs	nosuid,nodev,noexec	0 0
configfs	/sys/kernel/config	configfs	defaults	0 0
debugfs	/sys/kernel/debug	debugfs	defaults	0 0
pstore	/sys/fs/pstore	pstore	nosuid,nodev,noexec	0 0
tmpfs	/tmp	tmpfs	mode=1777	0 0
PARTLABEL=boot	/boot/efi	vfat	umask=0077	0 1
PARTLABEL=data	/data	ext4	defaults	0 2
EOF

$SUDO mkdir -p "$TARGET/boot/efi" "$TARGET/data"

# Rootfs payloads are plain overlays. Apply common first, then let the board
# override any file with the same path.
copy_tree "$COMMON_OVERLAY_DIR" "$TARGET"
copy_tree "$BOARD_OVERLAY_DIR" "$TARGET"

# Keep the complete legal bundle in the generated image as well as in the
# source repository and release assets.
install_root_file 0644 "$SDK_ROOT/NOTICE" "/usr/share/doc/eidos-alpha/NOTICE"
install_root_file 0644 "$SDK_ROOT/LICENSE" "/usr/share/doc/eidos-alpha/LICENSE"
copy_tree "$LEGAL_DIR" "$TARGET/usr/share/doc/eidos-alpha/legal"
install_root_file 0644 "$BOARD_FIRMWARE_DIR/rockchip/LICENSE" \
	"/usr/share/doc/eidos-alpha/legal/rockchip-rkbin-LICENSE"

read -r -a rootfs_units <<< "${ROOTFS_ENABLE_UNITS:-}"
for unit in "${rootfs_units[@]}"; do
	enable_unit "$unit" multi-user.target
done

# Root filesystem check orchestration.
$SUDO mkdir -p "$TARGET/etc/systemd/system/systemd-fsck-root.service.wants"
$SUDO ln -sfn /usr/lib/systemd/system/systemd-fsck-prepare.service \
	"$TARGET/etc/systemd/system/systemd-fsck-root.service.wants/systemd-fsck-prepare.service"

# USB gadget.
$SUDO tee "$TARGET/etc/profile.d/usb-gadget.sh" >/dev/null <<EOF
export USB_FUNCS="${USB_GADGET_FUNCS:-adb}"
export USB_VENDOR_ID="$USB_VID"
export USB_PRODUCT_ID="$USB_PID"
export USB_FW_VERSION="$USB_FW_VERSION"
export USB_MANUFACTURER="$USB_MANUFACTURER"
export USB_PRODUCT="$USB_PRODUCT"
EOF
printf '#!/bin/sh\nexec tail -f -n "${1:-99999999}" /var/log/messages\n' | \
	$SUDO tee "$TARGET/usr/bin/logcat" >/dev/null
$SUDO chmod 0755 "$TARGET/usr/bin/logcat"
$SUDO ln -sfn usb-gadget "$TARGET/usr/bin/usbdevice"
$SUDO mkdir -p "$TARGET/etc/usb-gadget.d"
$SUDO ln -sfn usb-gadget.d "$TARGET/etc/usbdevice.d"

[ -x "$TARGET/usr/bin/usb-gadget" ] || {
	echo "missing rootfs executable: $TARGET/usr/bin/usb-gadget" >&2
	exit 1
}

# Kernel, device tree and GRUB configuration.
KERNEL_RELEASE="$(make -s -C "$KERNEL_DIR" --no-print-directory kernelrelease)"
ROOTFS_UUID="$(sed -n 's/^uuid:rootfs=//p' \
	"$BOARD_FIRMWARE_DIR/$PARAMETER_FILE" | head -n 1)"
[ -n "$ROOTFS_UUID" ] || {
	echo "missing rootfs PARTUUID in $BOARD_FIRMWARE_DIR/$PARAMETER_FILE" >&2
	exit 1
}
BOOTARGS="$(strings "$KERNEL_DTB" | grep -m 1 'root=PARTUUID=' || true)"
if [ -n "$BOOTARGS" ]; then
	BOOTARGS="$(printf '%s\n' "$BOOTARGS" | \
		sed -E "s#root=PARTUUID=[^ ]+#root=PARTUUID=$ROOTFS_UUID#")"
else
	BOOTARGS="root=PARTUUID=$ROOTFS_UUID rootfstype=ext4 rw rootwait"
fi
case " $BOOTARGS " in
	*" efi=noruntime "*) ;;
	*) BOOTARGS="$BOOTARGS efi=noruntime" ;;
esac

install_root_file 0644 "$KERNEL_IMAGE" "/boot/vmlinuz-$KERNEL_RELEASE"
install_root_file 0644 "$KERNEL_DTB" "/boot/dtb/rockchip/$(basename "$KERNEL_DTB")"
$SUDO mkdir -p "$TARGET/boot/grub"
$SUDO tee "$TARGET/boot/grub/grub.cfg" >/dev/null <<EOF
set default=0
set timeout=3
set timeout_style=menu

menuentry "Ubuntu (Linux $KERNEL_RELEASE)" --class ubuntu {
	linux /boot/vmlinuz-$KERNEL_RELEASE $BOOTARGS
	devicetree /boot/dtb/rockchip/$(basename "$KERNEL_DTB")
}
EOF

# Kernel modules and dependency metadata.
find "$MODULES_DIR/lib/modules/$KERNEL_RELEASE" -name '*.ko' -print0 | \
	xargs -0 -r "$CROSS_COMPILE"strip --strip-unneeded
$SUDO rm -rf "$TARGET/lib/modules/$KERNEL_RELEASE"
$SUDO mkdir -p "$TARGET/lib/modules"
$SUDO cp -a --no-preserve=ownership "$MODULES_DIR/lib/modules/$KERNEL_RELEASE" \
	"$TARGET/lib/modules/"
$SUDO depmod -b "$TARGET" "$KERNEL_RELEASE"

echo "Rootfs configured: $TARGET"
