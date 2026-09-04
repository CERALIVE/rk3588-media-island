// SPDX-License-Identifier: GPL-2.0
#include <kunit/test.h>
#include <linux/string.h>

#include "../rga3/include/rga_request_validation.h"

static const struct rga_plane_request valid_plane = {
	.active_width = 128,
	.active_height = 64,
	.width_stride = 128,
	.height_stride = 64,
	.format = RGA_REQUEST_FORMAT_NV12,
	.plane_count = 2,
	.byte_stride = 128,
	.byte_stride_align = 4,
	.max_byte_stride = 32768,
	.format_supported = true,
	.planes = {
		{ .descriptor = 7, .size = 12288, .required = 8192 },
		{ .descriptor = 7, .offset = 8192, .size = 12288, .required = 4096 },
	},
};

static void rga_plane_rejects_missing_descriptor_test(struct kunit *test)
{
	struct rga_plane_request plane = valid_plane;

	plane.planes[0].descriptor = 0;
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), -EINVAL);
}

static void rga_plane_rejects_horizontal_offset_outside_stride_test(struct kunit *test)
{
	struct rga_plane_request plane = valid_plane;

	plane.x_offset = 1;
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), -EINVAL);
}

static void rga_plane_rejects_vertical_offset_outside_stride_test(struct kunit *test)
{
	struct rga_plane_request plane = valid_plane;

	plane.y_offset = 1;
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), -EINVAL);
}

static void rga_plane_rejects_zero_width_test(struct kunit *test)
{
	struct rga_plane_request plane = valid_plane;

	plane.active_width = 0;
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), -EINVAL);
}

static void rga_plane_rejects_unsupported_scheduler_format_test(struct kunit *test)
{
	struct rga_plane_request plane = valid_plane;

	plane.format_supported = false;
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), -EINVAL);
}

static void rga_plane_rejects_unknown_format_test(struct kunit *test)
{
	struct rga_plane_request plane = valid_plane;

	plane.format = RGA_REQUEST_FORMAT_UNKNOWN;
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), -EINVAL);

}

static void rga_plane_rejects_unaligned_byte_stride_test(struct kunit *test)
{
	struct rga_plane_request plane = valid_plane;

	plane.byte_stride = 130;
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), -EINVAL);
}

static void rga_plane_rejects_oversized_byte_stride_test(struct kunit *test)
{
	struct rga_plane_request plane = valid_plane;

	plane.byte_stride = 32772;
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), -EINVAL);
}

static void rga_plane_rejects_missing_uv_plane_test(struct kunit *test)
{
	struct rga_plane_request plane = valid_plane;

	plane.planes[1].descriptor = 0;
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), -EINVAL);
}

static void rga_plane_rejects_unexpected_third_plane_test(struct kunit *test)
{
	struct rga_plane_request plane = valid_plane;

	plane.planes[2].descriptor = 7;
	plane.planes[2].size = 12288;
	plane.planes[2].required = 1;
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), -EINVAL);
}

static void rga_plane_rejects_plane_offset_overflow_test(struct kunit *test)
{
	struct rga_plane_request plane = valid_plane;

	plane.planes[1].offset = U64_MAX;
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), -EINVAL);
}

static void rga_plane_rejects_plane_past_buffer_test(struct kunit *test)
{
	struct rga_plane_request plane = valid_plane;

	plane.planes[1].offset = 9000;
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), -EINVAL);
}

static void rga_plane_accepts_rgb_contiguous_test(struct kunit *test)
{
	struct rga_plane_request plane = valid_plane;

	plane.format = 0x2;
	plane.plane_count = 1;
	plane.byte_stride = 384;
	plane.planes[0].size = 24576;
	plane.planes[0].required = 24576;
	memset(&plane.planes[1], 0, sizeof(plane.planes[1]));
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), 0);
}

static void rga_plane_accepts_nv12_contiguous_test(struct kunit *test)
{
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&valid_plane), 0);
}

static void rga_plane_accepts_nv16_contiguous_test(struct kunit *test)
{
	struct rga_plane_request plane = valid_plane;

	plane.format = 0x8;
	plane.planes[0].required = 8192;
	plane.planes[1].required = 8192;
	plane.planes[1].size = 16384;
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), 0);
}

static void rga_plane_accepts_three_separate_planes_test(struct kunit *test)
{
	struct rga_plane_request plane = valid_plane;

	plane.format = 0xb;
	plane.plane_count = 3;
	plane.planes[1].descriptor = 8;
	plane.planes[1].offset = 0;
	plane.planes[1].size = 2048;
	plane.planes[1].required = 2048;
	plane.planes[2].descriptor = 9;
	plane.planes[2].size = 2048;
	plane.planes[2].required = 2048;
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), 0);
}

static void rga_plane_accepts_two_separate_planes_test(struct kunit *test)
{
	struct rga_plane_request plane = valid_plane;

	plane.planes[1].descriptor = 8;
	plane.planes[1].offset = 0;
	plane.planes[1].size = 4096;
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), 0);
}

static void rga_plane_accepts_aligned_crop_test(struct kunit *test)
{
	struct rga_plane_request plane = valid_plane;

	plane.active_width = 64;
	plane.active_height = 32;
	plane.x_offset = 16;
	plane.y_offset = 8;
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), 0);
}

static struct kunit_case rga_request_validation_cases[] = {
	KUNIT_CASE(rga_plane_rejects_missing_descriptor_test),
	KUNIT_CASE(rga_plane_rejects_horizontal_offset_outside_stride_test),
	KUNIT_CASE(rga_plane_rejects_vertical_offset_outside_stride_test),
	KUNIT_CASE(rga_plane_rejects_zero_width_test),
	KUNIT_CASE(rga_plane_rejects_unsupported_scheduler_format_test),
	KUNIT_CASE(rga_plane_rejects_unknown_format_test),
	KUNIT_CASE(rga_plane_rejects_unaligned_byte_stride_test),
	KUNIT_CASE(rga_plane_rejects_oversized_byte_stride_test),
	KUNIT_CASE(rga_plane_rejects_missing_uv_plane_test),
	KUNIT_CASE(rga_plane_rejects_unexpected_third_plane_test),
	KUNIT_CASE(rga_plane_rejects_plane_offset_overflow_test),
	KUNIT_CASE(rga_plane_rejects_plane_past_buffer_test),
	KUNIT_CASE(rga_plane_accepts_rgb_contiguous_test),
	KUNIT_CASE(rga_plane_accepts_nv12_contiguous_test),
	KUNIT_CASE(rga_plane_accepts_nv16_contiguous_test),
	KUNIT_CASE(rga_plane_accepts_three_separate_planes_test),
	KUNIT_CASE(rga_plane_accepts_two_separate_planes_test),
	KUNIT_CASE(rga_plane_accepts_aligned_crop_test),
	{}
};

static struct kunit_suite rga_request_validation_suite = {
	.name = "rga-validate",
	.test_cases = rga_request_validation_cases,
};

kunit_test_suite(rga_request_validation_suite);

MODULE_LICENSE("GPL");
