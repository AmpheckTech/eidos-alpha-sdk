# Ampheck Eidos Alpha board description.

BOARD_VENDOR := ampheck
BOARD_NAME := eidos-alpha
BOARD_CHIP := rk3566
BOARD_ARCH := arm64
BOARD_CROSS_COMPILE ?= aarch64-linux-gnu-

KERNEL_VERSION := 7.3.4
KERNEL_TARBALL := linux-$(KERNEL_VERSION).tar.xz
KERNEL_URL := https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-$(KERNEL_VERSION).tar.xz
KERNEL_SHA256 := b11b6df8295e8e991ff040b71aaa4994a8b55caa23b6b092907f195b5840fd1f
KERNEL_DEFCONFIG := eidos_alpha_defconfig
KERNEL_DTS := rk3566-ampheck-eidos-alpha
KERNEL_IMAGE := kernel/arch/$(BOARD_ARCH)/boot/Image
KERNEL_DTB := kernel/$(KERNEL_DTS).dtb

UBOOT_VERSION := 2026.10
UBOOT_TARBALL := u-boot-$(UBOOT_VERSION).tar.gz
UBOOT_URL := https://codeload.github.com/u-boot/u-boot/tar.gz/refs/tags/v$(UBOOT_VERSION)
UBOOT_SHA256 := f943a88389c8fd70a6b0d061a88267465e143c7ca6ea2b75837ab20f5b60c739
UBOOT_DEFCONFIG := ampheck-eidos-alpha-rk3566_defconfig
UBOOT_BL31 := boards/$(BOARD_VENDOR)/$(BOARD_NAME)/firmware/rockchip/rk3568_bl31_v1.46.elf
UBOOT_TPL := boards/$(BOARD_VENDOR)/$(BOARD_NAME)/firmware/rockchip/rk3566_ddr_1056MHz_v1.25.bin
MINILOADER := boards/$(BOARD_VENDOR)/$(BOARD_NAME)/firmware/rockchip/rk3568_miniloader_ldr.bin

UBUNTU_VERSION := 24.04.5
UBUNTU_SUITE := noble
UBUNTU_ARCH := arm64
UBUNTU_MIRROR := http://mirrors.aliyun.com/ubuntu-ports
UBUNTU_BASE_URL := https://cdimage.ubuntu.com/ubuntu-base/releases/$(UBUNTU_VERSION)/release
UBUNTU_BASE_SHA256 := a91d5a93010193712d346d761372b7c9db6dfcf093893161c64ca107f05914f2
UBUNTU_ROOT_PASSWORD ?=
UBUNTU_PACKAGES := \
	vim sudo bash-completion kmod procps util-linux rsyslog htop curl wget \
	openssh-server locales net-tools iputils-ping ethtool iw \
	ca-certificates usbutils pciutils i2c-tools lm-sensors picocom \
	device-tree-compiler sysfsutils psmisc strace evtest dosfstools parted \
	e2fsprogs weston libgl1-mesa-dri wayland-utils libts-bin libqmi-utils \
	modemmanager network-manager usb-modeswitch usb-modeswitch-data \
	wpasupplicant rfkill wireless-regdb systemd-timesyncd fonts-dejavu-core \
	libinput-bin logrotate irqbalance grub-common
ROOTFS_IMAGE_HEADROOM := 512M
ROOTFS_IMAGE_MIN_SIZE := 1024M
ROOTFS_LABEL := rootfs
ROOTFS_HOSTNAME := ampheck-eidos-alpha
ROOTFS_LOCALE := en_US.UTF-8
ROOTFS_UBUNTU_USER := ubuntu
ROOTFS_UBUNTU_PASSWORD ?= eidos
ROOTFS_ENABLE_UNITS := irqbalance.service adbd.service \
	eidos-grow-rootfs.service eidos-grow-data.service eidos-boot-success.service \
	eidos-pstore-archive.service
ROOTFS_MASK_UNITS := usb-gadget.service

USB_VID := 0x2207
USB_PID := 0
USB_FW_VERSION := 0x0310
USB_MANUFACTURER := Rockchip
USB_PRODUCT := rk3xxx
USB_GADGET_FUNCS := adb

PARAMETER_FILE := parameter-ubuntu-fit.txt
PACKAGE_FILE := package-file
BOOT_ESP_SIZE := 64M
BOOT_ESP_GRUB_DEB_URL := https://mirrors.aliyun.com/ubuntu-ports/pool/main/g/grub2-unsigned/grub-efi-arm64-bin_2.12-1ubuntu7.3_arm64.deb
BOOT_ESP_GRUB_DEB_SHA256 := d43219525621449cd795dd0a932f28729ea7da391115d84436c90521ab30ed31
DATA_IMAGE_SIZE := 8M
