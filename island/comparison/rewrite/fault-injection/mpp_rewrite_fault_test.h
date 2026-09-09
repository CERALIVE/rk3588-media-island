/* SPDX-License-Identifier: GPL-2.0-only */

#include <kunit/device.h>
#include <linux/kthread.h>

struct rk_mpp_fault_fixture {
	struct rk_mpp_service srv;
	struct rk_mpp_hw hw;
	struct rk_mpp_job job;
	struct rk_mpp_session session;
	struct device dev;
	struct iommu_domain iommu;
	bool fault_work_ran;
};

static void rk_mpp_fault_observe_work(struct work_struct *work)
{
	struct rk_mpp_fault_fixture *f = container_of(work,
		struct rk_mpp_fault_fixture, hw.iommu_fault_work);

	f->fault_work_ran = true;
}

static void rk_mpp_fault_fixture_cleanup(void *data)
{
	struct rk_mpp_fault_fixture *f = data;

	rk_mpp_hw_cancel_timeout_sync(&f->hw);
	cancel_work_sync(&f->hw.iommu_fault_work);
	rk_mpp_activation_ref_put(&f->hw.active_ref);
	put_device(&f->dev);
}

static int rk_mpp_fault_fixture_init(struct kunit *test)
{
	struct rk_mpp_fault_fixture *f;
	int ret;

	f = kunit_kzalloc(test, sizeof(*f), GFP_KERNEL);
	if (!f)
		return -ENOMEM;
	test->priv = f;
	f->hw.regs[0] = (__force void __iomem *)kunit_kzalloc(test, PAGE_SIZE, GFP_KERNEL);
	if (!f->hw.regs[0])
		return -ENOMEM;
	rk_mpp_service_state_init(&f->srv);
	f->srv.debug_ready = false;
	f->hw.srv = &f->srv;
	f->hw.match = &rk_mpp_rkvenc2_core;
	f->hw.online = true;
	spin_lock_init(&f->hw.lock);
	raw_spin_lock_init(&f->hw.regs_lock);
	mutex_init(&f->hw.run_lock);
	INIT_DELAYED_WORK(&f->hw.timeout_work, rk_mpp_hw_timeout_work);
	INIT_WORK(&f->hw.iommu_fault_work, rk_mpp_fault_observe_work);
	INIT_LIST_HEAD(&f->hw.fault_link);
	device_initialize(&f->dev);
	f->dev.release = rk_mpp_kunit_device_release;
	f->dev.init_name = "rewrite-fault-fixture";
	f->hw.dev = &f->dev;
	refcount_set(&f->hw.refs, 1);
	refcount_set(&f->job.refs, 1);
	rk_mpp_activation_init(&f->job);
	f->job.current_activation->selected_hw = &f->hw;
	f->job.current_activation->slot_state = RK_MPP_ACTIVATION_SLOTTED;
	f->job.current_activation->generation = 7;
	/* Keep the real watchdog from expiring while fixture assertions run. */
	f->job.current_activation->watchdog_deadline_valid = true;
	f->job.current_activation->watchdog_deadline = jiffies + 60 * HZ;
	f->job.session = &f->session;
	f->job.client_type = RK_MPP_DEVICE_RKVENC;
	mutex_init(&f->session.lock);
	f->session.srv = &f->srv;
	f->session.opener_pid = 123;
	f->job.reg_builder.state = RK_MPP_REG_BUILDER_SEALED;
	f->hw.regs_live_count = 1;
	if (!rk_mpp_activation_ref_get(&f->hw.active_ref, f->job.current_activation)) {
		put_device(&f->dev);
		return -EINVAL;
	}
	ret = kunit_add_action_or_reset(test, rk_mpp_fault_fixture_cleanup, f);
	return ret;
}

static int rk_mpp_fault_start(struct rk_mpp_fault_fixture *f)
{
	int ret;

	mutex_lock(&f->hw.run_lock);
	ret = rk_mpp_rkvenc2_publish_and_start(&f->job, 7, 0x1234);
	mutex_unlock(&f->hw.run_lock);
	return ret;
}

