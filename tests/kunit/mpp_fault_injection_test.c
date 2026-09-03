// SPDX-License-Identifier: GPL-2.0
#include <kunit/test.h>
#include "../mpp/mpp_rkvenc_test.h"

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

static struct kunit_case mpp_fault_injection_cases[] = {
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
