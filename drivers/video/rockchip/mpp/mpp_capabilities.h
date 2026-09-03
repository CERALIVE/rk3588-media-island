/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef CERALIVE_MPP_CAPABILITIES_H
#define CERALIVE_MPP_CAPABILITIES_H

static inline unsigned long
mpp_visible_device_mask(unsigned long compiled_mask, unsigned long probed_mask)
{
	return compiled_mask & probed_mask;
}

#endif