static void rk_mpp_fault_hang_once_kunit(struct kunit *test)
{
	struct rk_mpp_fault_fixture *f = test->priv;
	void __iomem *start = f->hw.regs[0] + RK_MPP_RKVENC_START_BASE;

	atomic_set(&f->srv.fault.hang.armed, 1);
	atomic_set(&f->srv.fault.target_session_pid, 123);
	KUNIT_ASSERT_EQ(test, rk_mpp_fault_start(f), 0);
	KUNIT_EXPECT_EQ(test, readl(start), 0U);
	KUNIT_EXPECT_TRUE(test, delayed_work_pending(&f->hw.timeout_work));
	KUNIT_EXPECT_PTR_EQ(test, f->hw.timeout_ref.activation, f->job.current_activation);
	KUNIT_EXPECT_TRUE(test, f->hw.register_lease_live);
	KUNIT_EXPECT_EQ(test, f->hw.register_lease_generation, 7ULL);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.hang.consumed), 1);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.target_session_pid), 0);
	KUNIT_ASSERT_EQ(test, rk_mpp_fault_start(f), 0);
	KUNIT_EXPECT_EQ(test, readl(start), 0x1234U);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.hang.consumed), 1);
}

static void rk_mpp_fault_target_and_lease_kunit(struct kunit *test)
{
	struct rk_mpp_fault_fixture *f = test->priv;

	atomic_set(&f->srv.fault.hang.armed, 1);
	atomic_set(&f->srv.fault.target_session_pid, 456);
	KUNIT_ASSERT_EQ(test, rk_mpp_fault_start(f), 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.hang.armed), 1);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.hang.consumed), 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.target_session_pid), 456);
	f->session.opener_pid = 456;
	f->hw.regs_live_count = 0;
	KUNIT_EXPECT_EQ(test, rk_mpp_fault_start(f), -ENODEV);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.hang.armed), 1);
	KUNIT_EXPECT_PTR_EQ(test, f->hw.timeout_ref.activation, NULL);
	f->hw.regs_live_count = 1;
	KUNIT_ASSERT_EQ(test, rk_mpp_fault_start(f), 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.hang.consumed), 1);
}

static void rk_mpp_fault_iommu_once_kunit(struct kunit *test)
{
	struct rk_mpp_fault_fixture *f = test->priv;

	atomic_set(&f->srv.fault.iommu.armed, 1);
	atomic_set(&f->srv.fault.target_session_pid, 123);
	KUNIT_ASSERT_EQ(test, rk_mpp_fault_start(f), 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.iommu.consumed), 0);
	f->hw.iommu_domain = &f->iommu;
	f->hw.iommu_provider = RK_MPP_IOMMU_ROCKCHIP;
	f->hw.iommu_fault_handler_registered = true;
	list_add_tail(&f->hw.fault_link, &f->srv.fault_hws);
	f->session.opener_pid = 456;
	KUNIT_ASSERT_EQ(test, rk_mpp_fault_start(f), 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.iommu.armed), 1);
	f->session.opener_pid = 123;
	KUNIT_ASSERT_EQ(test, rk_mpp_fault_start(f), 0);
	flush_work(&f->hw.iommu_fault_work);
	KUNIT_EXPECT_TRUE(test, f->fault_work_ran);
	KUNIT_EXPECT_TRUE(test, f->hw.iommu_fault_pending);
	KUNIT_EXPECT_EQ(test, f->hw.iommu_fault_generation, 7ULL);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.iommu_fault_count), 1);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.iommu.consumed), 1);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.target_session_pid), 0);
	KUNIT_ASSERT_EQ(test, rk_mpp_fault_start(f), 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.iommu_fault_count), 1);
	KUNIT_EXPECT_EQ(test, readl(f->hw.regs[0] + RK_MPP_RKVENC_START_BASE), 0x1234U);
}

