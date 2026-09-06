/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef ISLAND_IOCTL_RGA_FIXTURE_H
#define ISLAND_IOCTL_RGA_FIXTURE_H
#include <linux/dma-fence.h>
#include "../rga3/include/rga_drv.h"
#include "../rga3/include/rga_fence.h"
#include "../rga3/include/rga_job.h"
#include "../rga3/include/rga_request_validation.h"
#include "../mpp/media_request_size.h"
#include "ioctl_test_memory.h"
#include "ioctl_rga_types.inc"

struct rga_drvdata_t *rga_drvdata;
static const struct rga_backend_ops rga2_ops;
static int power_refs, buffer_refs, submit_calls;
static int import_fail_at;

#define DEBUGGER_EN(option) false
#define rga_err(...) do { } while (0)
#define rga_log(...) do { } while (0)
#define rga_req_err(...) do { } while (0)
#define rga_dump_external_buffer(buffer) do { } while (0)
#define rga_telemetry_add_session(session) do { } while (0)
#define rga_telemetry_remove_session(session) do { } while (0)

static char *ioctl_pname(struct task_struct *task, gfp_t flags)
{
	char *name = kstrdup_quotable_cmdline(task, flags);

	if (name)
		ioctl_memory.allocations++;
	return name;
}
#define kstrdup_quotable_cmdline(task, flags) ioctl_pname(task, flags)

static int rga_power_enable_all(void)
{
	power_refs++;
	return 0;
}

static void rga_power_disable_all(void)
{
	power_refs--;
}

static int rga_mm_import_buffer(struct rga_external_buffer *buffer,
				struct rga_session *session)
{
	if (import_fail_at && buffer_refs + 1 == import_fail_at)
		return -EBADF;
	return ++buffer_refs;
}

static int rga_mm_release_buffer(u32 handle, struct rga_session *session)
{
	if (!handle || handle > buffer_refs)
		return -EINVAL;
	buffer_refs--;
	return 0;
}

static void rga_mm_session_release_buffer(struct rga_session *session)
{
	KUNIT_EXPECT_EQ(ioctl_memory.test, buffer_refs, 0);
}

static void rga_request_acquire_fence_work(struct work_struct *work)
{
	KUNIT_FAIL(ioctl_memory.test, "unexpected async work");
}

static void rga_request_cancel_acquire_fence(struct rga_request *request)
{
	KUNIT_EXPECT_PTR_EQ(ioctl_memory.test, request->acquire_fence, NULL);
}

static void rga_request_scheduler_job_abort(struct rga_request *request)
{
	KUNIT_EXPECT_FALSE(ioctl_memory.test, request->is_running);
}

/* Hardware submission is a stop point, not a replacement validator. */
int rga_request_submit_locked(struct rga_request *request)
{
	submit_calls++;
	mutex_unlock(&request->commit_lock);
	rga_request_cancel(request, -ENODEV);
	return -ENODEV;
}

#include "ioctl_rga_source.inc"

struct rga_ioctl_fixture {
	struct rga_drvdata_t driver;
	struct inode inode;
	struct file files[2];
};

static int rga_ioctl_init(struct kunit *test)
{
	struct rga_ioctl_fixture *f;
	int ret, i;

	memset(&ioctl_memory, 0, sizeof(ioctl_memory));
	ioctl_memory.test = test;
	power_refs = buffer_refs = submit_calls = import_fail_at = 0;
	f = kunit_kzalloc(test, sizeof(*f), GFP_KERNEL);
	if (!f)
		return -ENOMEM;
	test->priv = f;
	rga_drvdata = &f->driver;
	init_rwsem(&f->driver.rwsem);
	ret = rga_session_manager_init(&f->driver.session_manager);
	if (ret)
		return ret;
	ret = rga_request_manager_init(&f->driver.pend_request_manager);
	if (ret)
		return ret;
	for (i = 0; i < ARRAY_SIZE(f->files); i++) {
		ret = rga_open(&f->inode, &f->files[i]);
		if (ret)
			return ret;
	}
	return 0;
}

static void rga_ioctl_exit(struct kunit *test)
{
	struct rga_ioctl_fixture *f = test->priv;
	int i;

	for (i = 0; i < ARRAY_SIZE(f->files); i++)
		if (f->files[i].private_data)
			rga_release(&f->inode, &f->files[i]);
	KUNIT_EXPECT_EQ(test, f->driver.session_manager->session_cnt, 0);
	KUNIT_EXPECT_EQ(test, f->driver.pend_request_manager->request_count, 0);
	KUNIT_EXPECT_TRUE(test, idr_is_empty(&f->driver.session_manager->ctx_id_idr));
	KUNIT_EXPECT_TRUE(test, idr_is_empty(&f->driver.pend_request_manager->request_idr));
	idr_destroy(&f->driver.session_manager->ctx_id_idr);
	idr_destroy(&f->driver.pend_request_manager->request_idr);
	kfree(f->driver.session_manager);
	kfree(f->driver.pend_request_manager);
	KUNIT_EXPECT_EQ(test, ioctl_memory.allocations, 0);
	KUNIT_EXPECT_EQ(test, power_refs, 0);
	KUNIT_EXPECT_EQ(test, buffer_refs, 0);
	rga_drvdata = NULL;
}

static u32 rga_test_create(struct kunit *test, struct file *file)
{
	u32 id = 0;

	ioctl_region(0, &id, sizeof(id));
	KUNIT_EXPECT_EQ(test, rga_ioctl(file, RGA_IOC_REQUEST_CREATE, 0x10000), 0L);
	return id;
}
#endif
