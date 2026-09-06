/* SPDX-License-Identifier: GPL-2.0-only */
#include <linux/file.h>
#include <linux/iopoll.h>
#include <linux/nospec.h>
#include <linux/regmap.h>
#define mpp_debug(type, fmt, ...) pr_debug(fmt, ##__VA_ARGS__)
#include "../mpp/mpp_common.h"
#include "../mpp/mpp_iommu.h"
#include "../mpp/mpp_capabilities.h"
#include "../mpp/mpp_request_bounds.h"
#include "ioctl_test_memory.h"
#include "ioctl_mpp_types.inc"

static int mpp_unexpected_hardware(void)
{
	KUNIT_FAIL(ioctl_memory.test, "unexpected hardware dependency");
	return -ENODEV;
}

static int mpp_test_task(struct mpp_session *session, struct mpp_task_msgs *msgs)
{
	return mpp_unexpected_hardware();
}

#define mpp_dbg_session(...) do { } while (0)
#define mpp_debug_func(...) do { } while (0)
#define mpp_debug_enter() do { } while (0)
#define mpp_debug_leave() do { } while (0)
#define mpp_err(...) pr_debug(__VA_ARGS__)
#define mpp_telemetry_add_session(session) do { } while (0)
#define mpp_telemetry_remove_session(session) do { } while (0)
#define mpp_session_clear_pending(session) do { } while (0)
#define mpp_session_attach_workqueue(session, queue) mpp_unexpected_hardware()
#define mpp_session_detach_workqueue(session) mpp_unexpected_hardware()
#define mpp_dma_session_create(dev, max) ((void *)(long)mpp_unexpected_hardware())
#define mpp_dma_session_destroy(dma) mpp_unexpected_hardware()
#define mpp_dma_import_fd(info, dma, fd, use) ERR_PTR(mpp_unexpected_hardware())
#define mpp_dma_release_fd(dma, fd) mpp_unexpected_hardware()
#define mpp_process_task(session, msgs) mpp_test_task(session, msgs)
#define mpp_wait_result(session, msgs) mpp_test_task(session, msgs)
#define mpp_process_task_default mpp_test_task
#define mpp_wait_result_default mpp_test_task

static void mpp_msgs_trigger(struct list_head *head)
{
	struct mpp_task_msgs *msgs;

	list_for_each_entry(msgs, head, list)
		KUNIT_EXPECT_PTR_EQ(ioctl_memory.test, msgs->task, NULL);
}

#include "ioctl_mpp_source.inc"

const struct file_operations rockchip_mpp_fops = {
	.open = mpp_dev_open,
	.release = mpp_dev_release,
	.unlocked_ioctl = mpp_dev_ioctl,
};

struct mpp_ioctl_fixture {
	struct mpp_service service;
	struct inode inode;
	struct file files[2];
};

static int mpp_ioctl_init(struct kunit *test)
{
	struct mpp_ioctl_fixture *fixture;
	int i;

	memset(&ioctl_memory, 0, sizeof(ioctl_memory));
	ioctl_memory.test = test;
	fixture = kunit_kzalloc(test, sizeof(*fixture), GFP_KERNEL);
	if (!fixture)
		return -ENOMEM;
	test->priv = fixture;
	mutex_init(&fixture->service.session_lock);
	INIT_LIST_HEAD(&fixture->service.session_list);
	fixture->inode.i_cdev = &fixture->service.mpp_cdev;
	for (i = 0; i < ARRAY_SIZE(fixture->files); i++) {
		fixture->files[i].f_op = &rockchip_mpp_fops;
		if (mpp_dev_open(&fixture->inode, &fixture->files[i]))
			return -ENOMEM;
	}
	return 0;
}

static void mpp_ioctl_exit(struct kunit *test)
{
	struct mpp_ioctl_fixture *fixture = test->priv;
	int i;

	for (i = 0; i < ARRAY_SIZE(fixture->files); i++)
		if (fixture->files[i].private_data)
			mpp_dev_release(&fixture->inode, &fixture->files[i]);
	KUNIT_EXPECT_TRUE(test, list_empty(&fixture->service.session_list));
	KUNIT_EXPECT_EQ(test, ioctl_memory.allocations, 0);
}