static void rk_mpp_fault_reset_after_pulse_kunit(struct kunit *test)
{
	struct rk_mpp_fault_fixture *f = test->priv;
	struct rk_mpp_reset_domain *domain;
	struct rk_mpp_kunit_reset_trace trace = { .fail_at = U32_MAX };
	int ret;

	domain = kunit_kzalloc(test, sizeof(*domain), GFP_KERNEL);
	KUNIT_ASSERT_NOT_NULL(test, domain);
	rk_mpp_reset_domain_init(domain, NULL);
	domain->backend_ops = &rk_mpp_kunit_reset_ops;
	domain->backend_data = &trace;
	f->hw.resets = (struct reset_control *)&f->hw.reset_pulse_active;
	INIT_LIST_HEAD(&f->hw.reset_domain_link);
	KUNIT_ASSERT_EQ(test, rk_mpp_reset_domain_register_member(domain, &f->hw), 0);
	atomic_set(&f->srv.fault.reset.armed, 1);
	mutex_lock(&f->hw.run_lock);
	ret = rk_mpp_reset_domain_recovery_pulse(&f->hw, NULL);
	mutex_unlock(&f->hw.run_lock);
	KUNIT_EXPECT_EQ(test, ret, -EIO);
	KUNIT_EXPECT_EQ(test, trace.count, 2U);
	KUNIT_EXPECT_FALSE(test, trace.deassert[0]);
	KUNIT_EXPECT_TRUE(test, trace.deassert[1]);
	KUNIT_EXPECT_EQ(test, domain->reset_domain_last_error, -EIO);
	KUNIT_EXPECT_EQ(test, domain->reset_domain_state, RK_MPP_RESET_DOMAIN_FAILED);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->hw.reset_pulse_active), 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.reset.consumed), 1);
	mutex_lock(&f->hw.run_lock);
	ret = rk_mpp_reset_domain_recovery_pulse(&f->hw, NULL);
	mutex_unlock(&f->hw.run_lock);
	KUNIT_EXPECT_EQ(test, ret, 0);
	KUNIT_EXPECT_EQ(test, trace.count, 4U);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.reset.consumed), 1);
	KUNIT_EXPECT_EQ(test, rk_mpp_reset_domain_unregister_member(&f->hw), 0);
}

struct rk_mpp_fault_retention {
	struct kunit *test;
	struct rk_mpp_job *job;
	struct rk_mpp_import *import;
	unsigned int calls;
};

static void rk_mpp_fault_teardown_during_wait(unsigned int ms, void *data)
{
	struct rk_mpp_fault_retention *hold = data;
	struct rk_mpp_session *session = hold->job->session;
	struct kunit *test = hold->test;

	hold->calls++;
	KUNIT_EXPECT_EQ(test, ms, 1000U);
	KUNIT_EXPECT_TRUE(test, list_empty(&hold->job->session_link));
	KUNIT_EXPECT_EQ(test, refcount_read(&hold->job->refs), 2);
	/* Re-enter real close/reset paths at the sleep boundary, without a timer race. */
	rk_mpp_session_abort_jobs(session, RK_MPP_TRANSITION_SESSION_CLOSE);
	KUNIT_EXPECT_EQ(test, rk_mpp_release_fd(session, 7), 0);
	KUNIT_EXPECT_EQ(test, session->active_job_count, 0U);
	KUNIT_EXPECT_EQ(test, refcount_read(&hold->job->refs), 2);
	KUNIT_EXPECT_EQ(test, refcount_read(&hold->import->refs), 2);
	KUNIT_EXPECT_FALSE(test, hold->job->canceled);
}

