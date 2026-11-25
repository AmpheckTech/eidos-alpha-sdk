# Ampheck Eidos Alpha SDK

BOARD ?= ampheck/eidos-alpha

.NOTPARALLEL:

include boards/$(BOARD)/board.mk
include build/common.mk
include build/kernel.mk
include build/rkbin.mk
include build/uboot.mk
include build/external-debs.mk
include build/rootfs.mk
include build/image.mk
include build/flash.mk

.PHONY: all

all: image
