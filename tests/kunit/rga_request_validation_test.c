// SPDX-License-Identifier: GPL-2.0
#include <kunit/test.h>

#include "../rga3/include/rga_request_validation.h"

static const struct rga_plane_request valid_plane = {
	.address = 7,
	.active_width = 128,
	.active_height = 64,
	.width_stride = 128,
	.height_stride = 64,
	.format = RGA_REQUEST_FORMAT_NV12,
};

static void rga_plane_accepts_well_formed_nv12_test(struct kunit *test)
{
	struct rga_plane_request plane = valid_plane;

	plane.x_offset = 16;
	plane.y_offset = 8;
	plane.width_stride += plane.x_offset;
	plane.height_stride += plane.y_offset;
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), 0);
	KUNIT_EXPECT_EQ(test, plane.x_offset, 16u);
	KUNIT_EXPECT_EQ(test, plane.y_offset, 8u);
}

static void rga_plane_rejects_missing_descriptor_test(struct kunit *test)
{
	struct rga_plane_request plane = valid_plane;

	plane.address = 0;
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

static void rga_plane_rejects_short_stride_test(struct kunit *test)
{
	struct rga_plane_request plane = valid_plane;

	plane.width_stride = 126;
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), -EINVAL);
}

static void rga_plane_rejects_zero_dimensions_test(struct kunit *test)
{
	struct rga_plane_request plane = valid_plane;

	plane.active_width = 0;
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), -EINVAL);
	plane = valid_plane;
	plane.active_height = 0;
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), -EINVAL);
}

static void rga_plane_rejects_short_height_stride_test(struct kunit *test)
{
	struct rga_plane_request plane = valid_plane;

	plane.height_stride = 63;
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), -EINVAL);
}

static void rga_plane_rejects_dimension_overflow_test(struct kunit *test)
{
	struct rga_plane_request plane = valid_plane;

	plane.x_offset = ~0U;
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), -EINVAL);
	plane = valid_plane;
	plane.y_offset = ~0U;
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), -EINVAL);
}

static void rga_plane_accepts_every_declared_format_test(struct kunit *test)
{
	struct rga_plane_request plane = valid_plane;
	u32 format;

	for (format = 0; format <= RGA_REQUEST_FORMAT_MAX; format++) {
		if (format == RGA_REQUEST_FORMAT_RESERVED_17 ||
		    format == RGA_REQUEST_FORMAT_RESERVED_27)
			continue;
		plane.format = format;
		KUNIT_EXPECT_EQ_MSG(test, rga_plane_request_validate(&plane), 0,
				    "format %#x", format);
	}
}

static void rga_plane_rejects_unknown_format_test(struct kunit *test)
{
	struct rga_plane_request plane = valid_plane;

	plane.format = RGA_REQUEST_FORMAT_UNKNOWN;
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), -EINVAL);
	plane.format = RGA_REQUEST_FORMAT_RESERVED_17;
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), -EINVAL);
	plane.format = RGA_REQUEST_FORMAT_RESERVED_27;
	KUNIT_EXPECT_EQ(test, rga_plane_request_validate(&plane), -EINVAL);
}

static void rga_user_request_shape_validation_test(struct kunit *test)
{
	KUNIT_EXPECT_EQ(test, rga_user_request_validate(1, 1, 1, 16), 0);
	KUNIT_EXPECT_EQ(test, rga_user_request_validate(0, 1, 1, 16), -EINVAL);
	KUNIT_EXPECT_EQ(test, rga_user_request_validate(1, 0, 1, 16), -EINVAL);
	KUNIT_EXPECT_EQ(test, rga_user_request_validate(1, 1, 0, 16), -EINVAL);
	KUNIT_EXPECT_EQ(test, rga_user_request_validate(1, 17, 1, 16), -EINVAL);
}

static struct kunit_case rga_request_validation_cases[] = {
	KUNIT_CASE(rga_plane_accepts_well_formed_nv12_test),
	KUNIT_CASE(rga_plane_rejects_missing_descriptor_test),
	KUNIT_CASE(rga_plane_rejects_horizontal_offset_outside_stride_test),
	KUNIT_CASE(rga_plane_rejects_vertical_offset_outside_stride_test),
	KUNIT_CASE(rga_plane_rejects_short_stride_test),
	KUNIT_CASE(rga_plane_rejects_zero_dimensions_test),
	KUNIT_CASE(rga_plane_rejects_short_height_stride_test),
	KUNIT_CASE(rga_plane_rejects_dimension_overflow_test),
	KUNIT_CASE(rga_plane_accepts_every_declared_format_test),
	KUNIT_CASE(rga_plane_rejects_unknown_format_test),
	KUNIT_CASE(rga_user_request_shape_validation_test),
	{}
};

static struct kunit_suite rga_request_validation_suite = {
	.name = "rockchip-rga-request-validation",
	.test_cases = rga_request_validation_cases,
};

kunit_test_suite(rga_request_validation_suite);

MODULE_LICENSE("GPL");
