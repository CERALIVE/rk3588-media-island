// SPDX-License-Identifier: GPL-2.0-only
#include <kunit/test.h>

#include "../mpp/mpp_telemetry.h"

static void mpp_telemetry_load_zero_test(struct kunit *test)
{
	char line[128];

	mpp_telemetry_format_load(line, sizeof(line), "fdbd0000.rkvenc-core",
				  0, 0, 0, 0);
	KUNIT_EXPECT_STREQ(test, line,
		"fdbd0000.rkvenc-core      load:   0.00% utilization:   0.00%\n");
}

static void mpp_telemetry_load_fraction_test(struct kunit *test)
{
	char line[128];

	mpp_telemetry_format_load(line, sizeof(line), "fdc38100.video-codec",
				  7, 5, 93, 42);
	KUNIT_EXPECT_STREQ(test, line,
		"fdc38100.video-codec      load:   7.05% utilization:  93.42%\n");
}

static void mpp_telemetry_session_stats_test(struct kunit *test)
{
	const struct mpp_session_telemetry_values values = {
		.client = 16,
		.tasks = 7,
		.bytes = 1048576,
	};
	char stats[96];

	mpp_telemetry_format_session(stats, sizeof(stats), &values);
	KUNIT_EXPECT_STREQ(test, stats,
		"client:\t16\ntasks:\t7\nbytes:\t1048576\n");
}

static void mpp_telemetry_mark_once_test(struct kunit *test)
{
	unsigned long state = 0;

	KUNIT_EXPECT_TRUE(test, mpp_telemetry_mark_once(&state, 3));
	KUNIT_EXPECT_FALSE(test, mpp_telemetry_mark_once(&state, 3));
	KUNIT_EXPECT_TRUE(test, mpp_telemetry_mark_once(&state, 5));
}

static struct kunit_case mpp_telemetry_cases[] = {
	KUNIT_CASE(mpp_telemetry_load_zero_test),
	KUNIT_CASE(mpp_telemetry_load_fraction_test),
	KUNIT_CASE(mpp_telemetry_session_stats_test),
	KUNIT_CASE(mpp_telemetry_mark_once_test),
	{}
};

static struct kunit_suite mpp_telemetry_suite = {
	.name = "rockchip-mpp-telemetry",
	.test_cases = mpp_telemetry_cases,
};

kunit_test_suite(mpp_telemetry_suite);

MODULE_LICENSE("GPL");
