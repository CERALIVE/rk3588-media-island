// SPDX-License-Identifier: GPL-2.0
#include <kunit/test.h>
#include <kunit/device.h>
#include <linux/sysfs.h>
#include <linux/kthread.h>
#include <linux/delay.h>
#include "../mpp/mpp_rkvenc_test.h"
#include "../mpp/media_fault.h"
#include "../mpp/media_dump.h"
#include "../mpp/media_probe.h"
#include "../../../base/base.h"

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

static void mpp_fault_target_zero_matches_any_test(struct kunit *test)
{
	struct mpp_fault_knob knob = {
		.armed = ATOMIC_INIT(1),
		.consumed = ATOMIC_INIT(0),
	};
	atomic_t target = ATOMIC_INIT(0);

	KUNIT_EXPECT_TRUE(test, mpp_fault_consume_targeted(&knob, &target, 4242));
	KUNIT_EXPECT_EQ(test, atomic_read(&knob.consumed), 1);
	KUNIT_EXPECT_EQ(test, atomic_read(&knob.armed), 0);
}

static void mpp_fault_target_matches_only_named_pid_test(struct kunit *test)
{
	struct mpp_fault_knob knob = {
		.armed = ATOMIC_INIT(1),
		.consumed = ATOMIC_INIT(0),
	};
	atomic_t target = ATOMIC_INIT(100);

	KUNIT_EXPECT_FALSE(test, mpp_fault_consume_targeted(&knob, &target, 101));
	KUNIT_EXPECT_EQ(test, atomic_read(&knob.armed), 1);
	KUNIT_EXPECT_EQ(test, atomic_read(&knob.consumed), 0);

	KUNIT_EXPECT_TRUE(test, mpp_fault_consume_targeted(&knob, &target, 100));
	KUNIT_EXPECT_EQ(test, atomic_read(&knob.consumed), 1);
}

static void mpp_fault_target_clears_after_consume_test(struct kunit *test)
{
	struct mpp_fault_knob knob = {
		.armed = ATOMIC_INIT(1),
		.consumed = ATOMIC_INIT(0),
	};
	atomic_t target = ATOMIC_INIT(100);

	KUNIT_EXPECT_TRUE(test, mpp_fault_consume_targeted(&knob, &target, 100));
	KUNIT_EXPECT_EQ(test, atomic_read(&target), 0);
}

static void mpp_fault_target_does_not_consume_unarmed_test(struct kunit *test)
{
	struct mpp_fault_knob knob = {
		.armed = ATOMIC_INIT(0),
		.consumed = ATOMIC_INIT(0),
	};
	atomic_t target = ATOMIC_INIT(100);

	KUNIT_EXPECT_FALSE(test, mpp_fault_consume_targeted(&knob, &target, 100));
	KUNIT_EXPECT_EQ(test, atomic_read(&knob.consumed), 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&target), 100);
}

static void mpp_fault_target_written_concurrently_is_kept_test(struct kunit *test)
{
	struct mpp_fault_knob knob = {
		.armed = ATOMIC_INIT(1),
		.consumed = ATOMIC_INIT(0),
	};
	atomic_t target = ATOMIC_INIT(100);
	int observed;

	/*
	 * mpp_fault_consume_targeted() is three uninterruptible steps with no
	 * interposition point, so the racing write is replayed between them
	 * here rather than driven from a second thread that could not be made
	 * to land inside the window deterministically.
	 */
	observed = atomic_read(&target);
	KUNIT_ASSERT_EQ(test, observed, 100);
	KUNIT_ASSERT_TRUE(test, mpp_fault_consume_flag(&knob));
	atomic_set(&target, 200);
	KUNIT_EXPECT_EQ(test, atomic_cmpxchg(&target, observed, 0), 200);
	KUNIT_EXPECT_EQ(test, atomic_read(&target), 200);

	/* Unraced, the same helper still clears the selector it observed. */
	atomic_set(&knob.armed, 1);
	KUNIT_EXPECT_TRUE(test, mpp_fault_consume_targeted(&knob, &target, 200));
	KUNIT_EXPECT_EQ(test, atomic_read(&target), 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&knob.consumed), 2);
}

