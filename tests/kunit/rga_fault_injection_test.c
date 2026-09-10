// SPDX-License-Identifier: GPL-2.0-only
#include "rga_fault_fixture.h"

static void rga_fault_controls_one_shot_test(struct kunit *test)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(fault_controls); i++) {
		struct rga_fault_knob *knob = fault_controls[i].knob;

		KUNIT_EXPECT_FALSE(test, fault_controls[i].consume());
		atomic_set(&knob->armed, 1);
		KUNIT_EXPECT_TRUE(test, fault_controls[i].consume());
		KUNIT_EXPECT_FALSE(test, fault_controls[i].consume());
		KUNIT_EXPECT_EQ(test, atomic_read(&knob->armed), 0);
		KUNIT_EXPECT_EQ(test, atomic_read(&knob->consumed), 1);
		atomic_set(&knob->armed, 1);
		KUNIT_EXPECT_TRUE(test, fault_controls[i].consume());
		KUNIT_EXPECT_EQ(test, atomic_read(&knob->consumed), 2);
	}
}

static void rga_fault_invalid_values_stay_unconsumed_test(struct kunit *test)
{
	const int values[] = { 0, -1, 2, INT_MAX, INT_MIN };
	int i;

	for (i = 0; i < ARRAY_SIZE(values); i++) {
		struct rga_fault_knob knob = { .armed = ATOMIC_INIT(values[i]) };

		KUNIT_EXPECT_FALSE(test, rga_fault_consume_flag(&knob));
		KUNIT_EXPECT_EQ(test, atomic_read(&knob.armed), values[i]);
		KUNIT_EXPECT_EQ(test, atomic_read(&knob.consumed), 0);
	}
}

struct rga_fault_race {
	struct rga_fault_knob knob;
	struct completion go;
	struct completion done;
	atomic_t winners;
};

static int rga_fault_contender(void *data)
{
	struct rga_fault_race *race = data;

	wait_for_completion(&race->go);
	if (rga_fault_consume_flag(&race->knob))
		atomic_inc(&race->winners);
	complete(&race->done);
	return 0;
}

static void rga_fault_concurrent_consume_test(struct kunit *test)
{
	struct rga_fault_race race = { .knob.armed = ATOMIC_INIT(1) };
	struct task_struct *tasks[8];
	int i, count = 0;

	init_completion(&race.go);
	init_completion(&race.done);
	for (i = 0; i < ARRAY_SIZE(tasks); i++) {
		tasks[i] = kthread_run(rga_fault_contender, &race, "rga-fault-race");
		if (IS_ERR(tasks[i]))
			break;
		get_task_struct(tasks[i]);
		count++;
	}
	complete_all(&race.go);
	for (i = 0; i < count; i++)
		wait_for_completion(&race.done);
	for (i = 0; i < count; i++) {
		kthread_stop(tasks[i]);
		put_task_struct(tasks[i]);
	}
	KUNIT_ASSERT_EQ(test, count, (int)ARRAY_SIZE(tasks));
	KUNIT_EXPECT_EQ(test, atomic_read(&race.winners), 1);
	KUNIT_EXPECT_EQ(test, atomic_read(&race.knob.consumed), 1);
	KUNIT_EXPECT_EQ(test, atomic_read(&race.knob.armed), 0);
}

static void fault_debugfs_cleanup(void *unused)
{
	rga_test_exit();
}

static void rga_fault_debugfs_modes_test(struct kunit *test)
{
	int i;

	KUNIT_ASSERT_EQ(test, rga_test_init(), 0);
	KUNIT_ASSERT_EQ(test, kunit_add_action_or_reset(test, fault_debugfs_cleanup, NULL), 0);
	for (i = 0; i < ARRAY_SIZE(fault_controls); i++) {
		char name[64];
		struct dentry *entry = debugfs_lookup(fault_controls[i].name, rga_test_dir);

		KUNIT_ASSERT_NOT_ERR_OR_NULL(test, entry);
		KUNIT_EXPECT_EQ(test, d_inode(entry)->i_mode & 0777, 0600);
		KUNIT_EXPECT_PTR_EQ(test, d_inode(entry)->i_private, &fault_controls[i].knob->armed);
		dput(entry);
		snprintf(name, sizeof(name), "%s_consumed", fault_controls[i].name);
		entry = debugfs_lookup(name, rga_test_dir);
		KUNIT_ASSERT_NOT_ERR_OR_NULL(test, entry);
		KUNIT_EXPECT_EQ(test, d_inode(entry)->i_mode & 0777, 0400);
		KUNIT_EXPECT_PTR_EQ(test, d_inode(entry)->i_private, &fault_controls[i].knob->consumed);
		dput(entry);
	}
}

