// SPDX-License-Identifier: GPL-2.0
#include <kunit/test.h>
#include "../mpp/mpp_rkvenc_test.h"
#include "../mpp/media_fault.h"

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

static struct kunit_case mpp_fault_injection_cases[] = {
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
