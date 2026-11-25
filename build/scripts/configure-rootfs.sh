#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
SDK_ROOT="${SDK_ROOT:-$(realpath "$SCRIPT_DIR/../..")}"
TARGET="${1:-${ROOTFS_ROOT:-$SDK_ROOT/output/rootfs/root}}"
ROOTFS_LOCALE="${ROOTFS_LOCALE:-en_US.UTF-8}"
BOARD_DIR="${BOARD_DIR:-$SDK_ROOT/boards/ampheck/eidos-alpha}"
COMMON_OVERLAY_DIR="${COMMON_OVERLAY_DIR:-$SDK_ROOT/common/overlays/rootfs}"
BOARD_OVERLAY_DIR="${BOARD_OVERLAY_DIR:-$BOARD_DIR/overlays/rootfs}"
BOARD_FIRMWARE_DIR="${BOARD_FIRMWARE_DIR:-$BOARD_DIR/firmware}"
LEGAL_DIR="${LEGAL_DIR:-$SDK_ROOT/legal}"
CONFIG_STAMP="${ROOTFS_CONFIG_STAMP:-$(dirname "$TARGET")/.rootfs-config.sha256}"

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

rootfs_config_input_hash()
{
	local bootstrap_key=

	if [ -r "$TARGET/.bootstrap-key" ]; then
		bootstrap_key="$(cat "$TARGET/.bootstrap-key")"
	fi

	{
		printf '%s\n' \
			"format=1" \
			"bootstrap-key=$bootstrap_key" \
			"ROOTFS_HOSTNAME=$ROOTFS_HOSTNAME" \
			"ROOTFS_LOCALE=$ROOTFS_LOCALE" \
			"ROOTFS_UBUNTU_USER=$ROOTFS_UBUNTU_USER" \
			"ROOTFS_ENABLE_UNITS=$ROOTFS_ENABLE_UNITS" \
			"ROOTFS_MASK_UNITS=$ROOTFS_MASK_UNITS" \
			"USB_GADGET_FUNCS=${USB_GADGET_FUNCS:-adb}" \
			"USB_VID=$USB_VID" "USB_PID=$USB_PID" \
			"USB_FW_VERSION=$USB_FW_VERSION" \
			"USB_MANUFACTURER=$USB_MANUFACTURER" "USB_PRODUCT=$USB_PRODUCT" \
			"PARAMETER_FILE=$PARAMETER_FILE" \
			"KERNEL_DTB=$(basename "$KERNEL_DTB")"
		eidos_hash_files \
			"$KERNEL_IMAGE" "$KERNEL_DTB" "$SDK_ROOT/NOTICE" \
			"$SDK_ROOT/LICENSE" "$BOARD_FIRMWARE_DIR/rockchip/LICENSE" \
			"$BOARD_FIRMWARE_DIR/$PARAMETER_FILE" "$BOARD_DIR/board.mk" \
			"$SCRIPT_DIR/configure-rootfs.sh" "$SCRIPT_DIR/lib.sh"
		eidos_hash_tree "$MODULES_DIR" ""
		eidos_hash_tree "$COMMON_OVERLAY_DIR" ""
		eidos_hash_tree "$BOARD_OVERLAY_DIR" ""
		eidos_hash_tree "$LEGAL_DIR" ""
	} | sha256sum | cut -d' ' -f1
}

if [ ! -x "$TARGET/bin/bash" ]; then
	echo "rootfs is not bootstrapped: $TARGET" >&2
	exit 1
fi

input_hash="$(rootfs_config_input_hash)"
if [ "${FORCE:-0}" != 1 ] && [ -s "$CONFIG_STAMP" ] && \
	[ "$(cat "$CONFIG_STAMP")" = "$input_hash" ] && \
	[ -x "$TARGET/usr/bin/usb-gadget" ]; then
	echo "Rootfs configuration is up to date: $TARGET"
	exit 0
