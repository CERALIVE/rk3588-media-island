// SPDX-License-Identifier: GPL-2.0-only
#include <linux/debugfs.h>
#include <linux/err.h>

#include "mpp_rkvenc_test.h"

static struct mpp_fault_knob fail_service_attach;
static struct mpp_fault_knob fail_ccu_attach;
static struct mpp_fault_knob fail_irq_request;
static struct mpp_fault_knob fail_clock_enable;
static struct mpp_fault_knob fail_session_alloc;
static struct mpp_fault_knob delay_task_completion;
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

unsigned int mpp_rkvenc_test_completion_delay_ms(void)
{
	return mpp_fault_consume_delay(&delay_task_completion);
}
