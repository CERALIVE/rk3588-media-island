// SPDX-License-Identifier: GPL-2.0-only
#include <linux/debugfs.h>
#include <linux/err.h>

#include "rga_test.h"

static struct rga_fault_knob irq_timeout;
static struct rga_fault_knob hang_task;
static struct rga_fault_knob fail_reset;
static struct rga_fault_knob inject_iommu_fault;
static struct dentry *rga_test_dir;

static void rga_test_add_flag(const char *name, struct rga_fault_knob *knob)
{
	char consumed_name[64];

	debugfs_create_atomic_t(name, 0600, rga_test_dir, &knob->armed);
	snprintf(consumed_name, sizeof(consumed_name), "%s_consumed", name);
	debugfs_create_atomic_t(consumed_name, 0400, rga_test_dir,
				&knob->consumed);
}

int rga_test_init(void)
{
	rga_test_dir = debugfs_create_dir("rga-test", NULL);
	if (IS_ERR(rga_test_dir))
		return PTR_ERR(rga_test_dir);

	rga_test_add_flag("irq_timeout_once", &irq_timeout);
	rga_test_add_flag("hang_task_once", &hang_task);
	rga_test_add_flag("fail_reset_once", &fail_reset);
	rga_test_add_flag("inject_iommu_fault_once", &inject_iommu_fault);
	return 0;
}

void rga_test_exit(void)
{
	debugfs_remove_recursive(rga_test_dir);
	rga_test_dir = NULL;
}

bool rga_test_irq_timeout(void)
{
	return rga_fault_consume_flag(&irq_timeout);
}

bool rga_test_hang_task(void)
{
	return rga_fault_consume_flag(&hang_task);
}

bool rga_test_fail_reset(void)
{
	return rga_fault_consume_flag(&fail_reset);
}

bool rga_test_inject_iommu_fault(void)
{
	return rga_fault_consume_flag(&inject_iommu_fault);
}
