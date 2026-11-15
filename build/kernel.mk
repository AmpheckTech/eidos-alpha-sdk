.PHONY: prepare-kernel kernel modules kernel-menuconfig kernel-clean

KMAKE := $(MAKE) -C "$(KERNEL_DIR)" \
	ARCH="$(BOARD_ARCH)" CROSS_COMPILE="$(CROSS_COMPILE)"

prepare-kernel: check-tools
	@"$(SCRIPTS_DIR)/fetch-linux.sh"

kernel: prepare-kernel
	@$(KMAKE) "$(KERNEL_DEFCONFIG)"
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
