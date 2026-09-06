// SPDX-License-Identifier: GPL-2.0-only
#include <kunit/test.h>
#include <linux/of_platform.h>
#include <linux/pm_runtime.h>
#include "../mpp/mpp_debug.h"
#include "../mpp/mpp_common.h"
#include "runtime_pm_jpeg_types.inc"

static int irq_error;
static int probe_error;
static int remove_calls;
static const struct of_device_id mpp_jpgdec_dt_match[] = { {} };
#define JPGDEC_SESSION_MAX_BUFFERS 40

/* Common probe is the hardware boundary; PM state uses the real kernel API. */
static int pm_jpeg_common_probe(struct mpp_dev *mpp, struct platform_device *pdev)
{
	if (probe_error)
		return probe_error;
	mpp->dev = &pdev->dev;
	pm_runtime_set_autosuspend_delay(mpp->dev, 2000);
	pm_runtime_use_autosuspend(mpp->dev);
	pm_runtime_enable(mpp->dev);
	return 0;
}

static int pm_jpeg_common_remove(struct mpp_dev *mpp)
{
	remove_calls++;
	pm_runtime_disable(mpp->dev);
	return 0;
}

#define mpp_dev_probe pm_jpeg_common_probe
#define mpp_dev_remove pm_jpeg_common_remove
#define devm_request_threaded_irq(...) irq_error
#define jpgdec_procfs_init(...) do { } while (0)
#define mpp_dev_register_srv(...) do { } while (0)
#include "runtime_pm_jpeg_probe.inc"

static void jpeg_probe_pm_lifetime_test(struct kunit *test)
{
	const struct { int common_error; int irq_error; bool enabled; int removes; } cases[] = {
		{ 0, -EBUSY, false, 1 },
		{ 0, 0, true, 0 },
		{ -ENOMEM, 0, false, 0 },
	};
	int i;

	for (i = 0; i < ARRAY_SIZE(cases); i++) {
		struct platform_device *pdev;
		int ret;

		pdev = platform_device_register_simple("island-pm-jpeg", PLATFORM_DEVID_AUTO, NULL, 0);
		KUNIT_ASSERT_FALSE(test, IS_ERR(pdev));
		probe_error = cases[i].common_error;
		irq_error = cases[i].irq_error;
		remove_calls = 0;
		ret = jpgdec_probe(pdev);
		KUNIT_EXPECT_EQ(test, ret, probe_error ? -EINVAL : irq_error);
		KUNIT_EXPECT_EQ_MSG(test, pm_runtime_enabled(&pdev->dev), cases[i].enabled,
				    "probe row %d", i);
		KUNIT_EXPECT_EQ(test, remove_calls, cases[i].removes);
		KUNIT_EXPECT_EQ(test, atomic_read(&pdev->dev.power.usage_count), 0);
		if (pm_runtime_enabled(&pdev->dev))
			pm_jpeg_common_remove(platform_get_drvdata(pdev));
		pm_runtime_dont_use_autosuspend(&pdev->dev);
		platform_device_unregister(pdev);
	}
}

static struct kunit_case pm_jpeg_cases[] = {
	KUNIT_CASE(jpeg_probe_pm_lifetime_test),
	{}
};
static struct kunit_suite pm_jpeg_suite = {
	.name = "rockchip-jpeg-runtime-pm",
	.test_cases = pm_jpeg_cases,
};
kunit_test_suite(pm_jpeg_suite);
MODULE_LICENSE("GPL");
