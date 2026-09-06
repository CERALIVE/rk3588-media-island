// SPDX-License-Identifier: GPL-2.0-only
#include "ioctl_mpp_fixture.h"

static void mpp_ioctl_envelope_test(struct kunit *test)
{
	struct mpp_ioctl_fixture *f = test->priv;
	struct mpp_msg_v1 msg = { .cmd = MPP_CMD_INIT_TRANS_TABLE };
	const struct { unsigned int cmd; unsigned long ptr; size_t bytes; int error; } cases[] = {
		{ MPP_IOC_CFG_V2, 0x10000, sizeof(msg), -EINVAL },
		{ UINT_MAX, 0x10000, sizeof(msg), -EINVAL },
		{ MPP_IOC_CFG_V1, 0, 0, -EFAULT },
		{ MPP_IOC_CFG_V1, ULONG_MAX, sizeof(msg), -EFAULT },
		{ MPP_IOC_CFG_V1, 0x10000, 0, -EFAULT },
		{ MPP_IOC_CFG_V1, 0x10000, sizeof(msg) - 1, -EFAULT },
		{ MPP_IOC_CFG_V1, 0x10000, sizeof(msg), 0 },
	};
	int i;

	for (i = 0; i < ARRAY_SIZE(cases); i++) {
		ioctl_region(0, &msg, cases[i].bytes);
		KUNIT_EXPECT_EQ_MSG(test, mpp_dev_ioctl(&f->files[0], cases[i].cmd,
				cases[i].ptr), (long)cases[i].error, "row %d", i);
	}
	msg.cmd = UINT_MAX;
	KUNIT_EXPECT_EQ(test, mpp_dev_ioctl(&f->files[0], MPP_IOC_CFG_V1, 0x10000), -EFAULT);
}

static void mpp_ioctl_chain_test(struct kunit *test)
{
	struct mpp_ioctl_fixture *f = test->priv;
	struct mpp_msg_v1 msgs[MPP_MAX_MSG_NUM + 1] = {};
	const struct { unsigned int count; size_t bytes; int error; } cases[] = {
		{ 1, sizeof(msgs[0]), 0 },
		{ MPP_MAX_MSG_NUM, MPP_MAX_MSG_NUM * sizeof(msgs[0]), 0 },
		{ MPP_MAX_MSG_NUM + 1, sizeof(msgs), -EINVAL },
		{ 2, sizeof(msgs[0]), -EFAULT },
		{ 2, 2 * sizeof(msgs[0]) - 1, -EFAULT },
	};
	int i, j;

	for (i = 0; i < ARRAY_SIZE(cases); i++) {
		for (j = 0; j < cases[i].count; j++) {
			msgs[j].cmd = MPP_CMD_INIT_TRANS_TABLE;
			msgs[j].flags = MPP_FLAGS_MULTI_MSG;
		}
		msgs[cases[i].count - 1].flags |= MPP_FLAGS_LAST_MSG;
		ioctl_region(0, msgs, cases[i].bytes);
		KUNIT_EXPECT_EQ_MSG(test, mpp_dev_ioctl(&f->files[0], MPP_IOC_CFG_V1,
				0x10000), (long)cases[i].error, "chain row %d", i);
		KUNIT_EXPECT_TRUE(test, list_empty(&((struct mpp_session *)
				f->files[0].private_data)->list_msgs));
	}
}

