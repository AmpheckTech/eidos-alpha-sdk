SHELL := /bin/bash
.DEFAULT_GOAL := all

SUDO := $(shell if [ "$$(id -u)" -eq 0 ]; then echo; else echo sudo; fi)

SDK_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
BUILD_DIR := $(SDK_ROOT)/build
SCRIPTS_DIR := $(BUILD_DIR)/scripts
COMMON_DIR := $(SDK_ROOT)/common
COMMON_OVERLAY_DIR := $(COMMON_DIR)/overlays/rootfs
COMMON_PACKAGES_DIR := $(COMMON_DIR)/packages
COMMON_LOCAL_PACKAGE_DIR := $(COMMON_PACKAGES_DIR)/local
COMMON_DEB_DIR := $(COMMON_PACKAGES_DIR)/debs
COMMON_EXTRA_DEB_MANIFEST := $(COMMON_PACKAGES_DIR)/third-party-debs.txt
COMMON_KERNEL_PATCH_DIR := $(COMMON_DIR)/kernel/patches
COMMON_KERNEL_FILES_DIR := $(COMMON_DIR)/kernel/files
COMMON_UBOOT_PATCH_DIR := $(COMMON_DIR)/uboot/patches

OUTPUT_DIR := $(SDK_ROOT)/output
DOWNLOAD_DIR := $(OUTPUT_DIR)/downloads
CACHE_DIR := $(OUTPUT_DIR)/cache
FIRMWARE_DIR := $(OUTPUT_DIR)/firmware
ROOTFS_DIR := $(OUTPUT_DIR)/rootfs
ROOTFS_ROOT := $(ROOTFS_DIR)/root
ROOTFS_IMAGE := $(ROOTFS_DIR)/rootfs.ext4
MODULES_DIR := $(OUTPUT_DIR)/kernel-modules
BOOT_IMAGE := $(OUTPUT_DIR)/images/boot.img
DATA_IMAGE := $(OUTPUT_DIR)/images/data.img

KERNEL_DIR := $(SDK_ROOT)/kernel
UBOOT_SRC := $(OUTPUT_DIR)/uboot-src
UBOOT_BUILD := $(OUTPUT_DIR)/uboot-build

BOARD_DIR := $(SDK_ROOT)/boards/$(BOARD)
BOARD_OVERLAY_DIR := $(BOARD_DIR)/overlays/rootfs
BOARD_PACKAGES_DIR := $(BOARD_DIR)/packages
BOARD_LOCAL_PACKAGE_DIR := $(BOARD_PACKAGES_DIR)/local
BOARD_DEB_DIR := $(BOARD_PACKAGES_DIR)/debs
BOARD_EXTRA_DEB_MANIFEST := $(BOARD_PACKAGES_DIR)/third-party-debs.txt
BOARD_KERNEL_DIR := $(BOARD_DIR)/kernel
BOARD_KERNEL_PATCH_DIR := $(BOARD_KERNEL_DIR)/patches
BOARD_KERNEL_FILES_DIR := $(BOARD_KERNEL_DIR)/files
BOARD_UBOOT_DIR := $(BOARD_DIR)/uboot
BOARD_UBOOT_PATCH_DIR := $(BOARD_UBOOT_DIR)/patches
BOARD_FIRMWARE_DIR := $(BOARD_DIR)/firmware
LEGAL_DIR := $(SDK_ROOT)/legal

JOBS ?= $(shell nproc)
CROSS_COMPILE ?= $(BOARD_CROSS_COMPILE)

