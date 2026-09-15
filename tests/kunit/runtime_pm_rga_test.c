// SPDX-License-Identifier: GPL-2.0-only
#include "runtime_pm_rga_fixture.h"

static void rga_wait_one_second_per_task_test(struct kunit *test)
{
	struct pm_rga_fixture *f = test->priv;
	struct rga_request request = { .is_done = true, .task_count = 1 };

	/* Milliseconds are a fixed contract, not a function of the kernel tick rate. */
	KUNIT_EXPECT_EQ(test, RGA_JOB_TIMEOUT_DELAY, 1000);
	KUNIT_EXPECT_EQ(test, rga_request_wait(&request), 0);
	KUNIT_EXPECT_EQ(test, f->wait_calls, 1);
	KUNIT_EXPECT_EQ(test, f->wait_timeout, (unsigned long)HZ);
	request.task_count = 3;
	KUNIT_EXPECT_EQ(test, rga_request_wait(&request), 0);
	KUNIT_EXPECT_EQ(test, f->wait_calls, 2);
	KUNIT_EXPECT_EQ(test, f->wait_timeout, 3UL * HZ);
}

static void rga_failed_reset_retains_tables_test(struct kunit *test)
{
	struct pm_rga_fixture *f = test->priv;
	struct rga_job *job = pm_rga_job(test, 1);
	u32 *table = kunit_kzalloc(test, PAGE_SIZE, GFP_KERNEL);

	/* Given: a running job owns a live PTE page and reset cannot drain DMA. */
	KUNIT_ASSERT_NOT_NULL(test, table);
	job->task_buffers = kunit_kzalloc(test, sizeof(*job->task_buffers), GFP_KERNEL);
	KUNIT_ASSERT_NOT_NULL(test, job->task_buffers);
	job->task_buffers[0].src_buffer.page_table = table;
	rga_job_next(&f->scheduler);
	f->reset_error = -ETIMEDOUT;

	/* When: the real scheduler abort path encounters that reset failure. */
	rga_request_scheduler_abort(&f->scheduler);

	/* Then: neither the mappings nor the owning job/power may be released. */
	KUNIT_EXPECT_PTR_EQ(test, job->task_buffers[0].src_buffer.page_table, table);
	KUNIT_EXPECT_EQ(test, f->unmapped, 0);
	KUNIT_EXPECT_EQ(test, f->retired, 0);
	KUNIT_EXPECT_EQ(test, f->scheduler.pd_refcount, 1);
	KUNIT_EXPECT_TRUE(test, f->scheduler.dma_faulted);
	KUNIT_EXPECT_EQ(test, f->scheduler.reset_result, -ETIMEDOUT);
}

static void rga_queued_deadline_cancels_test(struct kunit *test)
{
	struct pm_rga_fixture *f = test->priv;
	struct rga_request request = { .id = 2, .task_count = 1 };
	struct rga_job *running = pm_rga_job(test, 1);

	/* Given: an unrelated running job keeps a synchronous request queued. */
	pm_rga_job(test, request.id);
	rga_job_next(&f->scheduler);
	/* When: the wait primitive reports the deadline expired. */
	KUNIT_EXPECT_EQ(test, rga_request_wait(&request), -ETIMEDOUT);
	KUNIT_EXPECT_EQ(test, f->wait_calls, 1);
	KUNIT_EXPECT_EQ(test, f->wait_timeout, (unsigned long)HZ);
	/* Then: it cannot execute after the caller observes timeout. */
	KUNIT_EXPECT_TRUE(test, list_empty(&f->scheduler.todo_list));
	KUNIT_EXPECT_EQ(test, f->retired, 1);
	KUNIT_EXPECT_PTR_EQ(test, f->scheduler.running_job, running);
	request.id = 1;
	rga_request_scheduler_job_abort(&request);
}

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

static void rga_expired_queue_never_starts_test(struct kunit *test)
{
	struct pm_rga_fixture *f = test->priv;
	struct rga_job *job = pm_rga_job(test, 1);

	job->timestamp.insert = ktime_sub_ms(ktime_get(), RGA_QUEUE_TIMEOUT_MS + 1);
	rga_job_next(&f->scheduler);
	KUNIT_EXPECT_EQ(test, job->ret, -ETIMEDOUT);
	KUNIT_EXPECT_PTR_EQ(test, f->scheduler.running_job, NULL);
	KUNIT_EXPECT_EQ(test, f->scheduler.pd_refcount, 0);
	KUNIT_EXPECT_EQ(test, f->retired, 1);
}

static void rga_queue_admission_limit_test(struct kunit *test)
{
	struct pm_rga_fixture *f = test->priv;
	struct rga_job *extra;
	int i;

	for (i = 0; i < RGA_SCHED_QUEUE_LIMIT; i++)
		pm_rga_job(test, i + 1);
	extra = pm_rga_job(test, RGA_SCHED_QUEUE_LIMIT + 1);
	list_del_init(&extra->head);
	f->scheduler.job_count--;
	atomic_dec(&f->driver.telemetry_queue_depth);
	KUNIT_EXPECT_EQ(test, rga_job_insert_todo_list(extra), -EAGAIN);
	KUNIT_EXPECT_EQ(test, f->scheduler.job_count, RGA_SCHED_QUEUE_LIMIT);
	KUNIT_EXPECT_TRUE(test, list_empty(&extra->head));
}

static void rga_cancel_and_shutdown_retain_failed_reset_test(struct kunit *test)
{
	struct pm_rga_fixture *f = test->priv;
	struct rga_request request = { .id = 1 };
	struct rga_job *job = pm_rga_job(test, request.id);

	rga_job_next(&f->scheduler);
	f->reset_error = -ETIMEDOUT;
	rga_request_scheduler_job_abort(&request);
	KUNIT_EXPECT_EQ(test, f->unmapped, 0);
	KUNIT_EXPECT_EQ(test, f->retired, 0);
	KUNIT_EXPECT_PTR_EQ(test, f->scheduler.running_job, job);
	f->reset_error = 0;
	rga_request_scheduler_shutdown(&f->scheduler);
	KUNIT_EXPECT_EQ(test, f->unmapped, 0);
	KUNIT_EXPECT_EQ(test, f->retired, 0);
	KUNIT_EXPECT_PTR_EQ(test, f->scheduler.running_job, job);
	KUNIT_EXPECT_EQ(test, f->scheduler.pd_refcount, 1);
}

static struct kunit_case pm_rga_cases[] = {
	KUNIT_CASE(rga_wait_one_second_per_task_test),
	KUNIT_CASE(rga_expired_queue_never_starts_test),
	KUNIT_CASE(rga_queue_admission_limit_test),
	KUNIT_CASE(rga_cancel_and_shutdown_retain_failed_reset_test),
	KUNIT_CASE(rga_failed_reset_retains_tables_test),
	KUNIT_CASE(rga_queued_deadline_cancels_test),
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
