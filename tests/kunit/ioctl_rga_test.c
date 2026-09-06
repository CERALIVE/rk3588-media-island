// SPDX-License-Identifier: GPL-2.0-only
#include "ioctl_rga_fixture.h"

static void rga_ioctl_envelope_test(struct kunit *test)
{
	struct rga_ioctl_fixture *f = test->priv;
	struct rga_user_request req = {};
	const u32 commands[] = { RGA_IOC_IMPORT_BUFFER, RGA_IOC_RELEASE_BUFFER,
		RGA_IOC_REQUEST_CREATE, RGA_IOC_REQUEST_CONFIG, RGA_IOC_REQUEST_SUBMIT,
		RGA_IOC_REQUEST_CANCEL, RGA_IOC_GET_DRVIER_VERSION, RGA_IOC_GET_HW_VERSION };
	int i;

	for (i = 0; i < ARRAY_SIZE(commands); i++) {
		ioctl_region(0, &req, _IOC_SIZE(commands[i]) - 1);
		KUNIT_EXPECT_EQ_MSG(test, rga_ioctl(&f->files[0], commands[i], 0), -EFAULT,
			"null cmd %#x", commands[i]);
		KUNIT_EXPECT_EQ_MSG(test, rga_ioctl(&f->files[0], commands[i], ULONG_MAX), -EFAULT,
			"invalid cmd %#x", commands[i]);
		KUNIT_EXPECT_EQ_MSG(test, rga_ioctl(&f->files[0], commands[i], 0x10000), -EFAULT,
			"short cmd %#x", commands[i]);
	}
	KUNIT_EXPECT_EQ(test, rga_ioctl(&f->files[0], UINT_MAX, 0), -EINVAL);
}

static void rga_ioctl_task_table_test(struct kunit *test)
{
	struct rga_ioctl_fixture *f = test->priv;
	struct rga_req *tasks = kunit_kcalloc(test, RGA_TASK_NUM_MAX, sizeof(*tasks), GFP_KERNEL);
	struct rga_user_request req = { .sync_mode = RGA_BLIT_SYNC };
	const struct { u32 count; size_t available; u64 ptr; int error; } cases[] = {
		{ 0, 0, 0x20000, -EINVAL },
		{ 1, sizeof(*tasks), 0x20000, 0 },
		{ RGA_TASK_NUM_MAX, RGA_TASK_NUM_MAX * sizeof(*tasks), 0x20000, 0 },
		{ RGA_TASK_NUM_MAX + 1, RGA_TASK_NUM_MAX * sizeof(*tasks), 0x20000, -EINVAL },
		{ UINT_MAX, sizeof(*tasks), 0x20000, -EINVAL },
		{ 0x80000000, sizeof(*tasks), 0x20000, -EINVAL },
		{ 2, sizeof(*tasks), 0x20000, -EFAULT },
		{ 1, sizeof(*tasks) - 1, 0x20000, -EFAULT },
		{ 1, sizeof(*tasks), 0, -EINVAL },
		{ 1, sizeof(*tasks), U64_MAX, -EFAULT },
	};
	int i;

	KUNIT_ASSERT_NOT_NULL(test, tasks);
	req.id = rga_test_create(test, &f->files[0]);
	ioctl_region(0, &req, sizeof(req));
	for (i = 0; i < ARRAY_SIZE(cases); i++) {
		req.task_num = cases[i].count;
		req.task_ptr = cases[i].ptr;
		ioctl_region(1, tasks, cases[i].available);
		KUNIT_EXPECT_EQ_MSG(test, rga_ioctl(&f->files[0], RGA_IOC_REQUEST_CONFIG,
				0x10000), (long)cases[i].error, "task row %d", i);
		KUNIT_EXPECT_EQ(test, kref_read(&((struct rga_session *)
				f->files[0].private_data)->refcount), 2U);
		if (cases[i].error)
			KUNIT_EXPECT_EQ_MSG(test, rga_ioctl(&f->files[0], RGA_IOC_REQUEST_SUBMIT,
				0x10000), (long)cases[i].error, "submit row %d", i);
	}
	KUNIT_EXPECT_EQ(test, submit_calls, 0);
}