static void rk_mpp_fault_retained_completion_kunit(struct kunit *test)
{
	struct rk_mpp_fault_fixture *f = test->priv;
	struct rk_mpp_fault_retention hold = { .test = test, .job = &f->job };
	struct rk_mpp_import *import;
	struct rk_mpp_import *imports[1];

	import = kunit_kzalloc(test, sizeof(*import), GFP_KERNEL);
	KUNIT_ASSERT_NOT_NULL(test, import);
	hold.import = import;
	import->fd = 7;
	refcount_set(&import->refs, 3); /* session, job, fixture */
	INIT_LIST_HEAD(&import->link);
	mutex_init(&f->session.lock);
	mutex_init(&f->session.explicit_map_lock);
	init_waitqueue_head(&f->session.wait);
	INIT_LIST_HEAD(&f->session.active_jobs);
	INIT_LIST_HEAD(&f->session.imports);
	list_add_tail(&import->link, &f->session.imports);
	imports[0] = import;
	f->job.imports = imports;
	f->job.import_count = 1;
	rk_mpp_activation_ref_put(&f->hw.active_ref);
	refcount_set(&f->job.refs, 2); /* detached list ownership plus fixture */
	list_add_tail(&f->job.session_link, &f->session.active_jobs);
	f->session.active_job_count = 1;
	f->job.state = RK_MPP_JOB_DONE;
	f->srv.fault.wait = rk_mpp_fault_teardown_during_wait;
	f->srv.fault.wait_data = &hold;
	atomic_set(&f->srv.fault.delay.armed, 1000);
	KUNIT_EXPECT_EQ(test, rk_mpp_session_poll_job(&f->session, 0), 0);
	KUNIT_EXPECT_EQ(test, hold.calls, 1U);
	KUNIT_EXPECT_EQ(test, refcount_read(&f->job.refs), 1);
	KUNIT_EXPECT_EQ(test, refcount_read(&import->refs), 2);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.delay.armed), 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.delay.consumed), 1);
	rk_mpp_fault_completion_wait(&f->srv.fault);
	KUNIT_EXPECT_EQ(test, hold.calls, 1U);
	atomic_set(&f->srv.fault.delay.armed, -1);
	rk_mpp_fault_completion_wait(&f->srv.fault);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.delay.consumed), 1);
	f->job.imports = NULL;
	f->job.import_count = 0;
	rk_mpp_import_put(import);
}

/* These are the actual errno helpers called at the probe/client-init boundaries,
 * not emulated devm/OF/uaccess operations. Full probe rollback needs a board.
 */
static void rk_mpp_fault_service_attach_once_kunit(struct kunit *test)
{
	struct rk_mpp_fault_fixture *f = test->priv;

	atomic_set(&f->srv.fault.service_attach.armed, 1);
	KUNIT_EXPECT_EQ(test, rk_mpp_fault_service_attach(&f->srv.fault, false), 0);
	KUNIT_EXPECT_EQ(test, rk_mpp_fault_service_attach(&f->srv.fault, true), -ENOMEM);
	KUNIT_EXPECT_EQ(test, rk_mpp_fault_service_attach(&f->srv.fault, true), 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.service_attach.armed), 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.service_attach.consumed), 1);
}

static void rk_mpp_fault_ccu_attach_once_kunit(struct kunit *test)
{
	struct rk_mpp_fault_fixture *f = test->priv;

	atomic_set(&f->srv.fault.ccu_attach.armed, 1);
	mutex_lock(&f->srv.hw_lock);
	KUNIT_EXPECT_EQ(test, rk_mpp_fault_ccu_attach(&f->srv.fault, false), 0);
	KUNIT_EXPECT_EQ(test, rk_mpp_fault_ccu_attach(&f->srv.fault, true), -ENODEV);
	KUNIT_EXPECT_EQ(test, rk_mpp_fault_ccu_attach(&f->srv.fault, true), 0);
	mutex_unlock(&f->srv.hw_lock);
	KUNIT_EXPECT_PTR_EQ(test, f->hw.cluster, NULL);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.ccu_attach.armed), 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.ccu_attach.consumed), 1);
}

static void rk_mpp_fault_irq_request_once_kunit(struct kunit *test)
{
	struct rk_mpp_fault_fixture *f = test->priv;

	atomic_set(&f->srv.fault.irq_request.armed, 1);
	KUNIT_EXPECT_EQ(test, rk_mpp_fault_irq_request(&f->srv.fault, false), 0);
	KUNIT_EXPECT_EQ(test, rk_mpp_fault_irq_request(&f->srv.fault, true), -EBUSY);
	KUNIT_EXPECT_EQ(test, rk_mpp_fault_irq_request(&f->srv.fault, true), 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.irq_request.armed), 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.irq_request.consumed), 1);
}

