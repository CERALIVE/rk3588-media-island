// SPDX-License-Identifier: GPL-2.0-only
#include <kunit/device.h>
#include <kunit/test.h>
#include <linux/file.h>
#include <linux/mount.h>
#include <linux/pm_runtime.h>

#include "../mpp/mpp_debug.h"
#include "../mpp/mpp_common.h"

static int mpp_telemetry_atomic64_get(void *data, u64 *value);
DEFINE_DEBUGFS_ATTRIBUTE(mpp_telemetry_atomic64_fops,
			 mpp_telemetry_atomic64_get, NULL, "%llu\n");

static bool fail_second_core_dir;

static struct dentry *mpp_debugfs_create_dir(const char *name, struct dentry *parent)
{
	if (fail_second_core_dir && !strcmp(name, "1"))
		return ERR_PTR(-ENOMEM);
	return debugfs_create_dir(name, parent);
}

/* Hardware teardown is substituted; debugfs, VFS and devres lifetimes are real. */
#define mpp_iommu_quiesce_fault_handler(...) do { } while (0)
#define mpp_iommu_remove(...) do { } while (0)
#define mpp_detach_workqueue(...) do { } while (0)
#define debugfs_create_dir mpp_debugfs_create_dir
#include "telemetry_mpp_source.inc"
#undef debugfs_create_dir

struct mpp_debugfs_fixture {
	struct mpp_service srv;
	struct mpp_taskqueue queue;
	struct device_driver *driver;
	struct vfsmount *mount;
};

static void mpp_debugfs_test_fput(void *data)
{
	fput(data);
}

static int mpp_debugfs_test_init(struct kunit *test)
{
	struct mpp_debugfs_fixture *fixture;
	struct file_system_type *type;

	fixture = kunit_kzalloc(test, sizeof(*fixture), GFP_KERNEL);
	if (!fixture)
		return -ENOMEM;
	fixture->driver = kunit_driver_create(test, "mpp-debugfs");
	if (IS_ERR(fixture->driver))
		return PTR_ERR(fixture->driver);
	type = get_fs_type("debugfs");
	if (!type)
		return -ENODEV;
	fixture->mount = kern_mount(type);
	module_put(type->owner);
	if (IS_ERR(fixture->mount))
		return PTR_ERR(fixture->mount);
	fixture->srv.taskqueue_cnt = 1;
	fixture->srv.task_queues[0] = &fixture->queue;
	fail_second_core_dir = false;
	test->priv = fixture;
	return 0;
}

static void mpp_debugfs_test_exit(struct kunit *test)
{
	struct mpp_debugfs_fixture *fixture = test->priv;

	mpp_telemetry_remove(&fixture->srv);
	kern_unmount(fixture->mount);
}

static struct mpp_dev *mpp_debugfs_test_core(struct kunit *test, unsigned int id)
{
	static struct mpp_hw_ops hw_ops;
	struct mpp_debugfs_fixture *fixture = test->priv;
	struct device *dev;
	struct mpp_dev *mpp;

	/* A private driver per core would unregister a driver bound to both cores. */
	dev = kunit_device_register_with_driver(test,
			id ? "mpp-debugfs-core1" : "mpp-debugfs-core0", fixture->driver);
	KUNIT_ASSERT_NOT_ERR_OR_NULL(test, dev);
	mpp = devm_kzalloc(dev, sizeof(*mpp), GFP_KERNEL);
	KUNIT_ASSERT_NOT_NULL(test, mpp);
	mpp->dev = dev;
	mpp->hw_ops = &hw_ops;
	pm_runtime_enable(dev);
	fixture->queue.cores[id] = mpp;
	return mpp;
}

