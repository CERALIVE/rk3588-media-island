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

static void rga_low_userptr_execution_owns_dma_test(struct kunit *test)
{
	struct dma_owner_fixture *f = test->priv;
	struct rga_dma_buffer *mapping;
	struct sg_table *sgt;
	struct scatterlist *sg;
	u64 address;
	u32 ptes[2];
	int use_dma;

	f->origin.type = RGA_VIRTUAL_ADDRESS;
	f->origin.virt_addr = &f->userptr;
	f->preparation.dma_buf = NULL;
	KUNIT_ASSERT_LT(test, (u64)page_to_phys(f->user_pages[1]), 0x100000000ULL);
	KUNIT_ASSERT_EQ(test, rga_mm_get_buffer_info(&f->job, &f->origin,
						     &f->channel, &address), 0);
	KUNIT_EXPECT_EQ(test, address, 0x400080ULL);
	KUNIT_ASSERT_EQ(test, f->channel.iommu_mapping_count, 1);
	KUNIT_EXPECT_EQ(test, f->sg_allocs, 1);
	KUNIT_EXPECT_EQ(test, f->sg_maps, 1);
	KUNIT_EXPECT_EQ(test, f->maps, 0);
	KUNIT_EXPECT_PTR_EQ(test, f->map_dev, f->scheduler.dev);
	KUNIT_EXPECT_EQ(test, f->map_dir, DMA_BIDIRECTIONAL);
	mapping = rga_mm_job_dma_buffer(&f->channel, &f->origin);
	KUNIT_ASSERT_PTR_NE(test, mapping, &f->preparation);
	KUNIT_EXPECT_PTR_EQ(test, mapping->attach, NULL);
	KUNIT_EXPECT_PTR_EQ(test, mapping->map_dev, f->scheduler.dev);
	KUNIT_EXPECT_EQ(test, mapping->dir, DMA_BIDIRECTIONAL);
	sgt = rga_mm_get_rga2_sgt(&f->job, &f->channel, &f->origin,
				 DMA_TO_DEVICE, &use_dma);
	KUNIT_ASSERT_NOT_ERR_OR_NULL(test, sgt);
	KUNIT_ASSERT_PTR_EQ(test, sgt, f->owned_sgt);
	KUNIT_ASSERT_PTR_NE(test, sgt, &f->sgt);
	KUNIT_EXPECT_EQ(test, use_dma, 1);
	KUNIT_EXPECT_EQ(test, f->sg_maps, 1);
	KUNIT_ASSERT_EQ(test, sgt->orig_nents, 2U);
	sg = sgt->sgl;
	KUNIT_EXPECT_PTR_EQ(test, sg_page(sg), f->user_pages[0]);
	KUNIT_EXPECT_EQ(test, sg->offset, 0U);
	KUNIT_EXPECT_EQ(test, sg->length, (unsigned int)PAGE_SIZE);
	KUNIT_ASSERT_NE(test, (u64)sg_phys(sg), 0x30000000ULL);
	sg = sg_next(sg);
	KUNIT_ASSERT_NOT_NULL(test, sg);
	KUNIT_EXPECT_PTR_EQ(test, sg_page(sg), f->user_pages[1]);
	KUNIT_EXPECT_EQ(test, sg->offset, 0U);
	KUNIT_EXPECT_EQ(test, sg->length, (unsigned int)PAGE_SIZE);
	KUNIT_ASSERT_NE(test, (u64)sg_phys(sg), 0x30002000ULL);
	KUNIT_ASSERT_EQ(test, rga_mm_sgt_to_page_table(sgt, ptes, 2, use_dma), 0);
	KUNIT_EXPECT_EQ(test, ptes[0], 0x30000000U);
	KUNIT_EXPECT_EQ(test, ptes[1], 0x30002000U);
	KUNIT_EXPECT_TRUE(test, rga_mm_is_need_mmu(&f->job, &f->origin));
	KUNIT_ASSERT_EQ(test, rga_mm_sync_dma_sg_for_device(&f->origin,
			mapping, &f->job, DMA_TO_DEVICE), 0);
	KUNIT_EXPECT_PTR_EQ(test, f->sync_dev, f->scheduler.dev);
	KUNIT_EXPECT_EQ(test, f->sync_dir, DMA_BIDIRECTIONAL);
	KUNIT_EXPECT_PTR_EQ(test, f->sync_sg, sgt->sgl);
	KUNIT_EXPECT_EQ(test, f->sync_count, 2);
	f->sync_dev = NULL;
	f->sync_dir = DMA_NONE;
	KUNIT_ASSERT_EQ(test, rga_mm_sync_dma_sg_for_cpu(&f->origin,
			mapping, &f->job, DMA_FROM_DEVICE), 0);
	KUNIT_EXPECT_PTR_EQ(test, f->sync_dev, f->scheduler.dev);
	KUNIT_EXPECT_EQ(test, f->sync_dir, DMA_BIDIRECTIONAL);
	KUNIT_EXPECT_PTR_EQ(test, f->sync_sg, sgt->sgl);
	KUNIT_EXPECT_EQ(test, f->sync_count, 2);
	rga_mm_release_job_iommu_mappings(&f->channel);
	rga_mm_release_job_iommu_mappings(&f->channel);
	KUNIT_EXPECT_EQ(test, f->sg_unmaps, 1);
	KUNIT_EXPECT_EQ(test, f->sg_frees, 1);
	KUNIT_EXPECT_FALSE(test, f->freed_while_mapped);
	KUNIT_EXPECT_PTR_EQ(test, f->unmap_dev, f->scheduler.dev);
	KUNIT_EXPECT_EQ(test, f->unmap_dir, DMA_BIDIRECTIONAL);
	KUNIT_EXPECT_EQ(test, f->channel.iommu_mapping_count, 0);
	KUNIT_EXPECT_PTR_EQ(test, f->origin.dma_buffer, &f->preparation);
	KUNIT_EXPECT_PTR_EQ(test, f->preparation.map_dev, f->foreign.dev);
	KUNIT_EXPECT_EQ(test, f->unmaps, 0);
}