struct mpp_idle_fixture {
	struct mpp_fault_idle idle;
	struct mpp_fault_knob knob;
	atomic_t target;
	atomic_t calls;
	struct device *dev;
	bool suspended_at_fire;
	atomic_t go;
	atomic_t permit;
	bool rendezvous;
};

static void mpp_idle_test_fire(struct mpp_fault_idle *idle)
{
	struct mpp_idle_fixture *f = container_of(idle, struct mpp_idle_fixture, idle);

	if (f->dev)
		f->suspended_at_fire = mpp_fault_idle_suspended(f->dev);
	atomic_inc(&f->calls);
}

static void mpp_idle_test_cleanup(void *data)
{
	struct mpp_idle_fixture *f = data;

	mpp_fault_idle_disable(&f->idle);
}

static struct mpp_idle_fixture *mpp_idle_fixture(struct kunit *test)
{
	struct mpp_idle_fixture *f = kunit_kzalloc(test, sizeof(*f), GFP_KERNEL);

	if (!f)
		return NULL;
	mpp_fault_idle_init(&f->idle, mpp_idle_test_fire);
	if (kunit_add_action_or_reset(test, mpp_idle_test_cleanup, f))
		return NULL;
	return f;
}

static void mpp_fault_idle_delay_is_one_shot_test(struct kunit *test)
{
	struct mpp_idle_fixture *f = mpp_idle_fixture(test);
	struct device *dev = kunit_device_register(test, "idle-pm-kunit");
	unsigned long flags;

	KUNIT_ASSERT_NOT_NULL(test, f);
	KUNIT_ASSERT_NOT_ERR_OR_NULL(test, dev);
	f->dev = dev;
	spin_lock_irqsave(&dev->power.lock, flags);
	dev->power.runtime_status = RPM_ACTIVE;
	spin_unlock_irqrestore(&dev->power.lock, flags);
	atomic_set(&f->knob.armed, 60000);
	atomic_set(&f->target, 100);
	KUNIT_EXPECT_FALSE(test, mpp_fault_idle_arm(&f->idle, &f->knob,
						 &f->target, 101));
	KUNIT_EXPECT_EQ(test, atomic_read(&f->knob.armed), 60000);
	KUNIT_ASSERT_TRUE(test, mpp_fault_idle_arm(&f->idle, &f->knob,
						&f->target, 100));
	KUNIT_EXPECT_FALSE(test, mpp_fault_idle_arm(&f->idle, &f->knob,
						 &f->target, 100));
	KUNIT_EXPECT_EQ(test, atomic_read(&f->knob.consumed), 1);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->knob.armed), 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->target), 0);
	spin_lock_irqsave(&dev->power.lock, flags);
	dev->power.runtime_status = RPM_SUSPENDED;
	spin_unlock_irqrestore(&dev->power.lock, flags);
	flush_delayed_work(&f->idle.work);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->calls), 1);
	KUNIT_EXPECT_TRUE(test, f->suspended_at_fire);
	flush_delayed_work(&f->idle.work);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->calls), 1);

	spin_lock_irqsave(&dev->power.lock, flags);
	dev->power.runtime_status = RPM_SUSPENDED;
	spin_unlock_irqrestore(&dev->power.lock, flags);
	KUNIT_EXPECT_TRUE(test, mpp_fault_idle_suspended(dev));
	spin_lock_irqsave(&dev->power.lock, flags);
	dev->power.runtime_status = RPM_RESUMING;
	spin_unlock_irqrestore(&dev->power.lock, flags);
	KUNIT_EXPECT_FALSE(test, mpp_fault_idle_suspended(dev));
	atomic_set(&f->knob.armed, 60000);
	KUNIT_ASSERT_TRUE(test, mpp_fault_idle_arm(&f->idle, &f->knob,
						&f->target, 100));
	flush_delayed_work(&f->idle.work);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->calls), 2);
	KUNIT_EXPECT_FALSE(test, f->suspended_at_fire);
	spin_lock_irqsave(&dev->power.lock, flags);
	dev->power.runtime_status = RPM_SUSPENDED;
	spin_unlock_irqrestore(&dev->power.lock, flags);
}

