// SPDX-License-Identifier: GPL-2.0
#include <kunit/test.h>
#include <asm/pgtable.h>

#include "../mpp/mpp_request_bounds.h"
#include "../mpp/media_request_size.h"
#include "../mpp/media_map.h"

#define RKVENC_V2_CLASS_BASE_S	0x0000
#define RKVENC_V2_CLASS_BASE_E	0x0058
#define RKVENC_V2_CLASS_PIC_S	0x0280
#define RKVENC_V2_CLASS_PIC_E	0x03f4
#define RKVENC_V2_CLASS_RC_S	0x1000
#define RKVENC_V2_CLASS_RC_E	0x10e0
#define RKVENC_V2_CLASS_PAR_S	0x1700
#define RKVENC_V2_CLASS_PAR_E	0x1cd4
#define RKVENC_V2_CLASS_SQI_S	0x2000
#define RKVENC_V2_CLASS_SQI_E	0x21e4
#define RKVENC_V2_CLASS_SCL_S	0x2200
#define RKVENC_V2_CLASS_SCL_E	0x2c98
#define RKVENC_V2_CLASS_OSD_S	0x3000
#define RKVENC_V2_CLASS_OSD_E	0x347c
#define RKVENC_V2_CLASS_ST_S	0x4000
#define RKVENC_V2_CLASS_ST_E	0x42cc
#define RKVENC_V2_CLASS_DEBUG_S	0x5000
#define RKVENC_V2_CLASS_DEBUG_E	0x5354

static const struct mpp_req_class rkvenc_v2_classes[] = {
	{ RKVENC_V2_CLASS_BASE_S, RKVENC_V2_CLASS_BASE_E },
	{ RKVENC_V2_CLASS_PIC_S, RKVENC_V2_CLASS_PIC_E },
	{ RKVENC_V2_CLASS_RC_S, RKVENC_V2_CLASS_RC_E },
	{ RKVENC_V2_CLASS_PAR_S, RKVENC_V2_CLASS_PAR_E },
	{ RKVENC_V2_CLASS_SQI_S, RKVENC_V2_CLASS_SQI_E },
	{ RKVENC_V2_CLASS_SCL_S, RKVENC_V2_CLASS_SCL_E },
	{ RKVENC_V2_CLASS_OSD_S, RKVENC_V2_CLASS_OSD_E },
	{ RKVENC_V2_CLASS_ST_S, RKVENC_V2_CLASS_ST_E },
	{ RKVENC_V2_CLASS_DEBUG_S, RKVENC_V2_CLASS_DEBUG_E },
};

static int coverage_for(u32 offset, u32 size, struct mpp_req_coverage *coverage)
{
	u32 i;

	mpp_req_coverage_init(coverage);
	for (i = 0; i < ARRAY_SIZE(rkvenc_v2_classes); i++) {
		struct mpp_req_part part;

		if (mpp_req_class_part(offset, size, &rkvenc_v2_classes[i], &part))
			continue;
		mpp_req_coverage_add(coverage, &part);
	}

	return mpp_req_coverage_check(offset, size, rkvenc_v2_classes,
				      ARRAY_SIZE(rkvenc_v2_classes), coverage);
}

static void mpp_req_shape_rejects_wrap_test(struct kunit *test)
{
	KUNIT_EXPECT_EQ(test, mpp_req_shape(0xfffffff0, 0x20), -EINVAL);
}

static void mpp_req_shape_rejects_short_word_test(struct kunit *test)
{
	KUNIT_EXPECT_EQ(test, mpp_req_shape(0, 3), -EINVAL);
}

static void mpp_req_shape_rejects_unaligned_test(struct kunit *test)
{
	KUNIT_EXPECT_EQ(test, mpp_req_shape(2, 8), -EINVAL);
	KUNIT_EXPECT_EQ(test, mpp_req_shape(0, 6), -EINVAL);
}

static void mpp_req_element_count_rejects_odd_size_test(struct kunit *test)
{
	u32 count = 0;

	KUNIT_EXPECT_EQ(test, mpp_req_element_count(161, sizeof(u16), 80, &count),
			-EINVAL);
	KUNIT_EXPECT_EQ(test, mpp_req_element_count(13, 8, 80, &count), -EINVAL);
}

static void mpp_req_counts_are_bounded_test(struct kunit *test)
{
	KUNIT_EXPECT_EQ(test, mpp_req_count_room(15, 16), 0);
	KUNIT_EXPECT_EQ(test, mpp_req_count_room(16, 16), -EINVAL);
}

static void mpp_iova_offset_guardrail_test(struct kunit *test)
{
	KUNIT_EXPECT_EQ(test, mpp_iova_offset_check(0, 0), -EINVAL);
	KUNIT_EXPECT_EQ(test, mpp_iova_offset_check(0x10000, 0xffff), 0);
	KUNIT_EXPECT_EQ(test, mpp_iova_offset_check(0x10000, 0x10000), -EINVAL);
	KUNIT_EXPECT_EQ(test, mpp_iova_offset_check(0x10000, 0x10004), -EINVAL);
}

static void mpp_req_result_window_uses_actual_buffer_test(struct kunit *test)
{
	u32 start = 0;

	KUNIT_EXPECT_EQ(test, mpp_req_window_offset(0x2004, 488, 0x2000, 488,
						    &start), -EINVAL);
	KUNIT_EXPECT_EQ(test, mpp_req_window_offset(0x2004, 484, 0x2000, 488,
						    &start), 0);
	KUNIT_EXPECT_EQ(test, start, 4u);
}