static void rga_ioctl_semantics_test(struct kunit *test)
{
	struct rga_ioctl_fixture *f = test->priv;
	struct rga_req task = {};
	struct rga_user_request req = { .task_ptr = 0x20000, .task_num = 1 };
	const struct { u32 sync; u8 core; u8 mode; int error; } cases[] = {
		{ RGA_BLIT_SYNC, 0, BITBLT_MODE, 0 },
		{ RGA_BLIT_ASYNC, RGA3_SCHEDULER_CORE0, COLOR_FILL_MODE, 0 },
		{ RGA_BLIT_SYNC, RGA3_SCHEDULER_CORE1, COLOR_PALETTE_MODE, 0 },
		{ RGA_BLIT_SYNC, RGA2_SCHEDULER_CORE0, UPDATE_PALETTE_TABLE_MODE, 0 },
		{ RGA_BLIT_SYNC, RGA_CORE_MASK, UPDATE_PATTEN_BUF_MODE, 0 },
		{ 0, 0, BITBLT_MODE, -EINVAL },
		{ UINT_MAX, 0, BITBLT_MODE, -EINVAL },
		{ RGA_BLIT_SYNC, 0x10, BITBLT_MODE, -EINVAL },
		{ RGA_BLIT_SYNC, 0xff, BITBLT_MODE, -EINVAL },
		{ RGA_BLIT_SYNC, 0, 0xff, -EINVAL },
	};
	int i;

	req.id = rga_test_create(test, &f->files[0]);
	ioctl_region(0, &req, sizeof(req));
	ioctl_region(1, &task, sizeof(task));
	for (i = 0; i < ARRAY_SIZE(cases); i++) {
		req.sync_mode = cases[i].sync;
		task.core = cases[i].core;
		task.render_mode = cases[i].mode;
		KUNIT_EXPECT_EQ_MSG(test, rga_ioctl(&f->files[0], RGA_IOC_REQUEST_CONFIG,
				0x10000), (long)cases[i].error, "semantic row %d", i);
	}
	req.sync_mode = RGA_BLIT_SYNC;
	task.core = task.render_mode = 0;
	KUNIT_EXPECT_EQ(test, rga_ioctl(&f->files[1], RGA_IOC_REQUEST_CONFIG, 0x10000), -EPERM);
	req.id = UINT_MAX;
	KUNIT_EXPECT_EQ(test, rga_ioctl(&f->files[0], RGA_IOC_REQUEST_CONFIG, 0x10000), -EINVAL);
}

static void rga_ioctl_legacy_test(struct kunit *test)
{
	struct rga_ioctl_fixture *f = test->priv;
	struct rga_req task = {};
	const u32 commands[] = { RGA_BLIT_SYNC, RGA_BLIT_ASYNC };
	int i;

	for (i = 0; i < ARRAY_SIZE(commands); i++) {
		ioctl_region(0, &task, sizeof(task) - 1);
		KUNIT_EXPECT_EQ(test, rga_ioctl(&f->files[0], commands[i], 0), -EINVAL);
		KUNIT_EXPECT_EQ(test, rga_ioctl(&f->files[0], commands[i], ULONG_MAX), -EFAULT);
		KUNIT_EXPECT_EQ(test, rga_ioctl(&f->files[0], commands[i], 0x10000), -EFAULT);
		ioctl_region(0, &task, sizeof(task));
		task.core = 0xff;
		KUNIT_EXPECT_EQ(test, rga_ioctl(&f->files[0], commands[i], 0x10000), -EINVAL);
		task.core = 0;
		task.render_mode = 0xff;
		KUNIT_EXPECT_EQ(test, rga_ioctl(&f->files[0], commands[i], 0x10000), -EINVAL);
		task.render_mode = BITBLT_MODE;
		KUNIT_EXPECT_EQ(test, rga_ioctl(&f->files[0], commands[i], 0x10000), -ENODEV);
		KUNIT_EXPECT_EQ(test, f->driver.pend_request_manager->request_count, 0);
	}
	KUNIT_EXPECT_EQ(test, submit_calls, 2);
}