static void rk_mpp_fault_session_alloc_once_kunit(struct kunit *test)
{
	struct rk_mpp_fault_fixture *f = test->priv;

	atomic_set(&f->srv.fault.session_alloc.armed, 1);
	mutex_lock(&f->session.lock);
	/* Repeated init / non-encoder requests must leave the shot for initial RKVENC. */
	KUNIT_EXPECT_EQ(test, rk_mpp_fault_session_alloc(&f->srv.fault, false), 0);
	KUNIT_EXPECT_EQ(test, rk_mpp_fault_session_alloc(&f->srv.fault, true), -ENOMEM);
	KUNIT_EXPECT_FALSE(test, f->session.initialized);
	KUNIT_EXPECT_EQ(test, rk_mpp_fault_session_alloc(&f->srv.fault, true), 0);
	mutex_unlock(&f->session.lock);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.session_alloc.armed), 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.session_alloc.consumed), 1);
}

static void rk_mpp_fault_clock_enable_once_kunit(struct kunit *test)
{
	struct rk_mpp_fault_fixture *f = test->priv;
	struct rk_mpp_reset_domain *domain;
	struct rk_mpp_kunit_reset_trace trace = { .fail_at = U32_MAX };
	int ret;

	domain = kunit_kzalloc(test, sizeof(*domain), GFP_KERNEL);
	KUNIT_ASSERT_NOT_NULL(test, domain);
	rk_mpp_reset_domain_init(domain, NULL);
	domain->backend_ops = &rk_mpp_kunit_reset_ops;
	domain->backend_data = &trace;
	INIT_LIST_HEAD(&f->hw.reset_domain_link);
	KUNIT_ASSERT_EQ(test, rk_mpp_reset_domain_register_member(domain, &f->hw), 0);
	pm_runtime_no_callbacks(&f->dev);
	KUNIT_ASSERT_EQ(test, pm_runtime_set_active(&f->dev), 0);
	pm_runtime_enable(&f->dev);
	f->hw.regs_live_count = 0;
	atomic_set(&f->srv.fault.clock_enable.armed, 1);
	mutex_lock(&f->hw.run_lock);
	ret = rk_mpp_hw_power_on(&f->hw);
	mutex_unlock(&f->hw.run_lock);
	KUNIT_EXPECT_EQ(test, ret, -EIO);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->dev.power.usage_count), 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->hw.power_count), 0);
	KUNIT_EXPECT_EQ(test, f->hw.regs_live_count, 0U);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.clock_enable.armed), 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.clock_enable.consumed), 1);
	/* Zero clocks is a real bulk-clock no-op, not a replacement PM implementation. */
	mutex_lock(&f->hw.run_lock);
	ret = rk_mpp_hw_power_on(&f->hw);
	if (!ret)
		rk_mpp_hw_power_off(&f->hw);
	mutex_unlock(&f->hw.run_lock);
	KUNIT_EXPECT_EQ(test, ret, 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.clock_enable.consumed), 1);
	pm_runtime_barrier(&f->dev);
	pm_runtime_disable(&f->dev);
	KUNIT_EXPECT_EQ(test, rk_mpp_reset_domain_unregister_member(&f->hw), 0);
}

static void rk_mpp_fault_target_zero_matches_any_kunit(struct kunit *test)
{
	struct rk_mpp_fault_fixture *f = test->priv;

	atomic_set(&f->srv.fault.hang.armed, 1);
	KUNIT_EXPECT_TRUE(test, rk_mpp_fault_targeted(&f->srv.fault, &f->srv.fault.hang, 4242));
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.hang.armed), 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.hang.consumed), 1);
}

