/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef ISLAND_RUNTIME_PM_RGA_FIXTURE_H
#define ISLAND_RUNTIME_PM_RGA_FIXTURE_H
#include <kunit/test.h>
#define rga_drvdata pm_test_drvdata
#define rga_power_enable pm_test_power_enable
#define rga_power_disable pm_test_power_disable
#define rga_job_next pm_test_job_next
#define rga_request_scheduler_abort pm_test_scheduler_abort
#include "../rga3/include/rga_drv.h"
#include "../rga3/include/rga_job.h"

struct rga_drvdata_t *rga_drvdata;

struct pm_rga_fixture {
	struct rga_drvdata_t driver;
	struct rga_scheduler_t scheduler;
	struct platform_device *pdev;
	int resume_error;
	int clock_error;
	int register_error;
	int clock_refs;
	int retired;
};

static struct pm_rga_fixture *pm_fixture;

static int pm_test_resume(struct device *dev)
{
	struct pm_rga_fixture *f = dev_get_drvdata(dev);

	return f->resume_error;
}

static int pm_test_suspend(struct device *dev)
{
	return 0;
}

static struct dev_pm_domain pm_test_domain = {
	.ops = { .runtime_resume = pm_test_resume, .runtime_suspend = pm_test_suspend },
};

static int pm_test_clocks_enable(int count, struct clk_bulk_data *clocks)
{
	if (pm_fixture->clock_error)
		return pm_fixture->clock_error;
	pm_fixture->clock_refs++;
	return 0;
}

static void pm_test_clocks_disable(int count, struct clk_bulk_data *clocks)
{
	pm_fixture->clock_refs--;
}

static int pm_test_set_reg(struct rga_job *job, struct rga_scheduler_t *scheduler)
{
	return pm_fixture->register_error;
}

static const struct rga_backend_ops pm_test_ops = { .set_reg = pm_test_set_reg };

static void pm_test_retire(struct rga_job *job)
{
	list_del_init(&job->head);
	pm_fixture->retired++;
}

static void pm_test_job_release(struct kref *ref)
{
	/* The fixture owns the storage, independently of execution references. */
}

#define clk_bulk_prepare_enable pm_test_clocks_enable
#define clk_bulk_disable_unprepare pm_test_clocks_disable
#define rga_err(...) do { } while (0)
#define rga_job_err(...) do { } while (0)
#define rga_req_err(...) do { } while (0)
#define trace_rga_job_started(...) do { } while (0)
#define rga_telemetry_record_busy(...) do { } while (0)
#define rga_telemetry_reset(...) do { } while (0)
#define rga_mm_unmap_job_info(job) do { } while (0)
#define rga_request_release_signal(scheduler, job) pm_test_retire(job)
#define rga_job_cleanup(job) pm_test_retire(job)
#define rga_job_get(job) kref_get(&(job)->refcount)
#define rga_job_put(job) kref_put(&(job)->refcount, pm_test_job_release)

#include "runtime_pm_rga_power.inc"
#include "runtime_pm_rga_jobs.inc"

static int pm_rga_init(struct kunit *test)
{
	struct pm_rga_fixture *f = kunit_kzalloc(test, sizeof(*f), GFP_KERNEL);
	struct rga_scheduler_t *s;

	if (!f)
		return -ENOMEM;
	f->pdev = platform_device_register_simple("island-pm-rga", PLATFORM_DEVID_AUTO, NULL, 0);
	if (IS_ERR(f->pdev))
		return PTR_ERR(f->pdev);
	test->priv = f;
	pm_fixture = f;
	rga_drvdata = &f->driver;
	s = &f->scheduler;
	s->dev = &f->pdev->dev;
	s->ops = &pm_test_ops;
	s->core = RGA3_SCHEDULER_CORE0;
	mutex_init(&s->job_mutex);
	spin_lock_init(&s->irq_lock);
	INIT_LIST_HEAD(&s->todo_list);
	media_recovery_init(&s->recovery);
	spin_lock_init(&s->dump.lock);
	f->driver.scheduler[0] = s;
	f->driver.num_of_scheduler = 1;
	dev_set_drvdata(s->dev, f);
	s->dev->pm_domain = &pm_test_domain;
	pm_runtime_set_autosuspend_delay(s->dev, 2000);
	pm_runtime_use_autosuspend(s->dev);
	pm_runtime_enable(s->dev);
	return 0;
}

static void pm_rga_exit(struct kunit *test)
{
	struct pm_rga_fixture *f = test->priv;
	struct device *dev = &f->pdev->dev;

	/* Clean leaked test references too, after the test has recorded failure. */
	while (f->scheduler.pd_refcount)
		rga_power_disable(&f->scheduler);
	pm_runtime_barrier(dev);
	pm_runtime_suspend(dev);
	pm_runtime_disable(dev);
	pm_runtime_dont_use_autosuspend(dev);
	dev->pm_domain = NULL;
	platform_device_unregister(f->pdev);
	rga_drvdata = NULL;
}

static struct rga_job *pm_rga_job(struct kunit *test, u32 request_id)
{
	struct pm_rga_fixture *f = test->priv;
	struct rga_job *job = kunit_kzalloc(test, sizeof(*job), GFP_KERNEL);

	KUNIT_ASSERT_NOT_NULL(test, job);
	job->session = kunit_kzalloc(test, sizeof(*job->session), GFP_KERNEL);
	KUNIT_ASSERT_NOT_NULL(test, job->session);
	job->scheduler = &f->scheduler;
	job->request_id = request_id;
	job->task_count = 1;
	INIT_LIST_HEAD(&job->head);
	kref_init(&job->refcount);
	list_add_tail(&job->head, &f->scheduler.todo_list);
	f->scheduler.job_count++;
	atomic_inc(&f->driver.telemetry_queue_depth);
	return job;
}
#endif
