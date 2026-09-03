// SPDX-License-Identifier: GPL-2.0
#include <linux/sizes.h>
#include <kunit/test.h>

#include "../mpp/mpp_dma_policy.h"
#include "../rga3/include/rga_dma_policy.h"

static void mpp_dma_capability_is_32_bit_per_block_test(struct kunit *test)
{
	struct mpp_dma_capability caps = mpp_dma_capability_island();

	KUNIT_EXPECT_EQ(test, caps.streaming_bits, (u8)32);
	KUNIT_EXPECT_EQ(test, caps.coherent_bits, (u8)32);
}

static void mpp_dma_segment_limit_honours_device_maximum_test(struct kunit *test)
{
	KUNIT_EXPECT_EQ(test, mpp_dma_segment_limit(SZ_1G), (unsigned int)SZ_1G);
	KUNIT_EXPECT_EQ(test, mpp_dma_segment_limit(0), U32_MAX);
}

static void rga_staging_segment_limit_honours_device_maximum_test(struct kunit *test)
{
	KUNIT_EXPECT_EQ(test, rga_staging_segment_limit(SZ_1G),
			(unsigned int)SZ_1G);
	KUNIT_EXPECT_EQ(test, rga_staging_segment_limit(0), UINT_MAX);
}

static void rga_dma_capabilities_preserve_command_buffer_width_test(struct kunit *test)
{
	struct rga_dma_capability rga3 = rga3_dma_capability();
	struct rga_dma_capability rga2 = rga2_dma_capability();

	KUNIT_EXPECT_EQ(test, rga3.streaming_bits, (u8)40);
	KUNIT_EXPECT_EQ(test, rga3.coherent_bits, (u8)32);
	KUNIT_EXPECT_EQ(test, rga2.streaming_bits, (u8)32);
	KUNIT_EXPECT_EQ(test, rga2.coherent_bits, (u8)32);
}

static struct kunit_case media_dma_policy_cases[] = {
	KUNIT_CASE(mpp_dma_capability_is_32_bit_per_block_test),
	KUNIT_CASE(mpp_dma_segment_limit_honours_device_maximum_test),
	KUNIT_CASE(rga_staging_segment_limit_honours_device_maximum_test),
	KUNIT_CASE(rga_dma_capabilities_preserve_command_buffer_width_test),
	{}
};

static struct kunit_suite media_dma_policy_suite = {
	.name = "rockchip-media-dma-policy",
	.test_cases = media_dma_policy_cases,
};

kunit_test_suite(media_dma_policy_suite);

MODULE_LICENSE("GPL");