static void rk_mpp_fault_target_matches_only_named_pid_kunit(struct kunit *test)
{
	struct rk_mpp_fault_fixture *f = test->priv;

	atomic_set(&f->srv.fault.hang.armed, 1);
	atomic_set(&f->srv.fault.target_session_pid, 100);
	KUNIT_EXPECT_FALSE(test, rk_mpp_fault_targeted(&f->srv.fault, &f->srv.fault.hang, 101));
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.hang.armed), 1);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.hang.consumed), 0);
	KUNIT_EXPECT_TRUE(test, rk_mpp_fault_targeted(&f->srv.fault, &f->srv.fault.hang, 100));
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.hang.consumed), 1);
}

static void rk_mpp_fault_target_clears_after_consume_kunit(struct kunit *test)
{
	struct rk_mpp_fault_fixture *f = test->priv;

	atomic_set(&f->srv.fault.hang.armed, 1);
	atomic_set(&f->srv.fault.target_session_pid, 100);
	KUNIT_EXPECT_TRUE(test, rk_mpp_fault_targeted(&f->srv.fault, &f->srv.fault.hang, 100));
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.target_session_pid), 0);
}

static void rk_mpp_fault_target_does_not_consume_unarmed_kunit(struct kunit *test)
{
	struct rk_mpp_fault_fixture *f = test->priv;

	atomic_set(&f->srv.fault.target_session_pid, 100);
	KUNIT_EXPECT_FALSE(test, rk_mpp_fault_targeted(&f->srv.fault, &f->srv.fault.hang, 100));
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.hang.consumed), 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.target_session_pid), 100);
}

static void rk_mpp_fault_target_written_concurrently_is_kept_kunit(struct kunit *test)
{
	struct rk_mpp_fault_fixture *f = test->priv;
	int observed;

	/* Step replay, not a live race: same proof boundary as production KUnit. */
	atomic_set(&f->srv.fault.hang.armed, 1);
	atomic_set(&f->srv.fault.target_session_pid, 100);
	observed = atomic_read(&f->srv.fault.target_session_pid);
	KUNIT_ASSERT_TRUE(test, rk_mpp_fault_consume(&f->srv.fault.hang));
	atomic_set(&f->srv.fault.target_session_pid, 200);
	KUNIT_EXPECT_EQ(test, atomic_cmpxchg(&f->srv.fault.target_session_pid, observed, 0), 200);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.target_session_pid), 200);
	atomic_set(&f->srv.fault.hang.armed, 1);
	KUNIT_EXPECT_TRUE(test, rk_mpp_fault_targeted(&f->srv.fault, &f->srv.fault.hang, 200));
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.target_session_pid), 0);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->srv.fault.hang.consumed), 2);
}

struct rk_mpp_idle_fixture {
	struct rk_mpp_fault_idle idle;
	struct rk_mpp_fault_knob knob;
	atomic_t target, calls, go, permit;
	struct device *dev;
	bool suspended_at_fire, rendezvous;
};

static void rk_mpp_idle_test_fire(struct rk_mpp_fault_idle *idle)
{
	struct rk_mpp_idle_fixture *f = container_of(idle, struct rk_mpp_idle_fixture, idle);

	if (f->dev)
		f->suspended_at_fire = rk_mpp_fault_idle_suspended(f->dev);
	atomic_inc(&f->calls);
}

static void rk_mpp_idle_test_cleanup(void *data)
{
	struct rk_mpp_idle_fixture *f = data;

	rk_mpp_fault_idle_disable(&f->idle);
}

static struct rk_mpp_idle_fixture *rk_mpp_idle_fixture(struct kunit *test)
{
	struct rk_mpp_idle_fixture *f = kunit_kzalloc(test, sizeof(*f), GFP_KERNEL);

	if (!f)
		return NULL;
	rk_mpp_fault_idle_init(&f->idle, rk_mpp_idle_test_fire);
	if (kunit_add_action_or_reset(test, rk_mpp_idle_test_cleanup, f))
		return NULL;
	return f;
}

static bool rk_mpp_idle_test_arm(struct rk_mpp_idle_fixture *f, pid_t pid)
{
	return rk_mpp_fault_idle_arm(&f->idle, &f->knob, &f->target, pid);
}

