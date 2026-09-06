// SPDX-License-Identifier: GPL-2.0-only
#include "runtime_pm_rga_fixture.h"

static void rga_cancel_after_reset_balances_power_test(struct kunit *test)
{
	struct pm_rga_fixture *f = test->priv;
	struct rga_request request = { .id = 2 };
	struct rga_job *next;

	/* Given: reset retires one job and starts another before its two puts. */
	pm_rga_job(test, 1);
	next = pm_rga_job(test, request.id);
	rga_job_next(&f->scheduler);
	rga_request_scheduler_abort(&f->scheduler);
	KUNIT_ASSERT_PTR_EQ(test, f->scheduler.running_job, next);
	KUNIT_ASSERT_EQ(test, atomic_read(&f->pdev->dev.power.usage_count), 1);
	KUNIT_ASSERT_EQ(test, f->scheduler.status, RGA_SCHEDULER_ABORT);

	/* When: cancel the next job, then repeat cancellation after withdrawal. */
	rga_request_scheduler_job_abort(&request);
	rga_request_scheduler_job_abort(&request);

	/* Then: both jobs retire and the next job releases exactly its own ref. */
	KUNIT_EXPECT_EQ(test, f->retired, 2);
	KUNIT_EXPECT_EQ(test, f->scheduler.pd_refcount, 0);
	KUNIT_EXPECT_EQ(test, f->clock_refs, 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->pdev->dev.power.usage_count), 0);
}

static void rga_cancel_pending_preserves_running_power_test(struct kunit *test)
{
	struct pm_rga_fixture *f = test->priv;
	struct rga_request request = { .id = 2 };
	struct rga_job *running = pm_rga_job(test, 1);

	pm_rga_job(test, request.id);
	rga_job_next(&f->scheduler);
	rga_request_scheduler_job_abort(&request);
	KUNIT_EXPECT_PTR_EQ(test, f->scheduler.running_job, running);
	KUNIT_EXPECT_EQ(test, f->scheduler.pd_refcount, 1);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->pdev->dev.power.usage_count), 1);
	KUNIT_EXPECT_EQ(test, f->retired, 1);
	request.id = 1;
	rga_request_scheduler_job_abort(&request);
}

static void rga_failed_resume_has_no_power_ref_test(struct kunit *test)
{
	struct pm_rga_fixture *f = test->priv;

	f->resume_error = -EIO;
	KUNIT_EXPECT_EQ(test, rga_power_enable(&f->scheduler), -EIO);
	KUNIT_EXPECT_EQ(test, f->scheduler.pd_refcount, 0);
	KUNIT_EXPECT_EQ(test, f->clock_refs, 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->pdev->dev.power.usage_count), 0);
}

static void rga_failed_clocks_release_power_test(struct kunit *test)
{
	struct pm_rga_fixture *f = test->priv;

	f->clock_error = -EIO;
	KUNIT_EXPECT_EQ(test, rga_power_enable(&f->scheduler), -EIO);
	KUNIT_EXPECT_EQ(test, f->scheduler.pd_refcount, 0);
	KUNIT_EXPECT_EQ(test, f->clock_refs, 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->pdev->dev.power.usage_count), 0);
}

static void rga_failed_registers_release_power_test(struct kunit *test)
{
	struct pm_rga_fixture *f = test->priv;

	pm_rga_job(test, 1);
	f->register_error = -EIO;
	rga_job_next(&f->scheduler);
	KUNIT_EXPECT_PTR_EQ(test, f->scheduler.running_job, NULL);
	KUNIT_EXPECT_EQ(test, f->retired, 1);
	KUNIT_EXPECT_EQ(test, f->scheduler.pd_refcount, 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->pdev->dev.power.usage_count), 0);
}

static void rga_release_uses_autosuspend_test(struct kunit *test)
{
	struct pm_rga_fixture *f = test->priv;
	struct device *dev = &f->pdev->dev;

	KUNIT_ASSERT_EQ(test, rga_power_enable(&f->scheduler), 0);
	KUNIT_ASSERT_EQ(test, rga_power_disable(&f->scheduler), 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&dev->power.usage_count), 0);
	KUNIT_EXPECT_EQ(test, f->clock_refs, 0);
	KUNIT_EXPECT_FALSE(test, pm_runtime_suspended(dev));
	KUNIT_EXPECT_GT(test, pm_runtime_autosuspend_expiration(dev), 0ULL);
}

static void rga_power_all_balances_test(struct kunit *test)
{
	struct pm_rga_fixture *f = test->priv;

	KUNIT_ASSERT_EQ(test, rga_power_enable_all(), 0);
	rga_power_disable_all();
	KUNIT_EXPECT_EQ(test, atomic_read(&f->pdev->dev.power.usage_count), 0);
}

static struct kunit_case pm_rga_cases[] = {
	KUNIT_CASE(rga_cancel_after_reset_balances_power_test),
	KUNIT_CASE(rga_cancel_pending_preserves_running_power_test),
	KUNIT_CASE(rga_failed_resume_has_no_power_ref_test),
	KUNIT_CASE(rga_failed_clocks_release_power_test),
	KUNIT_CASE(rga_failed_registers_release_power_test),
	KUNIT_CASE(rga_release_uses_autosuspend_test),
	KUNIT_CASE(rga_power_all_balances_test),
	{}
};
static struct kunit_suite pm_rga_suite = {
	.name = "rockchip-rga-runtime-pm",
	.init = pm_rga_init,
	.exit = pm_rga_exit,
	.test_cases = pm_rga_cases,
};
kunit_test_suite(pm_rga_suite);
MODULE_LICENSE("GPL");
