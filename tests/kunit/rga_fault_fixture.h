/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef RGA_FAULT_FIXTURE_H
#define RGA_FAULT_FIXTURE_H

#include <kunit/test.h>
#include <kunit/device.h>
#include <linux/kthread.h>
#include <linux/completion.h>

/* Compile the opt-in seam, not the hardware driver, in this translation unit. */
#define CONFIG_ROCKCHIP_RGA_CERALIVE_TEST 1
#define rga_drvdata fault_drvdata
#define rga_power_enable fault_power_enable
#define rga_power_disable fault_power_disable
#define rga_telemetry_reset fault_telemetry_reset
#define rga_request_scheduler_abort fault_scheduler_abort
#define rga_request_release_signal fault_release_signal
#include "../rga3/include/rga_job.h"
#include "../rga3/include/rga_iommu.h"
#include "../rga3/include/rga_mm.h"
#include "../rga3/include/rga_common.h"
#include "rga_fault_provider.inc"
#include "../rga3/rga_test.c"

struct rga_drvdata_t *rga_drvdata;

struct rga_fault_fixture {
	struct rga_drvdata_t driver;
	struct rga_scheduler_t scheduler;
	struct rga_iommu_info iommu;
	struct rga_session session;
	struct rga_job job;
	int power_refs;
	int power_error;
	int starts;
	int resets;
	int irqs;
	int signals;
	int unmaps;
	int aborts;
	bool copy_fault;
};

static struct rga_fault_fixture *fault_fixture;

int rga_power_enable(struct rga_scheduler_t *scheduler)
{
	if (fault_fixture->power_error)
		return fault_fixture->power_error;
	fault_fixture->power_refs++;
	return 0;
}

int rga_power_disable(struct rga_scheduler_t *scheduler)
{
	fault_fixture->power_refs--;
	return 0;
}

static int fault_set_reg(struct rga_job *job, struct rga_scheduler_t *scheduler)
{
	fault_fixture->starts++;
	return 0;
}

static void fault_soft_reset(struct rga_scheduler_t *scheduler)
{
	fault_fixture->resets++;
}

static int fault_irq(struct rga_scheduler_t *scheduler)
{
	fault_fixture->irqs++;
	return IRQ_HANDLED;
}

static const struct rga_backend_ops fault_ops = {
	.set_reg = fault_set_reg,
	.soft_reset = fault_soft_reset,
	.irq = fault_irq,
};

void rga_request_scheduler_abort(struct rga_scheduler_t *scheduler)
{
	fault_fixture->aborts++;
}

int rga_request_release_signal(struct rga_scheduler_t *scheduler, struct rga_job *job)
{
	fault_fixture->signals++;
	return 0;
}

static unsigned long fault_copy_from_user(void *dst, const void __user *src, size_t size)
{
	if (fault_fixture->copy_fault)
		return size;
	memcpy(dst, (const void __force *)src, size);
	return 0;
}

#define copy_from_user fault_copy_from_user
#define rga_dump_job(...) do { } while (0)
#define rga_mm_unmap_job_info(job) (fault_fixture->unmaps++)
#define trace_rga_reset(...) do { } while (0)
#define trace_rga_job_started(...) do { } while (0)
#define trace_rga_job_timeout(...) do { } while (0)
#include "rga_fault_source.inc"

static const struct {
	const char *name;
	struct rga_fault_knob *knob;
	bool (*consume)(void);
} fault_controls[] = {
	{ "irq_timeout_once", &irq_timeout, rga_test_irq_timeout },
	{ "hang_task_once", &hang_task, rga_test_hang_task },
	{ "fail_reset_once", &fail_reset, rga_test_fail_reset },
	{ "inject_iommu_fault_once", &inject_iommu_fault, rga_test_inject_iommu_fault },
};

static int rga_fault_init(struct kunit *test)
{
	struct rga_fault_fixture *f = kunit_kzalloc(test, sizeof(*f), GFP_KERNEL);
	int i;

	if (!f)
		return -ENOMEM;
	for (i = 0; i < ARRAY_SIZE(fault_controls); i++) {
		atomic_set(&fault_controls[i].knob->armed, 0);
		atomic_set(&fault_controls[i].knob->consumed, 0);
	}
	test->priv = f;
	fault_fixture = f;
	rga_drvdata = &f->driver;
	f->driver.scheduler[0] = &f->scheduler;
	f->driver.num_of_scheduler = 1;
	f->scheduler.ops = &fault_ops;
	f->scheduler.core = RGA3_SCHEDULER_CORE0;
	f->scheduler.dev = kunit_device_register(test, "rga-fault");
	if (IS_ERR(f->scheduler.dev))
		return PTR_ERR(f->scheduler.dev);
	mutex_init(&f->scheduler.job_mutex);
	spin_lock_init(&f->scheduler.irq_lock);
	spin_lock_init(&f->scheduler.dump.lock);
	media_recovery_init(&f->scheduler.recovery);
	media_fault_init(&f->scheduler.fault_limit);
	f->scheduler.running_job = &f->job;
	f->job.scheduler = &f->scheduler;
	f->job.session = &f->session;
	return 0;
}

#endif
