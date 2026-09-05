/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef ROCKCHIP_MEDIA_PROBE_H
#define ROCKCHIP_MEDIA_PROBE_H

#include <linux/device.h>

static inline int media_probe_error(struct device *dev, int error, const char *resource)
{
	return dev_err_probe(dev, error, "failed to acquire %s\n", resource);
}

#endif
