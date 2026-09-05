/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef ROCKCHIP_MEDIA_REQUEST_SIZE_H
#define ROCKCHIP_MEDIA_REQUEST_SIZE_H

#include <linux/errno.h>
#include <linux/overflow.h>

static inline int media_request_size(size_t count, size_t element, size_t *bytes)
{
	if (check_mul_overflow(count, element, bytes)) {
		*bytes = 0;
		return -EINVAL;
	}
	return 0;
}

#endif