static void rk_mpp_fault_idle_delay_is_one_shot_kunit(struct kunit *test)
{
	struct rk_mpp_idle_fixture *f = rk_mpp_idle_fixture(test);
	struct device *dev = kunit_device_register(test, "rewrite-idle-pm");
	unsigned long flags;

	KUNIT_ASSERT_NOT_NULL(test, f);
	KUNIT_ASSERT_NOT_ERR_OR_NULL(test, dev);
	f->dev = dev;
	spin_lock_irqsave(&dev->power.lock, flags);
	dev->power.runtime_status = RPM_ACTIVE;
	spin_unlock_irqrestore(&dev->power.lock, flags);
	atomic_set(&f->knob.armed, 60000);
	atomic_set(&f->target, 100);
	KUNIT_EXPECT_FALSE(test, rk_mpp_idle_test_arm(f, 101));
	KUNIT_EXPECT_EQ(test, atomic_read(&f->knob.armed), 60000);
	KUNIT_ASSERT_TRUE(test, rk_mpp_idle_test_arm(f, 100));
	KUNIT_EXPECT_FALSE(test, rk_mpp_idle_test_arm(f, 100));
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
	dev->power.runtime_status = RPM_RESUMING;
	spin_unlock_irqrestore(&dev->power.lock, flags);
	atomic_set(&f->knob.armed, 60000);
	KUNIT_ASSERT_TRUE(test, rk_mpp_idle_test_arm(f, 100));
	flush_delayed_work(&f->idle.work);
	KUNIT_EXPECT_EQ(test, atomic_read(&f->calls), 2);
	KUNIT_EXPECT_FALSE(test, f->suspended_at_fire);
	spin_lock_irqsave(&dev->power.lock, flags);
	dev->power.runtime_status = RPM_SUSPENDED;
	spin_unlock_irqrestore(&dev->power.lock, flags);
}

static void rk_mpp_fault_idle_arm_refused_after_disable_kunit(struct kunit *test)
{
	struct rk_mpp_idle_fixture *f = rk_mpp_idle_fixture(test);

	KUNIT_ASSERT_NOT_NULL(test, f);
	rk_mpp_fault_idle_disable(&f->idle);
	atomic_set(&f->knob.armed, 60000);
	KUNIT_EXPECT_FALSE(test, rk_mpp_idle_test_arm(f, 100));
	KUNIT_EXPECT_FALSE(test, delayed_work_pending(&f->idle.work));
	KUNIT_EXPECT_EQ(test, atomic_read(&f->knob.consumed), 0);
}

static void rk_mpp_fault_idle_cancel_before_withdrawal_kunit(struct kunit *test)
{
	struct rk_mpp_idle_fixture *f = rk_mpp_idle_fixture(test);

	KUNIT_ASSERT_NOT_NULL(test, f);
	atomic_set(&f->knob.armed, 60000);
	KUNIT_ASSERT_TRUE(test, rk_mpp_idle_test_arm(f, 100));
	rk_mpp_fault_idle_disable(&f->idle);
	KUNIT_EXPECT_FALSE(test, delayed_work_pending(&f->idle.work));
	KUNIT_EXPECT_FALSE(test, flush_delayed_work(&f->idle.work));
	KUNIT_EXPECT_EQ(test, atomic_read(&f->calls), 0);
}

static void rk_mpp_idle_enqueue_rendezvous(struct rk_mpp_fault_idle *idle)
{
	struct rk_mpp_idle_fixture *f = container_of(idle, struct rk_mpp_idle_fixture, idle);
	unsigned int spins = 10000000;

	atomic_set_release(&f->go, 1);
	while (!atomic_read_acquire(&f->permit) && --spins)
		cpu_relax();
	f->rendezvous = spins != 0;
}

static int rk_mpp_idle_disabler(void *data)
{
	struct rk_mpp_idle_fixture *f = data;
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
	rk_mpp_fault_idle_disable(&f->idle);
	if (unlocked)
		atomic_set_release(&f->permit, 1);
	return 0;
}