static void rga_low_userptr_map_failure_unwinds_test(struct kunit *test)
{
	struct dma_owner_fixture *f = test->priv;
	u64 address = 0xdeadbeef;

	f->origin.type = RGA_VIRTUAL_ADDRESS;
	f->origin.virt_addr = &f->userptr;
	f->preparation.dma_buf = NULL;
	f->map_error = -EIO;
	KUNIT_EXPECT_EQ(test, rga_mm_get_buffer_info(&f->job, &f->origin,
						    &f->channel, &address), -EIO);
	KUNIT_EXPECT_EQ(test, address, 0xdeadbeefULL);
	KUNIT_EXPECT_EQ(test, f->sg_allocs, 1);
	KUNIT_EXPECT_EQ(test, f->sg_maps, 1);
	KUNIT_EXPECT_PTR_EQ(test, f->map_dev, f->scheduler.dev);
	KUNIT_EXPECT_EQ(test, f->map_dir, DMA_BIDIRECTIONAL);
	KUNIT_EXPECT_EQ(test, f->sg_frees, 1);
	KUNIT_EXPECT_PTR_EQ(test, f->owned_sgt, NULL);
	KUNIT_EXPECT_EQ(test, f->sg_unmaps, 0);
	KUNIT_EXPECT_EQ(test, f->channel.iommu_mapping_count, 0);
	KUNIT_EXPECT_PTR_EQ(test, f->channel.iommu_mapping[0].mapping, NULL);
	KUNIT_EXPECT_PTR_EQ(test, f->origin.dma_buffer, &f->preparation);
	KUNIT_EXPECT_PTR_EQ(test, f->preparation.map_dev, f->foreign.dev);
	f->map_error = 0;
	KUNIT_ASSERT_EQ(test, rga_mm_get_buffer_info(&f->job, &f->origin,
						     &f->channel, &address), 0);
	KUNIT_EXPECT_EQ(test, f->channel.iommu_mapping_count, 1);
	rga_mm_release_job_iommu_mappings(&f->channel);
	KUNIT_EXPECT_EQ(test, f->sg_allocs, 2);
	KUNIT_EXPECT_EQ(test, f->sg_frees, 2);
	KUNIT_EXPECT_EQ(test, f->sg_unmaps, 1);
	KUNIT_EXPECT_FALSE(test, f->freed_while_mapped);
	KUNIT_EXPECT_EQ(test, f->unmaps, 0);
}

static struct kunit_case dma_owner_cases[] = {
	KUNIT_CASE(rga_low_userptr_execution_owns_dma_test),
	KUNIT_CASE(rga_low_userptr_map_failure_unwinds_test),
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
