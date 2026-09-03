// SPDX-License-Identifier: GPL-2.0
#include <linux/dma-fence.h>
#include <linux/slab.h>
#include <kunit/test.h>

#include "../rga3/include/rga_fence.h"

struct rga_test_fence {
	struct dma_fence base;
	spinlock_t lock;
};

struct rga_fence_exit_case {
	const char *name;
	int error;
};

static const char *rga_test_fence_name(struct dma_fence *fence)
{
	return "rga-kunit";
}

static void rga_test_fence_release(struct dma_fence *fence)
{
	struct rga_test_fence *test_fence =
		container_of(fence, struct rga_test_fence, base);

	kfree(test_fence);
}

static const struct dma_fence_ops rga_test_fence_ops = {
	.get_driver_name = rga_test_fence_name,
	.get_timeline_name = rga_test_fence_name,
	.release = rga_test_fence_release,
};

static struct dma_fence *rga_test_fence_alloc(void)
{
	struct rga_test_fence *test_fence;

	test_fence = kzalloc(sizeof(*test_fence), GFP_KERNEL);
	if (!test_fence)
		return NULL;

	spin_lock_init(&test_fence->lock);
	dma_fence_init(&test_fence->base, &rga_test_fence_ops,
		       &test_fence->lock, dma_fence_context_alloc(1), 1);

	return &test_fence->base;
}

static void rga_release_fence_terminal_matrix_test(struct kunit *test)
{
	/*
	 * Each row names a terminal route in rga_job.c. Completion and IRQ error
	 * converge in rga_request_release_signal(); every remaining row converges
	 * in rga_request_release_abort() or the final request destructor.
	 */
	static const struct rga_fence_exit_case cases[] = {
		{ "completion", 0 },
		{ "timeout", -ETIMEDOUT },
		{ "irq-error", -EIO },
		{ "explicit-cancel", -ECANCELED },
		{ "submit-time-abort", -EINVAL },
		{ "session-close", -ECANCELED },
		{ "scheduler-shutdown", -ESHUTDOWN },
		{ "driver-remove", -ENODEV },
	};
	size_t i;

	for (i = 0; i < ARRAY_SIZE(cases); i++) {
		struct dma_fence *fence = rga_test_fence_alloc();
		int expected = cases[i].error ?: 1;

		KUNIT_ASSERT_NOT_NULL_MSG(test, fence, "%s", cases[i].name);
		KUNIT_EXPECT_EQ_MSG(test, dma_fence_get_status(fence), 0,
				    "%s must begin unsignalled", cases[i].name);

		rga_dma_fence_signal(fence, cases[i].error);

		KUNIT_EXPECT_TRUE_MSG(test, dma_fence_is_signaled(fence),
				      "%s left the consumer wedged", cases[i].name);
		KUNIT_EXPECT_EQ_MSG(test, dma_fence_get_status(fence), expected,
				    "%s lost its terminal status", cases[i].name);
		dma_fence_put(fence);
	}
}

static struct kunit_case rga_fence_cases[] = {
	KUNIT_CASE(rga_release_fence_terminal_matrix_test),
	{}
};

static struct kunit_suite rga_fence_suite = {
	.name = "rockchip-rga-fence",
	.test_cases = rga_fence_cases,
};

kunit_test_suite(rga_fence_suite);

MODULE_LICENSE("GPL");
