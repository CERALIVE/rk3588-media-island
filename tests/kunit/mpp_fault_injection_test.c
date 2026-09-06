// SPDX-License-Identifier: GPL-2.0
#include <kunit/test.h>
#include <kunit/device.h>
#include <linux/sysfs.h>
#include "../mpp/mpp_rkvenc_test.h"
#include "../mpp/media_fault.h"
#include "../mpp/media_dump.h"
#include "../mpp/media_probe.h"
#include "../../../base/base.h"

static void mpp_fault_flag_is_one_shot_test(struct kunit *test)
{
	struct mpp_fault_knob knob = {
		.armed = ATOMIC_INIT(1),
		.consumed = ATOMIC_INIT(0),
	};

	KUNIT_EXPECT_TRUE(test, mpp_fault_consume_flag(&knob));
	KUNIT_EXPECT_FALSE(test, mpp_fault_consume_flag(&knob));
	KUNIT_EXPECT_EQ(test, atomic_read(&knob.armed), 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&knob.consumed), 1);
}

static void mpp_fault_delay_is_one_shot_test(struct kunit *test)
{
	struct mpp_fault_knob knob = {
		.armed = ATOMIC_INIT(25),
		.consumed = ATOMIC_INIT(0),
	};

	KUNIT_EXPECT_EQ(test, mpp_fault_consume_delay(&knob), 25u);
	KUNIT_EXPECT_EQ(test, mpp_fault_consume_delay(&knob), 0u);
	KUNIT_EXPECT_EQ(test, atomic_read(&knob.consumed), 1);
	atomic_set(&knob.armed, -1);
	KUNIT_EXPECT_EQ(test, mpp_fault_consume_delay(&knob), 0u);
	KUNIT_EXPECT_EQ(test, atomic_read(&knob.consumed), 1);
}

static void media_fault_storm_test(struct kunit *test)
{
	struct ratelimit_state state;
	struct device dev = { .init_name = "media-fault-kunit" };
	unsigned int emitted = 0;
	int i;

	media_fault_init(&state);
	for (i = 0; i < 1000; i++)
		emitted += media_fault_report(&dev, &state, "injected fault %d\n", i);
	KUNIT_EXPECT_EQ(test, emitted, 10u);
}

static void media_dump_submission_owns_buffer_test(struct kunit *test)
{
	struct device *dev = kunit_device_register(test, "media-dump-kunit");
	struct media_dump_record record = { .task = 42, .core = 2 };
	struct kernfs_node *link;
	void *owned;
	size_t len;

	KUNIT_ASSERT_NOT_ERR_OR_NULL(test, dev);
	owned = vzalloc(MEDIA_DUMP_BYTES);
	KUNIT_ASSERT_NOT_NULL(test, owned);
	len = media_dump_format(owned, &record);
	KUNIT_EXPECT_LT(test, len, (size_t)MEDIA_DUMP_BYTES);
	KUNIT_EXPECT_NOT_NULL(test, strstr(owned, "task=42 core=2"));
	media_dump_submit(dev, &owned, len);
	KUNIT_EXPECT_PTR_EQ(test, owned, NULL);
	link = sysfs_get_dirent(dev->kobj.sd, "devcoredump");
	KUNIT_EXPECT_NOT_NULL(test, link);
	if (link)
		sysfs_put(link);
	dev_coredump_put(dev);
}

static void media_probe_names_deferred_resource_test(struct kunit *test)
{
	struct device *dev = kunit_device_register(test, "media-probe-kunit");

	KUNIT_ASSERT_NOT_ERR_OR_NULL(test, dev);
	KUNIT_EXPECT_EQ(test, media_probe_error(dev, -EPROBE_DEFER, "iommus provider"),
			-EPROBE_DEFER);
	KUNIT_ASSERT_NOT_NULL(test, dev->p->deferred_probe_reason);
	KUNIT_EXPECT_NOT_NULL(test, strstr(dev->p->deferred_probe_reason, "iommus provider"));
	KUNIT_EXPECT_EQ(test, media_probe_error(dev, -EPROBE_DEFER, "aclk_vcodec"),
			-EPROBE_DEFER);
	KUNIT_EXPECT_NOT_NULL(test, strstr(dev->p->deferred_probe_reason, "aclk_vcodec"));
}

static struct kunit_case mpp_fault_injection_cases[] = {
	KUNIT_CASE(media_probe_names_deferred_resource_test),
	KUNIT_CASE(media_dump_submission_owns_buffer_test),
	KUNIT_CASE(media_fault_storm_test),
	KUNIT_CASE(mpp_fault_flag_is_one_shot_test),
	KUNIT_CASE(mpp_fault_delay_is_one_shot_test),
	{}
};

static struct kunit_suite mpp_fault_injection_suite = {
	.name = "rockchip-mpp-fault-injection",
	.test_cases = mpp_fault_injection_cases,
};

kunit_test_suite(mpp_fault_injection_suite);

MODULE_LICENSE("GPL");