static void mpp_req_hevc_sqi_scl_span_test(struct kunit *test)
{
	struct mpp_req_coverage coverage;

	KUNIT_ASSERT_EQ(test, coverage_for(0x2000, 3228, &coverage), 0);
	KUNIT_EXPECT_EQ(test, coverage.bytes, 3204u);
	KUNIT_EXPECT_EQ(test, coverage.hi - coverage.lo - coverage.bytes, 24u);
}

static void mpp_req_libmpp_partial_par_program_test(struct kunit *test)
{
	struct mpp_req_coverage coverage;

	KUNIT_EXPECT_EQ(test, coverage_for(0x1700, 720, &coverage), 0);
	KUNIT_EXPECT_EQ(test, coverage.bytes, 720u);
}

static void mpp_req_class_overrun_rejected_test(struct kunit *test)
{
	struct mpp_req_coverage coverage;

	KUNIT_EXPECT_EQ(test, coverage_for(0x0004, 0x4000, &coverage), -EINVAL);
}

static void mpp_req_rkvdec2_bounds_test(struct kunit *test)
{
	u32 size = 0;

	KUNIT_EXPECT_EQ(test, mpp_req_buffer_check(0xfffffff0, 0x20, 0, 0x3000,
						   0, 0x3000, &size), -EINVAL);
	KUNIT_EXPECT_EQ(test, mpp_req_buffer_check(0x2ffc, 8, 0, 0x3000,
						   0, 0x3000, &size), 0);
	KUNIT_EXPECT_EQ(test, size, 4u);
}

static void mpp_req_jpgdec_bounds_test(struct kunit *test)
{
	u32 size = 0;

	KUNIT_EXPECT_EQ(test, mpp_req_buffer_check(2, 8, 0, 0x400,
						   0, 0x400, &size), -EINVAL);
	KUNIT_EXPECT_EQ(test, mpp_req_count_room(16, 16), -EINVAL);
}

static void media_request_size_rejects_overflow_test(struct kunit *test)
{
	size_t bytes = 123;

	KUNIT_EXPECT_EQ(test, media_request_size(SIZE_MAX / sizeof(u64) + 1,
					       sizeof(u64), &bytes), -EINVAL);
	KUNIT_EXPECT_EQ(test, bytes, (size_t)0);
	KUNIT_EXPECT_EQ(test, media_request_size(8192, sizeof(u64), &bytes), 0);
	KUNIT_EXPECT_EQ(test, bytes, (size_t)65536);
}

static void media_map_lifetime_test(struct kunit *test)
{
	struct page *page = alloc_page(GFP_KERNEL | __GFP_ZERO);
	struct iosys_map map = IOSYS_MAP_INIT_VADDR(NULL);
	u32 value = 0x12345678, result = 0;

	KUNIT_ASSERT_NOT_NULL(test, page);
	iosys_map_set_vaddr(&map, vmap(&page, 1, VM_MAP, PAGE_KERNEL));
	KUNIT_EXPECT_TRUE(test, iosys_map_is_set(&map));
	if (iosys_map_is_set(&map)) {
		iosys_map_memcpy_to(&map, 16, &value, sizeof(value));
		KUNIT_EXPECT_EQ(test, media_map_read(&result, &map, PAGE_SIZE,
						   16, sizeof(result)), 0);
		KUNIT_EXPECT_EQ(test, result, value);
		KUNIT_EXPECT_EQ(test, media_map_read(&result, &map, PAGE_SIZE,
						   PAGE_SIZE - 1, sizeof(result)), -EINVAL);
		media_vunmap(&map);
		KUNIT_EXPECT_TRUE(test, iosys_map_is_null(&map));
		media_vunmap(&map);
	}
	__free_page(page);
}

static struct kunit_case mpp_request_bounds_cases[] = {
	KUNIT_CASE(media_map_lifetime_test),
	KUNIT_CASE(media_request_size_rejects_overflow_test),
	KUNIT_CASE(mpp_req_shape_rejects_wrap_test),
	KUNIT_CASE(mpp_req_shape_rejects_short_word_test),
	KUNIT_CASE(mpp_req_shape_rejects_unaligned_test),
	KUNIT_CASE(mpp_req_element_count_rejects_odd_size_test),
	KUNIT_CASE(mpp_req_counts_are_bounded_test),
	KUNIT_CASE(mpp_iova_offset_guardrail_test),
	KUNIT_CASE(mpp_req_result_window_uses_actual_buffer_test),
	KUNIT_CASE(mpp_req_hevc_sqi_scl_span_test),
	KUNIT_CASE(mpp_req_libmpp_partial_par_program_test),
	KUNIT_CASE(mpp_req_class_overrun_rejected_test),
	KUNIT_CASE(mpp_req_rkvdec2_bounds_test),
	KUNIT_CASE(mpp_req_jpgdec_bounds_test),
	{}
};

static struct kunit_suite mpp_request_bounds_suite = {
	.name = "rockchip-mpp-request-bounds",
	.test_cases = mpp_request_bounds_cases,
};

kunit_test_suite(mpp_request_bounds_suite);

MODULE_LICENSE("GPL");
