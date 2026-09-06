/* SPDX-License-Identifier: GPL-2.0-only */
#include "ioctl_rga_fixture.h"
static void rga_ioctl_session_cycles_test(struct kunit *test)
{
	struct rga_ioctl_fixture *f = test->priv;
	int cycle, fd;

	for (cycle = 0; cycle < 32; cycle++) {
		u32 ids[2];

		for (fd = 0; fd < 2; fd++) {
			struct rga_session *session = f->files[fd].private_data;

			KUNIT_EXPECT_EQ(test, kref_read(&session->refcount), 1U);
			ids[fd] = rga_test_create(test, &f->files[fd]);
			KUNIT_EXPECT_GT(test, ids[fd], 0U);
			KUNIT_EXPECT_EQ(test, kref_read(&session->refcount), 2U);
		}
		KUNIT_EXPECT_NE(test, ids[0], ids[1]);
		ioctl_region(0, &ids[0], sizeof(ids[0]));
		KUNIT_EXPECT_EQ(test, rga_ioctl(&f->files[1], RGA_IOC_REQUEST_CANCEL, 0x10000), -EPERM);
		KUNIT_EXPECT_EQ(test, rga_ioctl(&f->files[0], RGA_IOC_REQUEST_CANCEL, 0x10000), 0L);
		KUNIT_EXPECT_EQ(test, rga_ioctl(&f->files[0], RGA_IOC_REQUEST_CANCEL, 0x10000), -EINVAL);
		for (fd = 0; fd < 2; fd++) {
			KUNIT_EXPECT_EQ(test, rga_release(&f->inode, &f->files[fd]), 0);
			KUNIT_EXPECT_PTR_EQ(test, f->files[fd].private_data, NULL);
		}
		KUNIT_EXPECT_EQ(test, f->driver.session_manager->session_cnt, 0);
		KUNIT_EXPECT_EQ(test, f->driver.pend_request_manager->request_count, 0);
		KUNIT_EXPECT_TRUE(test, idr_is_empty(&f->driver.session_manager->ctx_id_idr));
		KUNIT_EXPECT_TRUE(test, idr_is_empty(&f->driver.pend_request_manager->request_idr));
		KUNIT_EXPECT_EQ(test, ioctl_memory.allocations, 2);
		for (fd = 0; fd < 2; fd++)
			KUNIT_ASSERT_EQ(test, rga_open(&f->inode, &f->files[fd]), 0);
	}
}

static void rga_ioctl_create_copy_failure_test(struct kunit *test)
{
	struct rga_ioctl_fixture *f = test->priv;
	struct rga_session *session = f->files[0].private_data;
	u32 flags = 0;
	int baseline = ioctl_memory.allocations;

	ioctl_region(0, &flags, sizeof(flags));
	ioctl_memory.regions[0].writable = sizeof(flags) - 1;
	KUNIT_EXPECT_EQ(test, rga_ioctl(&f->files[0], RGA_IOC_REQUEST_CREATE, 0x10000), -EFAULT);
	KUNIT_EXPECT_EQ(test, f->driver.pend_request_manager->request_count, 0);
	KUNIT_EXPECT_EQ(test, kref_read(&session->refcount), 1U);
	KUNIT_EXPECT_EQ(test, ioctl_memory.allocations, baseline);
}
