/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef RK_MPP_REWRITE_FAULT_H
#define RK_MPP_REWRITE_FAULT_H

#include <linux/atomic.h>
#include <linux/debugfs.h>
#include <linux/delay.h>
#include <linux/err.h>
#include <linux/pm_runtime.h>
#include <linux/seq_file.h>
#include <linux/workqueue.h>

#if IS_ENABLED(CONFIG_ROCKCHIP_MPP_CERALIVE_TEST) && IS_ENABLED(CONFIG_ROCKCHIP_MPP_REWRITE_FAULT_INJECTION)
#error "both fault seams share /sys/kernel/debug/rkvenc-test"
#endif

struct rk_mpp_fault_knob {
	atomic_t armed;
	atomic_t consumed;
};

/* Per-service storage keeps KUnit fixtures separate from the live instance. */
struct rk_mpp_fault_controls {
	struct rk_mpp_fault_knob service_attach;
	struct rk_mpp_fault_knob ccu_attach;
	struct rk_mpp_fault_knob irq_request;
	struct rk_mpp_fault_knob clock_enable;
	struct rk_mpp_fault_knob session_alloc;
	struct rk_mpp_fault_knob hang;
	struct rk_mpp_fault_knob iommu;
	struct rk_mpp_fault_knob reset;
	struct rk_mpp_fault_knob delay;
	struct rk_mpp_fault_knob idle;
	atomic_t idle_fired;
	atomic_t idle_state;
	atomic_t target_session_pid;
	struct dentry *root;
	struct dentry *sessions;
#if IS_ENABLED(CONFIG_ROCKCHIP_MPP_REWRITE_KUNIT_TEST)
	void (*wait)(unsigned int ms, void *data);
	void *wait_data;
#endif
};

static inline bool rk_mpp_fault_consume(struct rk_mpp_fault_knob *knob)
{
	if (!IS_ENABLED(CONFIG_ROCKCHIP_MPP_REWRITE_FAULT_INJECTION))
		return false;
	if (atomic_cmpxchg(&knob->armed, 1, 0) != 1)
		return false;
	atomic_inc(&knob->consumed);
	return true;
}

struct rk_mpp_fault_idle {
	void *owner;
	struct delayed_work work;
	spinlock_t fault_idle_lock;
	bool arming_enabled;
	void (*fire)(struct rk_mpp_fault_idle *idle);
#if IS_ENABLED(CONFIG_KUNIT)
	void (*before_enqueue)(struct rk_mpp_fault_idle *idle);
#endif
};

static inline unsigned int rk_mpp_fault_consume_delay(struct rk_mpp_fault_knob *knob)
{
	int delay_ms = atomic_xchg(&knob->armed, 0);

	if (delay_ms <= 0)
		return 0;
	atomic_inc(&knob->consumed);
	return delay_ms;
}

static inline bool rk_mpp_fault_idle_suspended(struct device *dev)
{
	unsigned long flags;
	bool suspended;

	spin_lock_irqsave(&dev->power.lock, flags);
	suspended = dev->power.runtime_status == RPM_SUSPENDED;
	spin_unlock_irqrestore(&dev->power.lock, flags);
	return suspended;
}

static inline void rk_mpp_fault_idle_work(struct work_struct *work)
{
	struct rk_mpp_fault_idle *idle = container_of(to_delayed_work(work),
						 struct rk_mpp_fault_idle, work);
	unsigned long flags;
	bool enabled;

	spin_lock_irqsave(&idle->fault_idle_lock, flags);
	enabled = idle->arming_enabled;
	spin_unlock_irqrestore(&idle->fault_idle_lock, flags);
	if (enabled)
		idle->fire(idle);
}

static inline void rk_mpp_fault_idle_init(struct rk_mpp_fault_idle *idle,
					void (*fire)(struct rk_mpp_fault_idle *))
{
	spin_lock_init(&idle->fault_idle_lock);
	INIT_DELAYED_WORK(&idle->work, rk_mpp_fault_idle_work);
	idle->fire = fire;
	idle->arming_enabled = true;
}