static void rga_fault_timeout_recovery_test(struct kunit *test)
{
	struct rga_fault_fixture *f = test->priv;
	int i;

	for (i = 0; i < 2; i++) {
		f->scheduler.running_job = &f->job;
		f->job.state = 0;
		atomic_set(&fault_controls[i].knob->armed, 1);
		KUNIT_ASSERT_EQ(test, rga_job_run(&f->job, &f->scheduler), 0);
		KUNIT_EXPECT_EQ(test, f->starts, 0);
		KUNIT_EXPECT_GT(test, f->job.timestamp.hw_execute, (ktime_t)0);
		KUNIT_EXPECT_EQ(test, f->power_refs, 1);
		f->job.timestamp.hw_execute = ktime_sub_ms(ktime_get(), RGA_JOB_TIMEOUT_DELAY + 1);
		rga_job_scheduler_timeout_clean(&f->scheduler);
		rga_job_scheduler_timeout_clean(&f->scheduler);
		KUNIT_EXPECT_PTR_EQ(test, f->scheduler.running_job, NULL);
		KUNIT_EXPECT_EQ(test, f->job.ret, -EBUSY);
		KUNIT_EXPECT_EQ(test, f->power_refs, 0);
		KUNIT_EXPECT_EQ(test, f->resets, i + 1);
		KUNIT_EXPECT_EQ(test, f->signals, i + 1);
		KUNIT_EXPECT_EQ(test, f->unmaps, i + 1);
		KUNIT_EXPECT_EQ(test, atomic_read(&fault_controls[i].knob->consumed), 1);
	}
	KUNIT_EXPECT_EQ(test, rga_job_run(&f->job, &f->scheduler), 0);
	KUNIT_EXPECT_EQ(test, f->starts, 1);
}

static void rga_fault_failed_power_keeps_shot_test(struct kunit *test)
{
	struct rga_fault_fixture *f = test->priv;

	f->power_error = -EIO;
	atomic_set(&hang_task.armed, 1);
	KUNIT_EXPECT_EQ(test, rga_job_run(&f->job, &f->scheduler), -EIO);
	KUNIT_EXPECT_EQ(test, atomic_read(&hang_task.armed), 1);
	KUNIT_EXPECT_EQ(test, atomic_read(&hang_task.consumed), 0);
	KUNIT_EXPECT_EQ(test, f->starts, 0);
	KUNIT_EXPECT_EQ(test, f->power_refs, 0);
}

static void rga_fault_iommu_callback_test(struct kunit *test)
{
	struct rga_fault_fixture *f = test->priv;

	atomic_set(&inject_iommu_fault.armed, 1);
	KUNIT_EXPECT_FALSE(test, rga_iommu_test_prepare(&f->scheduler));
	f->scheduler.iommu_info = &f->iommu;
	KUNIT_EXPECT_FALSE(test, rga_iommu_test_prepare(&f->scheduler));
	KUNIT_EXPECT_EQ(test, atomic_read(&inject_iommu_fault.armed), 1);
	f->iommu.rockchip_fault_handler = true;
	KUNIT_EXPECT_EQ(test, rga_job_run(&f->job, &f->scheduler), -EACCES);
	KUNIT_EXPECT_EQ(test, f->starts, 0);
	KUNIT_EXPECT_EQ(test, f->irqs, 1);
	KUNIT_EXPECT_EQ(test, f->resets, 1);
	KUNIT_EXPECT_TRUE(test, test_bit(RGA_JOB_STATE_INTR_ERR, &f->job.state));
	KUNIT_EXPECT_EQ(test, f->power_refs, 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&inject_iommu_fault.consumed), 1);
	KUNIT_EXPECT_FALSE(test, rga_iommu_test_prepare(&f->scheduler));
}

static void rga_fault_reset_write_result_test(struct kunit *test)
{
	struct rga_fault_fixture *f = test->priv;
	const char __user *core = (const char __user *)"1\n";

	atomic_set(&fail_reset.armed, 1);
	KUNIT_EXPECT_EQ(test, rga_reset_write(NULL, core, 0, NULL), (ssize_t)-EINVAL);
	f->copy_fault = true;
	KUNIT_EXPECT_EQ(test, rga_reset_write(NULL, core, 2, NULL), (ssize_t)-EFAULT);
	f->copy_fault = false;
	KUNIT_EXPECT_EQ(test, f->aborts, 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&fail_reset.consumed), 0);
	KUNIT_EXPECT_EQ(test, rga_reset_write(NULL, core, 2, NULL), (ssize_t)-EIO);
	KUNIT_EXPECT_EQ(test, f->aborts, 1);
	KUNIT_EXPECT_EQ(test, atomic_read(&fail_reset.consumed), 1);
	KUNIT_EXPECT_EQ(test, rga_reset_write(NULL, core, 2, NULL), (ssize_t)2);
	KUNIT_EXPECT_EQ(test, f->aborts, 2);
}

static struct kunit_case rga_fault_cases[] = {
	KUNIT_CASE(rga_fault_controls_one_shot_test),
	KUNIT_CASE(rga_fault_invalid_values_stay_unconsumed_test),
	KUNIT_CASE(rga_fault_concurrent_consume_test),
	KUNIT_CASE(rga_fault_debugfs_modes_test),
	KUNIT_CASE(rga_fault_timeout_recovery_test),
	KUNIT_CASE(rga_fault_failed_power_keeps_shot_test),
	KUNIT_CASE(rga_fault_iommu_callback_test),
	KUNIT_CASE(rga_fault_reset_write_result_test),
	{}
};

static struct kunit_suite rga_fault_suite = {
	.name = "rockchip-rga-fault-injection",
	.init = rga_fault_init,
	.test_cases = rga_fault_cases,
};
kunit_test_suite(rga_fault_suite);
MODULE_LICENSE("GPL");