fi

echo "Configuring rootfs: $TARGET"

printf '%s\n' "$ROOTFS_HOSTNAME" | $SUDO tee "$TARGET/etc/hostname" >/dev/null
$SUDO touch "$TARGET/etc/hosts"
$SUDO sed -i '/^127\.0\.1\.1[[:space:]]/d' "$TARGET/etc/hosts"
printf '127.0.1.1\t%s\n' "$ROOTFS_HOSTNAME" | \
	$SUDO tee -a "$TARGET/etc/hosts" >/dev/null

$SUDO mkdir -p "$TARGET/etc/default" "$TARGET/etc/profile.d"
printf 'LANG=%s\n' "$ROOTFS_LOCALE" | \
	$SUDO tee "$TARGET/etc/locale.conf" >/dev/null
$SUDO ln -sfn ../locale.conf "$TARGET/etc/default/locale"

if [ -f "$TARGET/etc/os-release" ]; then
	$SUDO sed -i '/^ID_LIKE=/d' "$TARGET/etc/os-release"
	printf 'ID_LIKE="debian"\n' | $SUDO tee -a "$TARGET/etc/os-release" >/dev/null
fi

$SUDO mkdir -p "$TARGET/etc"
$SUDO tee "$TARGET/etc/fstab" >/dev/null <<'EOF'
/dev/root	/	ext4	defaults	0 0
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

# Allow only the configured login user to use sudo without a password.
case "$ROOTFS_UBUNTU_USER" in
	''|*[!A-Za-z0-9_.-]*|[!A-Za-z0-9_]*)
		echo "invalid ROOTFS_UBUNTU_USER: $ROOTFS_UBUNTU_USER" >&2
		exit 1
		;;
esac
if ! awk -F: -v user="$ROOTFS_UBUNTU_USER" \
	'$1 == user { found = 1 } END { exit !found }' "$TARGET/etc/passwd"; then
	echo "rootfs user does not exist: $ROOTFS_UBUNTU_USER" >&2
	exit 1
fi
sudoers_tmp="$(mktemp)"
trap 'unlink "$sudoers_tmp"' EXIT
printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$ROOTFS_UBUNTU_USER" > "$sudoers_tmp"
if command -v visudo >/dev/null 2>&1; then
	visudo -cf "$sudoers_tmp" >/dev/null
fi
$SUDO install -D -m 0440 "$sudoers_tmp" \
	"$TARGET/etc/sudoers.d/90-eidos-user"
unlink "$sudoers_tmp"
trap - EXIT

# adbd hardcodes /bin/sh for shell sessions. Route only adbd-launched shells
# to bash; package scripts and system services continue to use dash.
$SUDO unlink "$TARGET/bin/sh" 2>/dev/null || true
install_root_file 0755 "$COMMON_OVERLAY_DIR/usr/local/libexec/adbd-shell" "/bin/sh"

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

read -r -a rootfs_masked_units <<< "${ROOTFS_MASK_UNITS:-}"
for unit in "${rootfs_masked_units[@]}"; do
	$SUDO ln -sfn /dev/null "$TARGET/etc/systemd/system/$unit"
done

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
KERNEL_RELEASE="$(make -s -C "$KERNEL_DIR" --no-print-directory LOCALVERSION= kernelrelease)"
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
set fallback=1

menuentry "Ubuntu (Linux $KERNEL_RELEASE)" --class ubuntu {
	linux /boot/vmlinuz-$KERNEL_RELEASE $BOOTARGS
	devicetree /boot/dtb/rockchip/$(basename "$KERNEL_DTB")
}

menuentry "Recovery (single user)" --class recovery {
	linux /boot/vmlinuz-$KERNEL_RELEASE $BOOTARGS init=/bin/bash
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

printf '%s\n' "$input_hash" > "$CONFIG_STAMP"
echo "Rootfs configured: $TARGET"
