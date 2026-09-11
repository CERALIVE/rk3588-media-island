// SPDX-License-Identifier: GPL-2.0-only
#include <kunit/test.h>
#include "../rga3/rga_test.h"

static void rga_fault_disabled_stubs_test(struct kunit *test)
{
	KUNIT_ASSERT_FALSE(test, IS_ENABLED(CONFIG_ROCKCHIP_RGA_CERALIVE_TEST));
	KUNIT_EXPECT_EQ(test, rga_test_init(), 0);
	KUNIT_EXPECT_FALSE(test, rga_test_irq_timeout());
	KUNIT_EXPECT_FALSE(test, rga_test_hang_task());
	KUNIT_EXPECT_FALSE(test, rga_test_fail_reset());
	KUNIT_EXPECT_FALSE(test, rga_test_inject_iommu_fault());
	KUNIT_EXPECT_FALSE(test, rga_iommu_test_prepare(NULL));
	rga_iommu_test_fault(NULL);
	rga_test_exit();
}

static struct kunit_case rga_fault_disabled_cases[] = {
	KUNIT_CASE(rga_fault_disabled_stubs_test),
	{}
};
static struct kunit_suite rga_fault_disabled_suite = {
	.name = "rockchip-rga-fault-disabled",
	.test_cases = rga_fault_disabled_cases,
};
kunit_test_suite(rga_fault_disabled_suite);
MODULE_LICENSE("GPL");