static void mpp_fault_idle_arm_refused_after_disable_test(struct kunit *test)
{
	struct mpp_idle_fixture *f = mpp_idle_fixture(test);

	KUNIT_ASSERT_NOT_NULL(test, f);
	mpp_fault_idle_disable(&f->idle);
	atomic_set(&f->knob.armed, 60000);
	KUNIT_EXPECT_FALSE(test, mpp_fault_idle_arm(&f->idle, &f->knob,
						 &f->target, 100));
	KUNIT_EXPECT_FALSE(test, delayed_work_pending(&f->idle.work));
	KUNIT_EXPECT_EQ(test, atomic_read(&f->knob.consumed), 0);
}

static void mpp_fault_idle_cancel_before_withdrawal_test(struct kunit *test)
{
	struct mpp_idle_fixture *f = mpp_idle_fixture(test);

	KUNIT_ASSERT_NOT_NULL(test, f);
	atomic_set(&f->knob.armed, 60000);
	KUNIT_ASSERT_TRUE(test, mpp_fault_idle_arm(&f->idle, &f->knob,
						&f->target, 100));
	mpp_fault_idle_disable(&f->idle);
	KUNIT_EXPECT_FALSE(test, delayed_work_pending(&f->idle.work));
	KUNIT_EXPECT_FALSE(test, flush_delayed_work(&f->idle.work));
	KUNIT_EXPECT_EQ(test, atomic_read(&f->calls), 0);
}

static void mpp_idle_enqueue_rendezvous(struct mpp_fault_idle *idle)
{
	struct mpp_idle_fixture *f = container_of(idle, struct mpp_idle_fixture, idle);
	unsigned int spins = 10000000;

	atomic_set_release(&f->go, 1);
	while (!atomic_read_acquire(&f->permit) && --spins)
		cpu_relax();
	f->rendezvous = spins != 0;
}

static int mpp_idle_disabler(void *data)
{
	struct mpp_idle_fixture *f = data;
	bool unlocked;

	while (!atomic_read_acquire(&f->go)) {
		if (kthread_should_stop())
			return 0;
		usleep_range(50, 100);
	}
	unlocked = spin_trylock(&f->idle.fault_idle_lock);
	if (unlocked)
		spin_unlock(&f->idle.fault_idle_lock);
	else
		atomic_set_release(&f->permit, 1);
	mpp_fault_idle_disable(&f->idle);
	if (unlocked)
		atomic_set_release(&f->permit, 1);
	return 0;
}

