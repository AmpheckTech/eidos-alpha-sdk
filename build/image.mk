.PHONY: loader boot-image data-image update-image image

loader: prepare-rkbin
	@"$(SCRIPTS_DIR)/pack-loader.sh"

boot-image:
	@"$(SCRIPTS_DIR)/build-esp.sh"

data-image:
	@"$(SCRIPTS_DIR)/pack-data.sh" "$(DATA_IMAGE)"

update-image: loader
	@"$(SCRIPTS_DIR)/pack-update.sh"

image: uboot rootfs boot-image data-image update-image
