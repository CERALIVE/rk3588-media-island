/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef ROCKCHIP_MEDIA_RECOVERY_H
#define ROCKCHIP_MEDIA_RECOVERY_H

#include <linux/atomic.h>
#include <linux/delay.h>
#include <linux/device.h>
#include <linux/of.h>
#include <linux/reset.h>
#include <linux/slab.h>

struct media_recovery {
	atomic64_t recovery_epoch;
	atomic64_t claimed_epoch;
};

static inline void media_recovery_init(struct media_recovery *r)
{
	atomic64_set(&r->recovery_epoch, 1);
	atomic64_set(&r->claimed_epoch, 0);
}

static inline void media_recovery_started(struct media_recovery *r)
{
	atomic64_inc(&r->recovery_epoch);
}

static inline bool media_recovery_claim(struct media_recovery *r, s64 epoch)
{
	s64 old = atomic64_read(&r->claimed_epoch);

	while (old < epoch) {
		if (atomic64_try_cmpxchg(&r->claimed_epoch, &old, epoch))
			return true;
	}
	return false;
}

struct media_resets {
	struct reset_control_bulk_data *controls;
	int count;
};

static inline int media_resets_get(struct device *dev, struct media_resets *resets)
{
	int count, i, ret;
	const char *name;

	if (!of_find_property(dev->of_node, "reset-names", NULL))
		return 0;
	count = of_property_count_strings(dev->of_node, "reset-names");
	if (count < 0)
		return dev_err_probe(dev, count, "reset-names\n");
	resets->controls = devm_kcalloc(dev, count, sizeof(*resets->controls), GFP_KERNEL);
	if (!resets->controls)
		return -ENOMEM;
	for (i = 0; i < count; i++) {
		ret = of_property_read_string_index(dev->of_node, "reset-names", i, &name);
		if (ret)
			return dev_err_probe(dev, ret, "reset-names[%d]\n", i);
		/* Shared MPP reset-group ownership remains with the group, not each core. */
		if (!strncmp(name, "shared_", 7))
			continue;
		resets->controls[resets->count++].id = name;
	}
	ret = devm_reset_control_bulk_get_optional_exclusive(dev, resets->count,
							  resets->controls);
	if (ret)
		return dev_err_probe(dev, ret, "reset controls from reset-names\n");
	return 0;
}

static inline int media_reset_cycle(int count,
				    struct reset_control_bulk_data *assert_order,
				    struct reset_control_bulk_data *deassert_order)
{
	int ret = reset_control_bulk_assert(count, assert_order);

	if (ret)
		return ret;
	udelay(5);
	return reset_control_bulk_deassert(count, deassert_order);
}

#endif
