// SPDX-License-Identifier: GPL-2.0-only
#include <linux/debugfs.h>
#include <linux/err.h>
#include <linux/seq_file.h>

#include "mpp_rkvenc_test.h"

static struct mpp_fault_knob fail_service_attach;
static struct mpp_fault_knob fail_ccu_attach;
static struct mpp_fault_knob fail_irq_request;
static struct mpp_fault_knob fail_clock_enable;
static struct mpp_fault_knob fail_session_alloc;
static struct mpp_fault_knob fail_reset;
static struct mpp_fault_knob hang_task;
static struct mpp_fault_knob inject_iommu_fault;
static struct mpp_fault_knob delay_task_completion;
static struct mpp_fault_knob inject_iommu_fault_idle;
static atomic_t inject_iommu_fault_idle_fired = ATOMIC_INIT(0);
static atomic_t inject_iommu_fault_idle_state = ATOMIC_INIT(0);
static LIST_HEAD(fault_idle_devices);
static DEFINE_MUTEX(fault_idle_devices_lock);
static atomic_t target_session_pid = ATOMIC_INIT(0);
static struct dentry *mpp_rkvenc_test_dir;

static void mpp_rkvenc_test_add_flag(const char *name,
				     struct mpp_fault_knob *knob)
{
	char consumed_name[64];

	debugfs_create_atomic_t(name, 0600, mpp_rkvenc_test_dir, &knob->armed);
	snprintf(consumed_name, sizeof(consumed_name), "%s_consumed", name);
	debugfs_create_atomic_t(consumed_name, 0400, mpp_rkvenc_test_dir,
				&knob->consumed);
}

static int mpp_rkvenc_test_idle_state_show(struct seq_file *file, void *unused)
{
	int state = atomic_read(&inject_iommu_fault_idle_state);

	seq_puts(file, state == 1 ? "suspended\n" :
		 state == 2 ? "not-suspended\n" : "none\n");
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(mpp_rkvenc_test_idle_state);

void mpp_rkvenc_test_idle_register(struct mpp_fault_idle *idle)
{
	mutex_lock(&fault_idle_devices_lock);
	list_add_tail(&idle->registry, &fault_idle_devices);
	mutex_unlock(&fault_idle_devices_lock);
}

void mpp_rkvenc_test_idle_unregister(struct mpp_fault_idle *idle)
{
	mutex_lock(&fault_idle_devices_lock);
	mpp_fault_idle_disable(idle);
	list_del_init(&idle->registry);
	mutex_unlock(&fault_idle_devices_lock);
}

void mpp_rkvenc_test_idle_arm(struct mpp_fault_idle *idle, pid_t pid)
{
	mpp_fault_idle_arm(idle, &inject_iommu_fault_idle, &target_session_pid, pid);
}

void mpp_rkvenc_test_idle_record(bool suspended)
{
	atomic_set(&inject_iommu_fault_idle_state, suspended ? 1 : 2);
	atomic_inc(&inject_iommu_fault_idle_fired);
}

int mpp_rkvenc_test_init(void)
{
	mpp_rkvenc_test_dir = debugfs_create_dir("rkvenc-test", NULL);
	if (IS_ERR(mpp_rkvenc_test_dir))
		return PTR_ERR(mpp_rkvenc_test_dir);

	mpp_rkvenc_test_add_flag("fail_service_attach_once", &fail_service_attach);
	mpp_rkvenc_test_add_flag("fail_ccu_attach_once", &fail_ccu_attach);
	mpp_rkvenc_test_add_flag("fail_irq_request_once", &fail_irq_request);
	mpp_rkvenc_test_add_flag("fail_clock_enable_once", &fail_clock_enable);
	mpp_rkvenc_test_add_flag("fail_session_alloc_once", &fail_session_alloc);
	mpp_rkvenc_test_add_flag("fail_reset_once", &fail_reset);
	mpp_rkvenc_test_add_flag("hang_task_once", &hang_task);
	mpp_rkvenc_test_add_flag("inject_iommu_fault_once", &inject_iommu_fault);
	debugfs_create_atomic_t("target_session_pid", 0600, mpp_rkvenc_test_dir,
				&target_session_pid);
	debugfs_create_atomic_t("delay_task_completion_ms", 0600,
				mpp_rkvenc_test_dir, &delay_task_completion.armed);
	debugfs_create_atomic_t("delay_consumed", 0400, mpp_rkvenc_test_dir,
				&delay_task_completion.consumed);
	debugfs_create_atomic_t("inject_iommu_fault_idle_ms", 0600,
				mpp_rkvenc_test_dir, &inject_iommu_fault_idle.armed);
	debugfs_create_atomic_t("inject_iommu_fault_idle_consumed", 0400,
				mpp_rkvenc_test_dir, &inject_iommu_fault_idle.consumed);
	debugfs_create_atomic_t("inject_iommu_fault_idle_fired", 0400,
				mpp_rkvenc_test_dir, &inject_iommu_fault_idle_fired);
	debugfs_create_file("inject_iommu_fault_idle_state", 0400,
			   mpp_rkvenc_test_dir, NULL, &mpp_rkvenc_test_idle_state_fops);

	return 0;
}

void mpp_rkvenc_test_exit(void)
{
	struct mpp_fault_idle *idle;

	mutex_lock(&fault_idle_devices_lock);
	list_for_each_entry(idle, &fault_idle_devices, registry)
		mpp_fault_idle_disable(idle);
	mutex_unlock(&fault_idle_devices_lock);
	debugfs_remove_recursive(mpp_rkvenc_test_dir);
	mpp_rkvenc_test_dir = NULL;
}

bool mpp_rkvenc_test_fail_service_attach(void)
{
	return mpp_fault_consume_flag(&fail_service_attach);
}

bool mpp_rkvenc_test_fail_ccu_attach(void)
{
	return mpp_fault_consume_flag(&fail_ccu_attach);
}

bool mpp_rkvenc_test_fail_irq_request(void)
{
	return mpp_fault_consume_flag(&fail_irq_request);
}

bool mpp_rkvenc_test_fail_clock_enable(void)
{
	return mpp_fault_consume_flag(&fail_clock_enable);
}

bool mpp_rkvenc_test_fail_session_alloc(void)
{
	return mpp_fault_consume_flag(&fail_session_alloc);
}

bool mpp_rkvenc_test_fail_reset(void)
{
	return mpp_fault_consume_flag(&fail_reset);
}

bool mpp_rkvenc_test_hang_task(pid_t session_pid)
{
	return mpp_fault_consume_targeted(&hang_task, &target_session_pid,
					  session_pid);
}

bool mpp_rkvenc_test_inject_iommu_fault(pid_t session_pid)
{
	return mpp_fault_consume_targeted(&inject_iommu_fault,
					  &target_session_pid, session_pid);
}

unsigned int mpp_rkvenc_test_completion_delay_ms(void)
{
	return mpp_fault_consume_delay(&delay_task_completion);
}
