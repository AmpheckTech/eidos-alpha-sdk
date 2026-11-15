.PHONY: rootfs rootfs-clean rootfs-bootstrap \
	rootfs-configure rootfs-image

rootfs-bootstrap: check-tools
	@"$(SCRIPTS_DIR)/bootstrap-rootfs.sh"

rootfs-configure: external-debs
	@"$(SCRIPTS_DIR)/configure-rootfs.sh" "$(ROOTFS_ROOT)"

rootfs-image: rootfs-configure
	@"$(SCRIPTS_DIR)/pack-rootfs.sh" "$(ROOTFS_ROOT)" "$(ROOTFS_IMAGE)"

rootfs: modules rootfs-image

rootfs-clean:
	@rm -rf "$(ROOTFS_DIR)" "$(OUTPUT_DIR)/ubuntu"
	@find "$(CACHE_DIR)" -maxdepth 1 -type f \
		-name 'ubuntu-package-layer-*.tar.zst' -delete