static void mpp_debugfs_counter_read_after_remove_test(struct kunit *test)
{
	static const char * const counters[] = { "busy", "busy_ns", "tasks", "errors", "resets" };
	struct mpp_debugfs_fixture *fixture = test->priv;
	struct mpp_dev *mpp = mpp_debugfs_test_core(test, 0);
	struct mpp_dev *other = mpp_debugfs_test_core(test, 1);
	struct device *dev = mpp->dev;
	struct file *files[ARRAY_SIZE(counters)];
	struct dentry *entry;
	unsigned int i;

	KUNIT_ASSERT_EQ(test, mpp_telemetry_init(&fixture->srv), 0);
	for (i = 0; i < ARRAY_SIZE(counters); i++) {
		struct path path = { .mnt = fixture->mount };

		path.dentry = debugfs_lookup(counters[i], mpp->telemetry_dir);
		KUNIT_ASSERT_NOT_NULL(test, path.dentry);
		files[i] = dentry_open(&path, O_RDONLY, current_cred());
		dput(path.dentry);
		KUNIT_ASSERT_NOT_ERR_OR_NULL(test, files[i]);
		KUNIT_ASSERT_EQ(test, kunit_add_action_or_reset(test,
				mpp_debugfs_test_fput, files[i]), 0);
		KUNIT_ASSERT_EQ(test, debugfs_file_get(file_dentry(files[i])), 0);
		debugfs_file_put(file_dentry(files[i]));
	}

	KUNIT_EXPECT_EQ(test, mpp_dev_remove(mpp), 0);
	entry = debugfs_lookup("0", fixture->srv.telemetry_cores);
	KUNIT_EXPECT_PTR_EQ(test, entry, NULL);
	dput(entry);
	KUNIT_EXPECT_PTR_EQ(test, mpp->telemetry_dir, NULL);
	/* Keep the red run safe: report the missing removal before freeing storage. */
	if (mpp->telemetry_dir) {
		debugfs_remove_recursive(mpp->telemetry_dir);
		mpp->telemetry_dir = NULL;
	}
	kunit_device_unregister(test, dev);
	fixture->queue.cores[0] = NULL;

	for (i = 0; i < ARRAY_SIZE(counters); i++) {
		loff_t pos = 0;

		/* Removal must reject the read before either the getter or uaccess. */
		KUNIT_EXPECT_EQ(test, files[i]->f_op->read(files[i], NULL, 32, &pos), -EIO);
		kunit_release_action(test, mpp_debugfs_test_fput, files[i]);
	}
	entry = debugfs_lookup("busy", other->telemetry_dir);
	KUNIT_EXPECT_NOT_NULL(test, entry);
	dput(entry);
	mpp_dev_remove(other);
}

static void mpp_debugfs_remove_without_registration_test(struct kunit *test)
{
	struct mpp_dev *mpp = mpp_debugfs_test_core(test, 0);

	KUNIT_EXPECT_EQ(test, mpp_dev_remove(mpp), 0);
	KUNIT_EXPECT_PTR_EQ(test, mpp->telemetry_dir, NULL);
}

static void mpp_debugfs_partial_init_unwind_test(struct kunit *test)
{
	struct mpp_debugfs_fixture *fixture = test->priv;
	struct mpp_dev *first = mpp_debugfs_test_core(test, 0);
	struct mpp_dev *second = mpp_debugfs_test_core(test, 1);

	fail_second_core_dir = true;
	KUNIT_ASSERT_EQ(test, mpp_telemetry_init(&fixture->srv), -ENOMEM);
	/* The parent must survive until device removal drops its child handles. */
	KUNIT_ASSERT_NOT_NULL(test, fixture->srv.telemetry_root);
	KUNIT_EXPECT_EQ(test, mpp_dev_remove(first), 0);
	KUNIT_EXPECT_PTR_EQ(test, first->telemetry_dir, NULL);
	KUNIT_EXPECT_EQ(test, mpp_dev_remove(second), 0);
	KUNIT_EXPECT_PTR_EQ(test, second->telemetry_dir, NULL);
}

static struct kunit_case mpp_debugfs_cases[] = {
	KUNIT_CASE(mpp_debugfs_counter_read_after_remove_test),
	KUNIT_CASE(mpp_debugfs_remove_without_registration_test),
	KUNIT_CASE(mpp_debugfs_partial_init_unwind_test),
	{}
};

static struct kunit_suite mpp_debugfs_suite = {
	.name = "rockchip-mpp-debugfs-lifetime",
	.init = mpp_debugfs_test_init,
	.exit = mpp_debugfs_test_exit,
	.test_cases = mpp_debugfs_cases,
};
kunit_test_suite(mpp_debugfs_suite);
MODULE_LICENSE("GPL");
