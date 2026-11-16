# SPDX-License-Identifier: (GPL-2.0+ OR MIT)

ccflags-y += -DMPP_VERSION=\"rockchip-mpp-77168c8\"

rk_vcodec-objs := mpp_service.o mpp_common.o mpp_iommu.o
rk_vcodec-$(CONFIG_ROCKCHIP_MPP_RKVDEC2) += mpp_rkvdec2.o mpp_rkvdec2_link.o
rk_vcodec-$(CONFIG_ROCKCHIP_MPP_RKVENC) += mpp_rkvenc.o

obj-$(CONFIG_ROCKCHIP_MPP_SERVICE) += rk_vcodec.o
