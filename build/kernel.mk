.PHONY: prepare-kernel kernel modules kernel-menuconfig kernel-clean

CCACHE ?= $(shell command -v ccache 2>/dev/null)
ifneq ($(CCACHE),)
KERNEL_CC := $(CCACHE) $(CROSS_COMPILE)gcc
KERNEL_HOSTCC := $(CCACHE) gcc
else
KERNEL_CC := $(CROSS_COMPILE)gcc
KERNEL_HOSTCC := gcc
endif

KMAKE := $(MAKE) -C "$(KERNEL_DIR)" \
	ARCH="$(BOARD_ARCH)" CROSS_COMPILE="$(CROSS_COMPILE)" LOCALVERSION= \
	CC="$(KERNEL_CC)" HOSTCC="$(KERNEL_HOSTCC)"
BOARD_DEFCONFIG := $(BOARD_KERNEL_DIR)/$(KERNEL_DEFCONFIG)
KERNEL_DEFCONFIG_PATH ?= $(if $(wildcard $(BOARD_DEFCONFIG)),$(BOARD_DEFCONFIG),$(KERNEL_DIR)/arch/$(BOARD_ARCH)/configs/$(KERNEL_DEFCONFIG))
DEFCONFIG_STAMP := $(KERNEL_DIR)/.eidos-defconfig.applied.sha256

prepare-kernel: check-tools
	@"$(SCRIPTS_DIR)/fetch-linux.sh"

kernel: prepare-kernel
	@defconfig_hash="$$(sha256sum "$(KERNEL_DEFCONFIG_PATH)" | cut -d' ' -f1)"; \
	if [ ! -f "$(KERNEL_DIR)/.config" ] || \
		[ ! -f "$(DEFCONFIG_STAMP)" ] || \
		[ "$$(cat "$(DEFCONFIG_STAMP)")" != "$$defconfig_hash" ]; then \
		echo "Applying $(KERNEL_DEFCONFIG)"; \
		$(KMAKE) "$(KERNEL_DEFCONFIG)"; \
		printf '%s\n' "$$defconfig_hash" > "$(DEFCONFIG_STAMP)"; \
	else \
		echo "Kernel .config is already up to date"; \
	fi
	@$(KMAKE) -j"$(JOBS)" Image "rockchip/$(KERNEL_DTS).dtb"
	@ln -rsf "$(KERNEL_DIR)/arch/$(BOARD_ARCH)/boot/dts/rockchip/$(KERNEL_DTS).dtb" \
		"$(SDK_ROOT)/$(KERNEL_DTB)"

modules: kernel
	@$(KMAKE) -j"$(JOBS)" modules
	@rm -rf "$(MODULES_DIR)/lib/modules/$(KERNEL_VERSION)"
	@$(KMAKE) modules_install INSTALL_MOD_PATH="$(MODULES_DIR)"
	@find "$(MODULES_DIR)/lib/modules" -type l -delete

kernel-menuconfig: prepare-kernel
	@$(KMAKE) "$(KERNEL_DEFCONFIG)"
	@$(KMAKE) menuconfig
	@$(KMAKE) savedefconfig
	@install -m 0644 "$(KERNEL_DIR)/defconfig" \
		"$(BOARD_KERNEL_DIR)/$(KERNEL_DEFCONFIG)"

kernel-clean:
	@if test -f "$(KERNEL_DIR)/Makefile"; then $(KMAKE) clean; fi
