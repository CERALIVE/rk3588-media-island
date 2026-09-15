// SPDX-License-Identifier: GPL-2.0-only
#include "rga_dma_ownership_fixture.h"

static void rga_low_execution_owns_dma_test(struct kunit *test)
{
	struct dma_owner_fixture *f = test->priv;
	struct rga_dma_buffer *mapping;
	struct sg_table *sgt;
	int use_dma;
	u64 address;
	u32 pte;

	/* Given: a low, contiguous buffer prepared against the foreign RGA3 device. */
	KUNIT_ASSERT_NE(test, (u64)sg_phys(&f->sg), 0x20000000ULL);
	/* When: RGA2 binds the channel and builds its execution PTE. */
	KUNIT_ASSERT_EQ(test, rga_mm_get_buffer_info(&f->job, &f->origin,
						     &f->channel, &address), 0);
	sgt = rga_mm_get_rga2_sgt(&f->job, &f->channel, &f->origin,
				 DMA_TO_DEVICE, &use_dma);
	KUNIT_ASSERT_NOT_ERR_OR_NULL(test, sgt);
	KUNIT_ASSERT_EQ(test, rga_mm_sgt_to_page_table(sgt, &pte, 1, use_dma), 0);
	/* Then: the DMA address, not the original PFN, reaches hardware. */
	KUNIT_EXPECT_GT(test, f->maps, 0);
	KUNIT_EXPECT_TRUE(test, rga_mm_is_need_mmu(&f->job, &f->origin));
	KUNIT_EXPECT_EQ(test, pte, 0x20000000U);
	mapping = rga_mm_job_dma_buffer(&f->channel, &f->origin);
	KUNIT_EXPECT_PTR_EQ(test, mapping->map_dev, f->scheduler.dev);
	KUNIT_ASSERT_EQ(test, rga_mm_sync_dma_sg_for_device(&f->origin,
			mapping, &f->job, DMA_TO_DEVICE), 0);
	KUNIT_EXPECT_PTR_EQ(test, f->sync_dev, f->scheduler.dev);
	KUNIT_EXPECT_EQ(test, f->sync_dir, DMA_BIDIRECTIONAL);
	KUNIT_ASSERT_EQ(test, rga_mm_sync_dma_sg_for_cpu(&f->origin,
			mapping, &f->job, DMA_FROM_DEVICE), 0);
	KUNIT_EXPECT_PTR_EQ(test, f->sync_dev, f->scheduler.dev);
	KUNIT_EXPECT_EQ(test, f->sync_dir, DMA_BIDIRECTIONAL);
	rga_mm_release_job_iommu_mappings(&f->channel);
	KUNIT_EXPECT_EQ(test, f->unmaps, 1);
}

static void rga_low_execution_map_failure_test(struct kunit *test)
{
	struct dma_owner_fixture *f = test->priv;
	u64 address;

	f->map_error = -EIO;
	KUNIT_EXPECT_EQ(test, rga_mm_get_buffer_info(&f->job, &f->origin,
						    &f->channel, &address), -EIO);
	KUNIT_EXPECT_EQ(test, f->channel.iommu_mapping_count, 0);
	KUNIT_EXPECT_PTR_EQ(test, f->origin.dma_buffer, &f->preparation);
}

static struct kunit_case dma_owner_cases[] = {
	KUNIT_CASE(rga_low_execution_owns_dma_test),
	KUNIT_CASE(rga_low_execution_map_failure_test),
	{}
};
static struct kunit_suite dma_owner_suite = {
	.name = "rockchip-rga-dma-ownership",
	.init = dma_owner_init,
	.exit = dma_owner_exit,
	.test_cases = dma_owner_cases,
};
kunit_test_suite(dma_owner_suite);
MODULE_LICENSE("GPL");