static void rk_mpp_fault_idle_enqueue_races_disable_kunit(struct kunit *test)
{
	struct rk_mpp_idle_fixture *f;
	struct task_struct *disabler;
	cpumask_t saved;
	int producer_cpu, consumer_cpu, ret;

	if (num_online_cpus() < 2) {
		kunit_skip(test, "forced interleaving requires two online CPUs");
		return;
	}
	f = rk_mpp_idle_fixture(test);
	KUNIT_ASSERT_NOT_NULL(test, f);
	cpumask_copy(&saved, current->cpus_ptr);
	producer_cpu = cpumask_first(cpu_online_mask);
	consumer_cpu = cpumask_next(producer_cpu, cpu_online_mask);
	disabler = kthread_create(rk_mpp_idle_disabler, f, "rewrite-idle-disable");
	KUNIT_ASSERT_FALSE(test, IS_ERR(disabler));
	kthread_bind(disabler, consumer_cpu);
	ret = set_cpus_allowed_ptr(current, cpumask_of(producer_cpu));
	if (ret) {
		kthread_stop(disabler);
		KUNIT_FAIL(test, "cannot pin producer: %d", ret);
		return;
	}
	f->idle.before_enqueue = rk_mpp_idle_enqueue_rendezvous;
	atomic_set(&f->knob.armed, 60000);
	wake_up_process(disabler);
	KUNIT_EXPECT_TRUE(test, rk_mpp_idle_test_arm(f, 100));
	kthread_stop(disabler);
	KUNIT_EXPECT_TRUE_MSG(test, f->rendezvous, "interleaving not forced");
	KUNIT_EXPECT_FALSE(test, delayed_work_pending(&f->idle.work));
	KUNIT_EXPECT_EQ(test, atomic_read(&f->calls), 0);
	KUNIT_EXPECT_EQ(test, set_cpus_allowed_ptr(current, &saved), 0);
}

static struct kunit_case rk_mpp_fault_test_cases[] = {
	KUNIT_CASE(rk_mpp_fault_idle_delay_is_one_shot_kunit),
	KUNIT_CASE(rk_mpp_fault_idle_arm_refused_after_disable_kunit),
	KUNIT_CASE(rk_mpp_fault_idle_cancel_before_withdrawal_kunit),
	KUNIT_CASE(rk_mpp_fault_idle_enqueue_races_disable_kunit),
	KUNIT_CASE(rk_mpp_fault_service_attach_once_kunit),
	KUNIT_CASE(rk_mpp_fault_ccu_attach_once_kunit),
	KUNIT_CASE(rk_mpp_fault_irq_request_once_kunit),
	KUNIT_CASE(rk_mpp_fault_clock_enable_once_kunit),
	KUNIT_CASE(rk_mpp_fault_session_alloc_once_kunit),
	KUNIT_CASE(rk_mpp_fault_target_zero_matches_any_kunit),
	KUNIT_CASE(rk_mpp_fault_target_matches_only_named_pid_kunit),
	KUNIT_CASE(rk_mpp_fault_target_clears_after_consume_kunit),
	KUNIT_CASE(rk_mpp_fault_target_does_not_consume_unarmed_kunit),
	KUNIT_CASE(rk_mpp_fault_target_written_concurrently_is_kept_kunit),
	KUNIT_CASE(rk_mpp_fault_hang_once_kunit),
	KUNIT_CASE(rk_mpp_fault_target_and_lease_kunit),
	KUNIT_CASE(rk_mpp_fault_iommu_once_kunit),
	KUNIT_CASE(rk_mpp_fault_reset_after_pulse_kunit),
	KUNIT_CASE(rk_mpp_fault_retained_completion_kunit),
	{}
};

static struct kunit_suite rk_mpp_fault_test_suite = {
	.name = "rk-mpp-rewrite-fault",
	.init = rk_mpp_fault_fixture_init,
	.test_cases = rk_mpp_fault_test_cases,
};

kunit_test_suite(rk_mpp_fault_test_suite);
