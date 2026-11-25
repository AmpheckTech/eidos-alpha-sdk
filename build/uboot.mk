.PHONY: prepare-uboot uboot uboot-menuconfig uboot-clean

UBOOT_MAKE := $(MAKE) -C "$(UBOOT_SRC)" O="$(UBOOT_BUILD)" \
	CROSS_COMPILE="$(CROSS_COMPILE)"
UBOOT_BUILD_STAMP := $(UBOOT_BUILD)/.eidos-uboot-build.sha256

prepare-uboot: check-tools
	@"$(SCRIPTS_DIR)/fetch-uboot.sh"

uboot: prepare-rkbin prepare-uboot
	@mkdir -p "$(UBOOT_BUILD)" "$(FIRMWARE_DIR)"
	@test -r "$(UBOOT_BL31)"
	@test -r "$(UBOOT_TPL)"
	@set -e; \
	input_hash="$$({ \
		printf '%s\n' "format=1" \
			"UBOOT_VERSION=$(UBOOT_VERSION)" \
			"UBOOT_DEFCONFIG=$(UBOOT_DEFCONFIG)" \
			"CROSS_COMPILE=$(CROSS_COMPILE)"; \
		cat "$(UBOOT_SRC)/.eidos-uboot-input.sha256"; \
		sha256sum "$(UBOOT_BL31)" "$(UBOOT_TPL)" \
			"$(SCRIPT_DIR)/fetch-uboot.sh" "$(BUILD_DIR)/uboot.mk"; \
	} | sha256sum | cut -d' ' -f1)"; \
	if [ "$${FORCE:-0}" != 1 ] && \
		[ -s "$(UBOOT_BUILD_STAMP)" ] && \
		[ "$$(cat "$(UBOOT_BUILD_STAMP)")" = "$$input_hash" ] && \
		[ -r "$(UBOOT_BUILD)/u-boot.itb" ] && \
		[ -r "$(UBOOT_BUILD)/idbloader.img" ]; then \
		echo "U-Boot is up to date"; \
	else \
		echo "Building U-Boot"; \
		$(UBOOT_MAKE) "$(UBOOT_DEFCONFIG)"; \
		$(UBOOT_MAKE) -j"$(JOBS)" \
			BL31="$(UBOOT_BL31)" \
			ROCKCHIP_TPL="$(UBOOT_TPL)"; \
		printf '%s\n' "$$input_hash" > "$(UBOOT_BUILD_STAMP)"; \
	fi
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
