.PHONY: rootfs rootfs-clean rootfs-cache-clean rootfs-apt-cache-clean \
	rootfs-bootstrap rootfs-configure rootfs-image

rootfs-bootstrap: check-tools
	@"$(SCRIPTS_DIR)/bootstrap-rootfs.sh"

rootfs-configure: rootfs-bootstrap
	@"$(SCRIPTS_DIR)/configure-rootfs.sh" "$(ROOTFS_ROOT)"

rootfs-image: rootfs-configure
	@"$(SCRIPTS_DIR)/pack-rootfs.sh" "$(ROOTFS_ROOT)" "$(ROOTFS_IMAGE)"

rootfs: modules rootfs-image

rootfs-clean:
	@$(SUDO) rm -rf "$(ROOTFS_DIR)" "$(OUTPUT_DIR)/ubuntu"

rootfs-cache-clean:
	@$(SUDO) rm -rf "$(CACHE_DIR)/rootfs-base"
	@$(SUDO) find "$(CACHE_DIR)" -maxdepth 1 -type f \
		-name 'ubuntu-package-layer-*.tar.zst' -delete

rootfs-apt-cache-clean:
	@$(SUDO) rm -rf "$(CACHE_DIR)/apt-archives" "$(CACHE_DIR)/apt-lists"
