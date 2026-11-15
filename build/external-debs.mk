.PHONY: external-debs

external-debs: rootfs-bootstrap
	@"$(SCRIPTS_DIR)/install-external-debs.sh"