static inline bool rk_mpp_fault_idle_arm(struct rk_mpp_fault_idle *idle,
					struct rk_mpp_fault_knob *knob,
					atomic_t *target, pid_t pid)
{
	unsigned long flags;
	unsigned int delay;
	int observed;
	bool scheduled = false;

	spin_lock_irqsave(&idle->fault_idle_lock, flags);
	if (!idle->arming_enabled || work_busy(&idle->work.work))
		goto out;
	observed = atomic_read(target);
	if (observed && observed != pid)
		goto out;
	delay = rk_mpp_fault_consume_delay(knob);
	if (!delay)
		goto out;
	atomic_cmpxchg(target, observed, 0);
#if IS_ENABLED(CONFIG_KUNIT)
	if (idle->before_enqueue)
		idle->before_enqueue(idle);
#endif
	scheduled = schedule_delayed_work(&idle->work, msecs_to_jiffies(delay));
out:
	spin_unlock_irqrestore(&idle->fault_idle_lock, flags);
	return scheduled;
}

static inline void rk_mpp_fault_idle_disable(struct rk_mpp_fault_idle *idle)
{
	unsigned long flags;

	spin_lock_irqsave(&idle->fault_idle_lock, flags);
	idle->arming_enabled = false;
	spin_unlock_irqrestore(&idle->fault_idle_lock, flags);
	cancel_delayed_work_sync(&idle->work);
}

static inline void rk_mpp_fault_idle_enable(struct rk_mpp_fault_idle *idle)
{
	unsigned long flags;

	spin_lock_irqsave(&idle->fault_idle_lock, flags);
	idle->arming_enabled = true;
	spin_unlock_irqrestore(&idle->fault_idle_lock, flags);
}