static void rga_ioctl_pool_test(struct kunit *test)
{
	struct rga_ioctl_fixture *f = test->priv;
	struct rga_external_buffer *buffers = kunit_kcalloc(test, RGA_BUFFER_POOL_SIZE_MAX,
							sizeof(*buffers), GFP_KERNEL);
	struct rga_buffer_pool pool = { .buffers_ptr = 0x20000 };
	const struct { u32 count; size_t available; int error; } cases[] = {
		{ 0, 0, 0 },
		{ RGA_BUFFER_POOL_SIZE_MAX + 1, 0, -EFBIG },
		{ UINT_MAX, 0, -EFBIG },
		{ 0x80000000, 0, -EFBIG },
		{ 2, sizeof(*buffers), -EFAULT },
		{ 1, sizeof(*buffers) - 1, -EFAULT },
	};
	const u32 commands[] = { RGA_IOC_IMPORT_BUFFER, RGA_IOC_RELEASE_BUFFER };
	int i, j;

	KUNIT_ASSERT_NOT_NULL(test, buffers);
	ioctl_region(0, &pool, sizeof(pool));
	for (j = 0; j < ARRAY_SIZE(commands); j++) {
		for (i = 0; i < ARRAY_SIZE(cases); i++) {
			pool.size = cases[i].count;
			ioctl_region(1, buffers, cases[i].available);
			KUNIT_EXPECT_EQ_MSG(test, rga_ioctl(&f->files[0], commands[j], 0x10000),
				(long)cases[i].error, "pool cmd %#x row %d", commands[j], i);
		}
		pool.size = 1;
		pool.buffers_ptr = 0;
		KUNIT_EXPECT_EQ(test, rga_ioctl(&f->files[0], commands[j], 0x10000), -EFAULT);
		pool.buffers_ptr = U64_MAX;
		KUNIT_EXPECT_EQ(test, rga_ioctl(&f->files[0], commands[j], 0x10000), -EFAULT);
		pool.buffers_ptr = 0x20000;
	}
	pool.size = RGA_BUFFER_POOL_SIZE_MAX;
	ioctl_region(1, buffers, pool.size * sizeof(*buffers));
	for (i = 0; i < pool.size; i++)
		buffers[i].type = RGA_DMA_BUFFER;
	KUNIT_EXPECT_EQ(test, rga_ioctl(&f->files[0], RGA_IOC_IMPORT_BUFFER, 0x10000), (long)pool.size);
	for (i = 0; i < pool.size; i++)
		buffers[i].handle = pool.size - i;
	KUNIT_EXPECT_EQ(test, rga_ioctl(&f->files[0], RGA_IOC_RELEASE_BUFFER, 0x10000), 0L);
	pool.size = 2;
	import_fail_at = 2;
	KUNIT_EXPECT_EQ(test, rga_ioctl(&f->files[0], RGA_IOC_IMPORT_BUFFER, 0x10000), -EBADF);
	KUNIT_EXPECT_EQ(test, buffer_refs, 0);
	import_fail_at = 0;
	ioctl_memory.regions[1].writable = 0;
	KUNIT_EXPECT_EQ(test, rga_ioctl(&f->files[0], RGA_IOC_IMPORT_BUFFER, 0x10000), -EFAULT);
	KUNIT_EXPECT_EQ(test, buffer_refs, 0);
	buffers[1].type = UINT_MAX;
	KUNIT_EXPECT_EQ(test, rga_ioctl(&f->files[0], RGA_IOC_IMPORT_BUFFER, 0x10000), -EOPNOTSUPP);
	KUNIT_EXPECT_EQ(test, buffer_refs, 0);
}

#include "ioctl_rga_lifecycle.h"

static struct kunit_case rga_ioctl_cases[] = {
	KUNIT_CASE(ioctl_memory_contract_test),
	KUNIT_CASE(rga_ioctl_envelope_test),
	KUNIT_CASE(rga_ioctl_task_table_test),
	KUNIT_CASE(rga_ioctl_semantics_test),
	KUNIT_CASE(rga_ioctl_legacy_test),
	KUNIT_CASE(rga_ioctl_pool_test),
	KUNIT_CASE(rga_ioctl_session_cycles_test),
	KUNIT_CASE(rga_ioctl_create_copy_failure_test),
	{}
};
static struct kunit_suite rga_ioctl_suite = {
	.name = "rockchip-rga-ioctl",
	.init = rga_ioctl_init,
	.exit = rga_ioctl_exit,
	.test_cases = rga_ioctl_cases,
};
kunit_test_suite(rga_ioctl_suite);
MODULE_LICENSE("GPL");
