// SPDX-License-Identifier: GPL-2.0
#include <linux/bitops.h>
#include <kunit/test.h>

#include "../mpp/mpp_capabilities.h"

#define MPP_TEST_RKVDEC2_BIT 9
#define MPP_TEST_JPGDEC_BIT 13
#define MPP_TEST_RKVENC2_BIT 16
#define MPP_TEST_AV1_BIT 4
#define MPP_TEST_VEPU1_BIT 17
#define MPP_TEST_IEP2_BIT 28
#define MPP_TEST_VDPP_BIT 29

static unsigned long mpp_island_compiled_mask(void)
{
	return BIT(MPP_TEST_RKVDEC2_BIT) | BIT(MPP_TEST_JPGDEC_BIT) |
	       BIT(MPP_TEST_RKVENC2_BIT);
}

static void mpp_capabilities_exclude_uncompiled_clients_test(struct kunit *test)
{
	unsigned long probed = mpp_island_compiled_mask() |
		BIT(MPP_TEST_AV1_BIT) | BIT(MPP_TEST_VEPU1_BIT) |
		BIT(MPP_TEST_IEP2_BIT) | BIT(MPP_TEST_VDPP_BIT);

	KUNIT_EXPECT_EQ(test,
		mpp_visible_device_mask(mpp_island_compiled_mask(), probed),
		mpp_island_compiled_mask());
}

static void mpp_capabilities_exclude_unprobed_clients_test(struct kunit *test)
{
	unsigned long probed = BIT(MPP_TEST_RKVENC2_BIT) |
		BIT(MPP_TEST_JPGDEC_BIT);

	KUNIT_EXPECT_EQ(test,
		mpp_visible_device_mask(mpp_island_compiled_mask(), probed), probed);
}

static struct kunit_case mpp_capabilities_cases[] = {
	KUNIT_CASE(mpp_capabilities_exclude_uncompiled_clients_test),
	KUNIT_CASE(mpp_capabilities_exclude_unprobed_clients_test),
	{}
};

static struct kunit_suite mpp_capabilities_suite = {
	.name = "rockchip-mpp-capabilities",
	.test_cases = mpp_capabilities_cases,
};

kunit_test_suite(mpp_capabilities_suite);

MODULE_LICENSE("GPL");