static void mpp_ioctl_table_size_test(struct kunit *test)
{
	struct mpp_ioctl_fixture *f = test->priv;
	struct mpp_session *session = f->files[0].private_data;
	u16 values[MPP_MAX_REG_TRANS_NUM] = { 17, 23 };
	struct mpp_msg_v1 msg = { .cmd = MPP_CMD_INIT_TRANS_TABLE, .data_ptr = 0x20000 };
	const struct { u32 size; size_t available; u64 ptr; int error; } cases[] = {
		{ 0, 0, 0, 0 },
		{ 2, 2, 0x20000, 0 },
		{ sizeof(values), sizeof(values), 0x20000, 0 },
		{ sizeof(values) + 1, sizeof(values), 0x20000, -EINVAL },
		{ sizeof(values) + 2, sizeof(values), 0x20000, -EINVAL },
		{ 1, 1, 0x20000, -EINVAL },
		{ UINT_MAX, sizeof(values), 0x20000, -EINVAL },
		{ 0x80000000, sizeof(values), 0x20000, -EINVAL },
		{ 4, 2, 0x20000, -EINVAL },
		{ 2, 2, 0, -EINVAL },
		{ 2, 2, U64_MAX, -EINVAL },
	};
	int i;

	for (i = 0; i < ARRAY_SIZE(cases); i++) {
		msg.size = cases[i].size;
		msg.data_ptr = cases[i].ptr;
		ioctl_region(0, &msg, sizeof(msg));
		ioctl_region(1, values, cases[i].available);
		KUNIT_EXPECT_EQ_MSG(test, mpp_dev_ioctl(&f->files[0], MPP_IOC_CFG_V1,
				0x10000), (long)cases[i].error, "size row %d", i);
		if (!cases[i].error && msg.size)
			KUNIT_EXPECT_EQ(test, session->trans_count, msg.size / sizeof(values[0]));
	}
}

static void mpp_ioctl_scalar_size_test(struct kunit *test)
{
	struct mpp_ioctl_fixture *f = test->priv;
	u32 data = 0;
	struct mpp_msg_v1 msg = { .cmd = MPP_CMD_QUERY_HW_SUPPORT, .data_ptr = 0x20000 };
	const u32 sizes[] = { 0, 1, 3, 4, 5, UINT_MAX, 0x80000000 };
	int i;

	ioctl_region(0, &msg, sizeof(msg));
	ioctl_region(1, &data, sizeof(data));
	for (i = 0; i < ARRAY_SIZE(sizes); i++) {
		unsigned int copies = ioctl_memory.copies;

		msg.size = sizes[i];
		data = 0xa5a5a5a5;
		KUNIT_EXPECT_EQ_MSG(test, mpp_dev_ioctl(&f->files[0], MPP_IOC_CFG_V1,
			0x10000), sizes[i] == sizeof(data) ? 0L : -EINVAL, "scalar size %u", sizes[i]);
		if (sizes[i] != sizeof(data)) {
			KUNIT_EXPECT_EQ(test, data, 0xa5a5a5a5U);
			KUNIT_EXPECT_EQ(test, ioctl_memory.copies - copies, 1U);
		} else {
			KUNIT_EXPECT_EQ(test, data, 0U);
		}
	}
	msg.size = sizeof(data);
	msg.data_ptr = 0;
	KUNIT_EXPECT_EQ(test, mpp_dev_ioctl(&f->files[0], MPP_IOC_CFG_V1, 0x10000), -EFAULT);
	msg.data_ptr = U64_MAX;
	KUNIT_EXPECT_EQ(test, mpp_dev_ioctl(&f->files[0], MPP_IOC_CFG_V1, 0x10000), -EFAULT);
	msg.data_ptr = 0x20000;
	ioctl_region(1, &data, sizeof(data) - 1);
	KUNIT_EXPECT_EQ(test, mpp_dev_ioctl(&f->files[0], MPP_IOC_CFG_V1, 0x10000), -EFAULT);
}

static void mpp_ioctl_client_test(struct kunit *test)
{
	struct mpp_ioctl_fixture *f = test->priv;
	struct mpp_msg_v1 msg = { .cmd = MPP_CMD_INIT_CLIENT_TYPE,
		.size = sizeof(u32), .data_ptr = 0x20000 };
	u32 clients[] = { 0, MPP_DEVICE_BUTT, UINT_MAX, 0x80000000 };
	int i;

	ioctl_region(0, &msg, sizeof(msg));
	for (i = 0; i < ARRAY_SIZE(clients); i++) {
		ioctl_region(1, &clients[i], sizeof(clients[i]));
		KUNIT_EXPECT_EQ(test, mpp_dev_ioctl(&f->files[0], MPP_IOC_CFG_V1, 0x10000), -EINVAL);
	}
}

