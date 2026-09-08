/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef RK_MPP_REWRITE_FAULT_H
#define RK_MPP_REWRITE_FAULT_H

#include <linux/atomic.h>
#include <linux/debugfs.h>
#include <linux/delay.h>
#include <linux/err.h>

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
