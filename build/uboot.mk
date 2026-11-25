.PHONY: prepare-uboot uboot uboot-menuconfig uboot-clean

UBOOT_MAKE := $(MAKE) -C "$(UBOOT_SRC)" O="$(UBOOT_BUILD)" \
	CROSS_COMPILE="$(CROSS_COMPILE)"

prepare-uboot: check-tools
	@"$(SCRIPTS_DIR)/fetch-uboot.sh"

uboot: prepare-rkbin prepare-uboot
	@mkdir -p "$(UBOOT_BUILD)" "$(FIRMWARE_DIR)"
	@test -r "$(UBOOT_BL31)"
	@test -r "$(UBOOT_TPL)"
	@$(UBOOT_MAKE) "$(UBOOT_DEFCONFIG)"
	@$(UBOOT_MAKE) -j"$(JOBS)" \
		BL31="$(UBOOT_BL31)" \
		ROCKCHIP_TPL="$(UBOOT_TPL)"
	@test -r "$(UBOOT_BUILD)/u-boot.itb"
	@test -r "$(UBOOT_BUILD)/idbloader.img"
	@ln -sfn "$(UBOOT_BUILD)/u-boot.itb" "$(FIRMWARE_DIR)/uboot.img"
	@ln -sfn "$(UBOOT_BUILD)/u-boot-rockchip.bin" "$(FIRMWARE_DIR)/u-boot-rockchip.bin"

uboot-menuconfig: prepare-uboot
	@mkdir -p "$(UBOOT_BUILD)"
	@$(UBOOT_MAKE) "$(UBOOT_DEFCONFIG)"
	@$(UBOOT_MAKE) menuconfig
	@$(UBOOT_MAKE) savedefconfig
	@install -m 0644 "$(UBOOT_BUILD)/defconfig" \
		"$(BOARD_UBOOT_DIR)/configs/$(UBOOT_DEFCONFIG)"

uboot-clean:
	@rm -rf "$(UBOOT_BUILD)"