static void mpp_fault_idle_enqueue_races_disable_test(struct kunit *test)
{
	struct mpp_idle_fixture *f;
	struct task_struct *disabler;
	cpumask_t saved;
	int producer_cpu, consumer_cpu, ret;

	if (num_online_cpus() < 2) {
		kunit_skip(test, "forced interleaving requires two online CPUs");
		return;
	}
	f = mpp_idle_fixture(test);
	KUNIT_ASSERT_NOT_NULL(test, f);
	cpumask_copy(&saved, current->cpus_ptr);
	producer_cpu = cpumask_first(cpu_online_mask);
	consumer_cpu = cpumask_next(producer_cpu, cpu_online_mask);
	disabler = kthread_create(mpp_idle_disabler, f, "idle-fault-disable");
	KUNIT_ASSERT_FALSE(test, IS_ERR(disabler));
	kthread_bind(disabler, consumer_cpu);
	ret = set_cpus_allowed_ptr(current, cpumask_of(producer_cpu));
	if (ret) {
		kthread_stop(disabler);
		KUNIT_FAIL(test, "cannot pin producer: %d", ret);
		return;
	}
	f->idle.before_enqueue = mpp_idle_enqueue_rendezvous;
	atomic_set(&f->knob.armed, 60000);
	wake_up_process(disabler);
	KUNIT_EXPECT_TRUE(test, mpp_fault_idle_arm(&f->idle, &f->knob,
						&f->target, 100));
	kthread_stop(disabler);
	KUNIT_EXPECT_TRUE_MSG(test, f->rendezvous, "interleaving not forced");
	KUNIT_EXPECT_FALSE(test, delayed_work_pending(&f->idle.work));
	KUNIT_EXPECT_EQ(test, atomic_read(&f->calls), 0);
	KUNIT_EXPECT_EQ(test, set_cpus_allowed_ptr(current, &saved), 0);
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

static void media_dump_submission_owns_buffer_test(struct kunit *test)
{
	struct device *dev = kunit_device_register(test, "media-dump-kunit");
	struct media_dump_record record = { .task = 42, .core = 2 };
	struct kernfs_node *link;
	void *owned;
	size_t len;

	KUNIT_ASSERT_NOT_ERR_OR_NULL(test, dev);
	owned = vzalloc(MEDIA_DUMP_BYTES);
	KUNIT_ASSERT_NOT_NULL(test, owned);
	len = media_dump_format(owned, &record);
	KUNIT_EXPECT_LT(test, len, (size_t)MEDIA_DUMP_BYTES);
	KUNIT_EXPECT_NOT_NULL(test, strstr(owned, "task=42 core=2"));
	media_dump_submit(dev, &owned, len);
	KUNIT_EXPECT_PTR_EQ(test, owned, NULL);
	link = sysfs_get_dirent(dev->kobj.sd, "devcoredump");
	KUNIT_EXPECT_NOT_NULL(test, link);
	if (link)
		sysfs_put(link);
	dev_coredump_put(dev);
}

static void media_probe_names_deferred_resource_test(struct kunit *test)
{
	struct device *dev = kunit_device_register(test, "media-probe-kunit");

	KUNIT_ASSERT_NOT_ERR_OR_NULL(test, dev);
	KUNIT_EXPECT_EQ(test, media_probe_error(dev, -EPROBE_DEFER, "iommus provider"),
			-EPROBE_DEFER);
	KUNIT_ASSERT_NOT_NULL(test, dev->p->deferred_probe_reason);
	KUNIT_EXPECT_NOT_NULL(test, strstr(dev->p->deferred_probe_reason, "iommus provider"));
	KUNIT_EXPECT_EQ(test, media_probe_error(dev, -EPROBE_DEFER, "aclk_vcodec"),
			-EPROBE_DEFER);
	KUNIT_EXPECT_NOT_NULL(test, strstr(dev->p->deferred_probe_reason, "aclk_vcodec"));
}

static struct kunit_case mpp_fault_injection_cases[] = {
	KUNIT_CASE(media_probe_names_deferred_resource_test),
	KUNIT_CASE(media_dump_submission_owns_buffer_test),
	KUNIT_CASE(media_fault_storm_test),
	KUNIT_CASE(mpp_fault_flag_is_one_shot_test),
	KUNIT_CASE(mpp_fault_delay_is_one_shot_test),
	KUNIT_CASE(mpp_fault_target_zero_matches_any_test),
	KUNIT_CASE(mpp_fault_target_matches_only_named_pid_test),
	KUNIT_CASE(mpp_fault_target_clears_after_consume_test),
	KUNIT_CASE(mpp_fault_target_does_not_consume_unarmed_test),
	KUNIT_CASE(mpp_fault_target_written_concurrently_is_kept_test),
	KUNIT_CASE(mpp_fault_idle_delay_is_one_shot_test),
	KUNIT_CASE(mpp_fault_idle_arm_refused_after_disable_test),
	KUNIT_CASE(mpp_fault_idle_cancel_before_withdrawal_test),
	KUNIT_CASE(mpp_fault_idle_enqueue_races_disable_test),
	{}
};

static struct kunit_suite mpp_fault_injection_suite = {
	.name = "rockchip-mpp-fault-injection",
	.test_cases = mpp_fault_injection_cases,
};

kunit_test_suite(mpp_fault_injection_suite);

MODULE_LICENSE("GPL");
