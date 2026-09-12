/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef __MPP_RKVENC_TEST_H__
#define __MPP_RKVENC_TEST_H__

#include <linux/atomic.h>
#include <linux/types.h>
#include <linux/pm_runtime.h>
#include <linux/workqueue.h>

struct mpp_fault_knob {
	atomic_t armed;
	atomic_t consumed;
};

static inline bool mpp_fault_consume_flag(struct mpp_fault_knob *knob)
{
	if (atomic_cmpxchg(&knob->armed, 1, 0) != 1)
		return false;

	atomic_inc(&knob->consumed);
	return true;
}

static inline unsigned int mpp_fault_consume_delay(struct mpp_fault_knob *knob)
{
	int delay_ms = atomic_xchg(&knob->armed, 0);

	if (delay_ms <= 0)
		return 0;

	atomic_inc(&knob->consumed);
	return delay_ms;
}

static inline bool mpp_fault_consume_targeted(struct mpp_fault_knob *knob,
					      atomic_t *target,
					      pid_t session_pid)
{
	int observed = atomic_read(target);

	if (observed && observed != session_pid)
		return false;
	if (!mpp_fault_consume_flag(knob))
		return false;
	/* Do not erase a different selector written while this shot was firing. */
	atomic_cmpxchg(target, observed, 0);
	return true;
}

struct mpp_fault_idle {
	struct delayed_work work;
	spinlock_t fault_idle_lock;
	bool arming_enabled;
	void (*fire)(struct mpp_fault_idle *idle);
	struct list_head registry;
#if IS_ENABLED(CONFIG_KUNIT)
	void (*before_enqueue)(struct mpp_fault_idle *idle);
#endif
};

static inline bool mpp_fault_idle_suspended(struct device *dev)
{
	unsigned long flags;
	bool suspended;

	spin_lock_irqsave(&dev->power.lock, flags);
	suspended = dev->power.runtime_status == RPM_SUSPENDED;
	spin_unlock_irqrestore(&dev->power.lock, flags);
	return suspended;
}

static inline void mpp_fault_idle_work(struct work_struct *work)
{
	struct mpp_fault_idle *idle = container_of(to_delayed_work(work),
							 struct mpp_fault_idle, work);
	unsigned long flags;
	bool enabled;

	spin_lock_irqsave(&idle->fault_idle_lock, flags);
	enabled = idle->arming_enabled;
	spin_unlock_irqrestore(&idle->fault_idle_lock, flags);
	if (enabled)
		idle->fire(idle);
}

static inline void mpp_fault_idle_init(struct mpp_fault_idle *idle,
				     void (*fire)(struct mpp_fault_idle *))
{
	spin_lock_init(&idle->fault_idle_lock);
	INIT_DELAYED_WORK(&idle->work, mpp_fault_idle_work);
	INIT_LIST_HEAD(&idle->registry);
	idle->fire = fire;
	idle->arming_enabled = true;
}

static inline bool mpp_fault_idle_arm(struct mpp_fault_idle *idle,
				     struct mpp_fault_knob *knob,
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
	delay = mpp_fault_consume_delay(knob);
	if (!delay)
		goto out;
	atomic_cmpxchg(target, observed, 0);
#if IS_ENABLED(CONFIG_KUNIT)
	if (idle->before_enqueue)
		idle->before_enqueue(idle);
#endif
	/* Disable cannot finish cancelling between eligibility and enqueue. */
	scheduled = schedule_delayed_work(&idle->work, msecs_to_jiffies(delay));
out:
	spin_unlock_irqrestore(&idle->fault_idle_lock, flags);
	return scheduled;
}

static inline void mpp_fault_idle_disable(struct mpp_fault_idle *idle)
{
	unsigned long flags;

	spin_lock_irqsave(&idle->fault_idle_lock, flags);
	idle->arming_enabled = false;
	spin_unlock_irqrestore(&idle->fault_idle_lock, flags);
	cancel_delayed_work_sync(&idle->work);
}

static inline void mpp_fault_idle_enable(struct mpp_fault_idle *idle)
{
	unsigned long flags;

	spin_lock_irqsave(&idle->fault_idle_lock, flags);
	idle->arming_enabled = true;
	spin_unlock_irqrestore(&idle->fault_idle_lock, flags);
}

#if IS_ENABLED(CONFIG_ROCKCHIP_MPP_CERALIVE_TEST)
void mpp_rkvenc_test_idle_register(struct mpp_fault_idle *idle);
void mpp_rkvenc_test_idle_unregister(struct mpp_fault_idle *idle);
void mpp_rkvenc_test_idle_arm(struct mpp_fault_idle *idle, pid_t pid);
void mpp_rkvenc_test_idle_record(bool suspended);
int mpp_rkvenc_test_init(void);
void mpp_rkvenc_test_exit(void);
bool mpp_rkvenc_test_fail_service_attach(void);
bool mpp_rkvenc_test_fail_ccu_attach(void);
bool mpp_rkvenc_test_fail_irq_request(void);
bool mpp_rkvenc_test_fail_clock_enable(void);
bool mpp_rkvenc_test_fail_session_alloc(void);
bool mpp_rkvenc_test_fail_reset(void);
bool mpp_rkvenc_test_hang_task(pid_t session_pid);
bool mpp_rkvenc_test_inject_iommu_fault(pid_t session_pid);
unsigned int mpp_rkvenc_test_completion_delay_ms(void);
#else
static inline int mpp_rkvenc_test_init(void) { return 0; }
static inline void mpp_rkvenc_test_exit(void) { }
static inline bool mpp_rkvenc_test_fail_service_attach(void) { return false; }
static inline bool mpp_rkvenc_test_fail_ccu_attach(void) { return false; }
static inline bool mpp_rkvenc_test_fail_irq_request(void) { return false; }
static inline bool mpp_rkvenc_test_fail_clock_enable(void) { return false; }
static inline bool mpp_rkvenc_test_fail_session_alloc(void) { return false; }
static inline bool mpp_rkvenc_test_fail_reset(void) { return false; }
static inline bool mpp_rkvenc_test_hang_task(pid_t session_pid) { return false; }
static inline bool mpp_rkvenc_test_inject_iommu_fault(pid_t session_pid) { return false; }
static inline unsigned int mpp_rkvenc_test_completion_delay_ms(void) { return 0; }
#endif

#endif
