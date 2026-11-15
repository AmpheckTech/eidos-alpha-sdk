# SPDX-License-Identifier: GPL-2.0
#
# Rockchip RK628 HDMI-RX -> MIPI CSI-2 bridge

obj-$(CONFIG_VIDEO_RK628) += video-rk628.o
video-rk628-y := \
	rk628.o \
	rk628_cru.o \
	rk628_hdmirx.o \
	rk628_dsi.o \
	rk628_combrxphy.o \
	rk628_combtxphy.o \
	rk628_mipi_dphy.o \
	rk628_post_process.o \
	rk628_csi_v4l2.o \
	rk628_hdmirx_class.o

ccflags-y += -I$(srctree)/$(src)/include
ccflags-y += -I$(srctree)/$(src)

# The vendor-only RKCIF hooks are not available in the mainline CIF driver.
ccflags-y += -UCONFIG_VIDEO_ROCKCHIP_CIF
# Mainline has no Rockchip vendor-storage API; use the private header fallback.
ccflags-y += -UCONFIG_ROCKCHIP_VENDOR_STORAGE
