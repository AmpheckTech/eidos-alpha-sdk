# Ampheck Eidos Alpha SDK

Board support and image build for the Ampheck Eidos Alpha, using mainline Linux
7.3.4, U-Boot 2026.10, and an Ubuntu Base 24.04 root filesystem.

## Build

```shell
make image
```

Common targets:

```shell
make help
make kernel
make modules
make uboot
make rootfs
make rootfs-clean
make image
make flash
```

Image packing requires `arkt` in `PATH`; override it with
`ARKT=/path/to/arkt` if needed.

Default login:

```text
ubuntu / eidos
```

Override the password when building:

```shell
ROOTFS_UBUNTU_PASSWORD='choose-a-strong-password' make image
```

Root password login is disabled by default.

Flash the complete update image:

```shell
make flash
arkt flash output/firmware/update.img
```

## Layout

- `boards/ampheck/eidos-alpha/` contains the complete product integration:
  `board.mk`, board kernel config/DTS, board U-Boot config/DTS, firmware
  metadata, board packages, and the board rootfs overlay.
- `common/` contains shared kernel/U-Boot patches and source files, plus
  product-neutral rootfs overlays and packages.
- `build/` contains the Make fragments and build scripts.
- `legal/` contains source provenance, package copyright, and license texts
  included in generated images and release legal bundles.
- `output/` contains downloaded sources, caches, build products, and firmware.

The Ubuntu package layer is cached under `output/cache/`. `make image` reuses
valid caches. To rebuild the rootfs and package layer from scratch, run
`make rootfs-clean` first.

## Licensing

Ampheck integration code is Apache-2.0; see [`LICENSE`](LICENSE). Kernel,
U-Boot, Rockchip boot firmware, Debian adbd payloads, and Ubuntu packages keep
their own licenses. See [`NOTICE`](NOTICE) for details.

Vendor userspace runtimes such as RKNN, Rockchip MPP/RGA, and Rockchip
GStreamer plugins are not redistributed by this SDK. Applications that require
them must obtain them from the applicable vendor and comply with the vendor's
terms. AP6256 Wi-Fi firmware is a required board-level component for Eidos
Alpha. The BCM43456 `.bin` firmware is distributed complete and unmodified
under the Broadcom BCM43xx Software License Agreement; board NVRAM data is
subject to the AP6256 module supplier's terms. See [`NOTICE`](NOTICE) and
[`legal/LICENCE.broadcom_bcm43xx`](legal/LICENCE.broadcom_bcm43xx).

## Disclaimer

This SDK and generated images are provided "AS IS", without warranties to the
maximum extent permitted by law. Building, flashing, and hardware operation are
at your own risk. Third-party components keep their own licenses; compliance is
the user's responsibility. Nothing here is legal advice.