static void mpp_ioctl_input_scalar_test(struct kunit *test)
{
	struct mpp_ioctl_fixture *f = test->priv;
	struct mpp_msg_v1 msg = { .data_ptr = 0x20000 };
	u32 data = MPP_CMD_INIT_BASE;
	const u32 commands[] = { MPP_CMD_QUERY_HW_ID, MPP_CMD_QUERY_CMD_SUPPORT,
		MPP_CMD_INIT_CLIENT_TYPE, MPP_CMD_INIT_DRIVER_DATA };
	const u32 sizes[] = { 0, 1, 3, 5, UINT_MAX, 0x80000000 };
	int i, j;

	ioctl_region(0, &msg, sizeof(msg));
	ioctl_region(1, &data, sizeof(data));
	for (i = 0; i < ARRAY_SIZE(commands); i++) {
		msg.cmd = commands[i];
		for (j = 0; j < ARRAY_SIZE(sizes); j++) {
			unsigned int copies = ioctl_memory.copies;

			msg.size = sizes[j];
			KUNIT_EXPECT_EQ(test, mpp_dev_ioctl(&f->files[0], MPP_IOC_CFG_V1, 0x10000), -EINVAL);
			KUNIT_EXPECT_EQ(test, ioctl_memory.copies - copies, 1U);
		}
	}
	msg.cmd = MPP_CMD_QUERY_CMD_SUPPORT;
	msg.size = sizeof(data);
	KUNIT_EXPECT_EQ(test, mpp_dev_ioctl(&f->files[0], MPP_IOC_CFG_V1, 0x10000), 0L);
	KUNIT_EXPECT_EQ(test, data, (u32)MPP_CMD_INIT_BUTT);
}

static void mpp_ioctl_session_cycles_test(struct kunit *test)
{
	struct mpp_ioctl_fixture *f = test->priv;
	struct mpp_msg_v1 msg = { .cmd = MPP_CMD_INIT_TRANS_TABLE, .size = 2, .data_ptr = 0x20000 };
	u16 value = 42;
	int cycle, fd;

	ioctl_region(0, &msg, sizeof(msg));
	ioctl_region(1, &value, sizeof(value));
	for (cycle = 0; cycle < 32; cycle++) {
		for (fd = 0; fd < 2; fd++) {
			struct mpp_session *session = f->files[fd].private_data;

			KUNIT_EXPECT_EQ(test, session->trans_count, 0U);
			KUNIT_EXPECT_EQ(test, session->msgs_cnt, 0U);
			KUNIT_EXPECT_EQ(test, kref_read(&session->telemetry_ref), 1U);
			KUNIT_EXPECT_EQ(test, mpp_dev_ioctl(&f->files[fd], MPP_IOC_CFG_V1, 0x10000), 0L);
			KUNIT_EXPECT_EQ(test, session->trans_table[0], value);
			KUNIT_EXPECT_EQ(test, mpp_dev_release(&f->inode, &f->files[fd]), 0);
			KUNIT_EXPECT_PTR_EQ(test, f->files[fd].private_data, NULL);
		}
		KUNIT_EXPECT_TRUE(test, list_empty(&f->service.session_list));
		KUNIT_EXPECT_EQ(test, ioctl_memory.allocations, 0);
		for (fd = 0; fd < 2; fd++)
			KUNIT_ASSERT_EQ(test, mpp_dev_open(&f->inode, &f->files[fd]), 0);
	}
}

static struct kunit_case mpp_ioctl_cases[] = {
	KUNIT_CASE(ioctl_memory_contract_test),
	KUNIT_CASE(mpp_ioctl_envelope_test),
	KUNIT_CASE(mpp_ioctl_chain_test),
	KUNIT_CASE(mpp_ioctl_table_size_test),
	KUNIT_CASE(mpp_ioctl_scalar_size_test),
	KUNIT_CASE(mpp_ioctl_client_test),
	KUNIT_CASE(mpp_ioctl_input_scalar_test),
	KUNIT_CASE(mpp_ioctl_session_cycles_test),
	{}
};

static struct kunit_suite mpp_ioctl_suite = {
	.name = "rockchip-mpp-ioctl",
	.init = mpp_ioctl_init,
	.exit = mpp_ioctl_exit,
	.test_cases = mpp_ioctl_cases,
};
kunit_test_suite(mpp_ioctl_suite);
MODULE_LICENSE("GPL");
