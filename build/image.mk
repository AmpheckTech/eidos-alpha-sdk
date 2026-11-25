.PHONY: boot-image data-image update-image image

boot-image:
	@"$(SCRIPTS_DIR)/build-esp.sh"

data-image:
	@"$(SCRIPTS_DIR)/pack-data.sh" "$(DATA_IMAGE)"

update-image:
	@"$(SCRIPTS_DIR)/pack-update.sh"

image: uboot rootfs boot-image data-image update-image
