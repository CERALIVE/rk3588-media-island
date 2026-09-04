// SPDX-License-Identifier: GPL-2.0-only
#include <linux/debugfs.h>
#include <linux/err.h>

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

	return 0;
}

void mpp_rkvenc_test_exit(void)
{
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

static bool mpp_rkvenc_test_target_matches(pid_t session_pid)
{
	int target = atomic_read(&target_session_pid);

	return !target || target == session_pid;
}

static bool mpp_rkvenc_test_consume_targeted(struct mpp_fault_knob *knob,
					      pid_t session_pid)
{
	if (!mpp_rkvenc_test_target_matches(session_pid))
		return false;
	if (!mpp_fault_consume_flag(knob))
		return false;
	atomic_set(&target_session_pid, 0);
	return true;
}

bool mpp_rkvenc_test_hang_task(pid_t session_pid)
{
	return mpp_rkvenc_test_consume_targeted(&hang_task, session_pid);
}

bool mpp_rkvenc_test_inject_iommu_fault(pid_t session_pid)
{
	return mpp_rkvenc_test_consume_targeted(&inject_iommu_fault, session_pid);
}

unsigned int mpp_rkvenc_test_completion_delay_ms(void)
{
	return mpp_fault_consume_delay(&delay_task_completion);
}