export SDK_ROOT BUILD_DIR SCRIPTS_DIR COMMON_DIR COMMON_OVERLAY_DIR
export COMMON_LOCAL_PACKAGE_DIR COMMON_DEB_DIR
export COMMON_EXTRA_DEB_MANIFEST
export COMMON_KERNEL_PATCH_DIR COMMON_KERNEL_FILES_DIR COMMON_UBOOT_PATCH_DIR
export OUTPUT_DIR DOWNLOAD_DIR CACHE_DIR
export FIRMWARE_DIR ROOTFS_DIR ROOTFS_ROOT ROOTFS_IMAGE
export MODULES_DIR BOOT_IMAGE DATA_IMAGE KERNEL_DIR UBOOT_SRC UBOOT_BUILD
export BOARD BOARD_DIR BOARD_OVERLAY_DIR
export BOARD_LOCAL_PACKAGE_DIR BOARD_DEB_DIR BOARD_EXTRA_DEB_MANIFEST
export BOARD_KERNEL_DIR BOARD_KERNEL_PATCH_DIR BOARD_KERNEL_FILES_DIR
export BOARD_UBOOT_DIR BOARD_UBOOT_PATCH_DIR
export BOARD_FIRMWARE_DIR BOARD_VENDOR BOARD_NAME BOARD_CHIP
export LEGAL_DIR
export BOARD_ARCH CROSS_COMPILE JOBS
export KERNEL_VERSION KERNEL_TARBALL KERNEL_URL KERNEL_SHA256
export KERNEL_DEFCONFIG KERNEL_DTS KERNEL_IMAGE KERNEL_DTB
export UBOOT_VERSION UBOOT_TARBALL UBOOT_URL UBOOT_SHA256
export UBOOT_DEFCONFIG UBOOT_BL31 UBOOT_TPL MINILOADER
export UBUNTU_VERSION UBUNTU_SUITE UBUNTU_ARCH UBUNTU_MIRROR
export UBUNTU_BASE_URL UBUNTU_BASE_SHA256 UBUNTU_ROOT_PASSWORD
export UBUNTU_PACKAGES
export ROOTFS_IMAGE_HEADROOM ROOTFS_IMAGE_MIN_SIZE
export ROOTFS_LABEL ROOTFS_HOSTNAME ROOTFS_LOCALE
export ROOTFS_UBUNTU_USER ROOTFS_UBUNTU_PASSWORD
export ROOTFS_ENABLE_UNITS
export ROOTFS_MASK_UNITS
export USB_VID USB_PID USB_FW_VERSION USB_MANUFACTURER USB_PRODUCT
export USB_GADGET_FUNCS
export PARAMETER_FILE PACKAGE_FILE BOOT_ESP_SIZE
export BOOT_ESP_GRUB_DEB_URL BOOT_ESP_GRUB_DEB_SHA256 DATA_IMAGE_SIZE

.PHONY: all help check-tools clean distclean

help:
	@printf '%s\n' \
		'Ampheck Eidos Alpha' \
		'' \
		'  make kernel          Fetch, configure and build Linux + DTB' \
		'  make modules         Build and install kernel modules' \
		'  make uboot           Fetch and build mainline U-Boot' \
		'  make external-debs   Install external prebuilt debs into rootfs' \
		'  make rootfs          Build rootfs using valid caches' \
		'  make rootfs-clean    Remove rootfs and package-layer cache' \
		'  make image           Build image using valid caches' \
		'  make flash           Flash update.img with ARKT' \
		'  make clean           Remove the output directory' \
		'  make distclean       Remove output and clean the kernel build tree'

check-tools:
	@for tool in curl tar sha256sum make patch rsync mke2fs e2fsck; do \
		command -v $$tool >/dev/null || { echo "missing tool: $$tool" >&2; exit 1; }; \
	done
	@command -v "$(CROSS_COMPILE)gcc" >/dev/null || { \
		echo "missing cross compiler: $(CROSS_COMPILE)gcc" >&2; exit 1; }

clean:
	@$(SUDO) rm -rf "$(OUTPUT_DIR)"

distclean: clean
	@if test -f "$(KERNEL_DIR)/Makefile"; then \
		$(MAKE) -C "$(KERNEL_DIR)" ARCH=$(BOARD_ARCH) CROSS_COMPILE=$(CROSS_COMPILE) distclean; \
	fi
