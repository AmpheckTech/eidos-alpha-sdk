// SPDX-License-Identifier: GPL-2.0
/*
 * Minimal HDMI-RX class shim for the out-of-tree RK628 CSI module.
 *
 * Rockchip's vendor kernel exposes this class from a separate hdmirx driver.
 * Mainline Linux has no such driver or exported symbol, so keep the class
 * private to rk628-csi.ko.
 */

#include <linux/device.h>
#include <linux/err.h>
#include <linux/module.h>
#include <linux/rk_hdmirx_class.h>

static struct class *rk628_hdmirx_class;

struct class *rk_hdmirx_class(void)
{
	return rk628_hdmirx_class;
}
EXPORT_SYMBOL_GPL(rk_hdmirx_class);

int rk628_hdmirx_class_init(void)
{
	rk628_hdmirx_class = class_create("hdmirx");
	if (IS_ERR(rk628_hdmirx_class)) {
		struct class *err = rk628_hdmirx_class;

		rk628_hdmirx_class = NULL;
		return PTR_ERR(err);
	}

	return 0;
}

void rk628_hdmirx_class_exit(void)
{
	class_destroy(rk628_hdmirx_class);
	rk628_hdmirx_class = NULL;
}