static int rk_mpp_fault_idle_state_show(struct seq_file *file, void *unused)
{
	struct rk_mpp_fault_controls *fault = file->private;
	int state = atomic_read(&fault->idle_state);

	seq_puts(file, state == 1 ? "suspended\n" :
		 state == 2 ? "not-suspended\n" : "none\n");
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(rk_mpp_fault_idle_state);

static inline int rk_mpp_fault_service_attach(struct rk_mpp_fault_controls *fault,
					     bool eligible)
{
	return eligible && rk_mpp_fault_consume(&fault->service_attach) ? -ENOMEM : 0;
}

static inline int rk_mpp_fault_ccu_attach(struct rk_mpp_fault_controls *fault,
					 bool eligible)
{
	return eligible && rk_mpp_fault_consume(&fault->ccu_attach) ? -ENODEV : 0;
}

static inline int rk_mpp_fault_irq_request(struct rk_mpp_fault_controls *fault,
					  bool eligible)
{
	return eligible && rk_mpp_fault_consume(&fault->irq_request) ? -EBUSY : 0;
}

static inline int rk_mpp_fault_clock_enable(struct rk_mpp_fault_controls *fault,
					   bool eligible)
{
	return eligible && rk_mpp_fault_consume(&fault->clock_enable) ? -EIO : 0;
}

static inline int rk_mpp_fault_session_alloc(struct rk_mpp_fault_controls *fault,
					    bool eligible)
{
	return eligible && rk_mpp_fault_consume(&fault->session_alloc) ? -ENOMEM : 0;
}

static inline bool
rk_mpp_fault_targeted(struct rk_mpp_fault_controls *fault,
		      struct rk_mpp_fault_knob *knob, pid_t opener)
{
	int target = atomic_read(&fault->target_session_pid);

	if (target && target != opener)
		return false;
	if (!rk_mpp_fault_consume(knob))
		return false;
	/* Do not erase a different selector written while this shot was firing. */
	atomic_cmpxchg(&fault->target_session_pid, target, 0);
	return true;
}

static inline void rk_mpp_fault_completion_wait(struct rk_mpp_fault_controls *fault)
{
	int ms;

	if (!IS_ENABLED(CONFIG_ROCKCHIP_MPP_REWRITE_FAULT_INJECTION))
		return;
	ms = atomic_xchg(&fault->delay.armed, 0);
	if (ms <= 0)
		return;
	atomic_inc(&fault->delay.consumed);
#if IS_ENABLED(CONFIG_ROCKCHIP_MPP_REWRITE_KUNIT_TEST)
	if (fault->wait) {
		fault->wait(ms, fault->wait_data);
		return;
	}
#endif
	msleep(ms);
}

static inline void rk_mpp_fault_add_flag(struct dentry *root, const char *name,
					struct rk_mpp_fault_knob *knob)
{
	char consumed[64];

	debugfs_create_atomic_t(name, 0600, root, &knob->armed);
	snprintf(consumed, sizeof(consumed), "%s_consumed", name);
	debugfs_create_atomic_t(consumed, 0400, root, &knob->consumed);
}

static inline int rk_mpp_fault_debugfs_init(struct rk_mpp_fault_controls *fault)
{
	if (!IS_ENABLED(CONFIG_ROCKCHIP_MPP_REWRITE_FAULT_INJECTION))
		return 0;
	fault->root = debugfs_create_dir("rkvenc-test", NULL);
	if (IS_ERR(fault->root))
		return PTR_ERR(fault->root);
	fault->sessions = debugfs_create_dir("sessions", fault->root);
	if (IS_ERR(fault->sessions)) {
		debugfs_remove_recursive(fault->root);
		return PTR_ERR(fault->sessions);
	}
	rk_mpp_fault_add_flag(fault->root, "hang_task_once", &fault->hang);
	rk_mpp_fault_add_flag(fault->root, "fail_service_attach_once", &fault->service_attach);
	rk_mpp_fault_add_flag(fault->root, "fail_ccu_attach_once", &fault->ccu_attach);
	rk_mpp_fault_add_flag(fault->root, "fail_irq_request_once", &fault->irq_request);
	rk_mpp_fault_add_flag(fault->root, "fail_clock_enable_once", &fault->clock_enable);
	rk_mpp_fault_add_flag(fault->root, "fail_session_alloc_once", &fault->session_alloc);
	rk_mpp_fault_add_flag(fault->root, "inject_iommu_fault_once", &fault->iommu);
	rk_mpp_fault_add_flag(fault->root, "fail_reset_once", &fault->reset);
	debugfs_create_atomic_t("target_session_pid", 0600, fault->root,
				&fault->target_session_pid);
	debugfs_create_atomic_t("delay_task_completion_ms", 0600, fault->root,
				&fault->delay.armed);
	debugfs_create_atomic_t("delay_consumed", 0400, fault->root,
				&fault->delay.consumed);
	debugfs_create_atomic_t("inject_iommu_fault_idle_ms", 0600, fault->root,
				&fault->idle.armed);
	debugfs_create_atomic_t("inject_iommu_fault_idle_consumed", 0400, fault->root,
				&fault->idle.consumed);
	debugfs_create_atomic_t("inject_iommu_fault_idle_fired", 0400, fault->root,
				&fault->idle_fired);
	debugfs_create_file("inject_iommu_fault_idle_state", 0400, fault->root,
			   fault, &rk_mpp_fault_idle_state_fops);
	return 0;
}

static inline struct dentry *
rk_mpp_fault_session_open(struct rk_mpp_fault_controls *fault, pid_t opener, u32 id)
{
	char name[32];

	if (!IS_ENABLED(CONFIG_ROCKCHIP_MPP_REWRITE_FAULT_INJECTION) ||
	    IS_ERR_OR_NULL(fault->sessions))
		return NULL;
	snprintf(name, sizeof(name), "%d-%u", opener, id);
	return debugfs_create_dir(name, fault->sessions);
}

#endif
