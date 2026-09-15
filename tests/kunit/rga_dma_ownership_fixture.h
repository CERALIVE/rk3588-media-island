/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef RGA_DMA_OWNERSHIP_FIXTURE_H
#define RGA_DMA_OWNERSHIP_FIXTURE_H
#include <kunit/test.h>
#include <kunit/device.h>
#include "../rga3/include/rga_mm.h"
#include "../rga3/include/rga_job.h"
#include "../rga3/include/rga_dma_buf.h"
#include "../rga3/include/rga_common.h"
#include "rga_memory_types.inc"
#include "rga_memory_sg.inc"

struct dma_owner_fixture {
	struct rga_scheduler_t scheduler;
	struct rga_scheduler_t foreign;
	struct rga_job job;
	struct rga_job_buffer channel;
	struct rga_internal_buffer origin;
	struct rga_dma_buffer preparation;
	struct dma_buf dmabuf;
	struct sg_table sgt;
	struct scatterlist sg;
	struct page *page;
	struct page *user_pages[2];
	struct rga_virt_addr userptr;
	struct sg_table *owned_sgt;
	struct device *map_dev;
	struct device *unmap_dev;
	enum dma_data_direction map_dir;
	enum dma_data_direction unmap_dir;
	int sg_allocs;
	int sg_frees;
	int sg_maps;
	int sg_unmaps;
	bool sg_mapped;
	bool freed_while_mapped;
	struct device *sync_dev;
	struct scatterlist *sync_sg;
	int sync_count;
	enum dma_data_direction sync_dir;
	int maps;
	int unmaps;
	int map_error;
};
static struct dma_owner_fixture *dma_owner;
static const struct rga_hw_data dma_owner_rga2 = { .mmu = RGA_MMU };
static const struct rga_hw_data dma_owner_rga3 = { .mmu = RGA_IOMMU };

static int owner_map(struct dma_buf *buf, struct rga_dma_buffer *mapping,
		     enum dma_data_direction dir, struct device *dev)
{
	dma_owner->maps++;
	if (dma_owner->map_error)
		return dma_owner->map_error;
	mapping->map_dev = dev;
	mapping->dir = dir;
	mapping->sgt = &dma_owner->sgt;
	mapping->attach = (struct dma_buf_attachment *)&dma_owner->dmabuf;
	mapping->dma_addr = 0x20000000;
	return 0;
}

static void owner_unmap(struct rga_dma_buffer *mapping)
{
	dma_owner->unmaps++;
}

static void owner_sync(struct device *dev, struct scatterlist *sg,
		       int count, enum dma_data_direction dir)
{
	dma_owner->sync_dev = dev;
	dma_owner->sync_dir = dir;
	dma_owner->sync_sg = sg;
	dma_owner->sync_count = count;
}

static struct sg_table *owner_alloc_sgt(struct page **pages, int count,
				       size_t offset, size_t size,
				       unsigned int max_segment, gfp_t gfp)
{
	struct sg_table *sgt;

	sgt = rga_alloc_sgt_segment(pages, count, offset, size, max_segment, gfp);
	if (!IS_ERR(sgt)) {
		dma_owner->sg_allocs++;
		dma_owner->owned_sgt = sgt;
	}
	return sgt;
}

static int owner_map_sgt_pages(struct sg_table *sgt, struct rga_dma_buffer *mapping,
			       enum dma_data_direction dir, struct device *dev)
{
	struct scatterlist *sg;
	unsigned int i;

	dma_owner->sg_maps++;
	dma_owner->map_dev = dev;
	dma_owner->map_dir = dir;
	if (dma_owner->map_error)
		return dma_owner->map_error;
	for_each_sg(sgt->sgl, sg, sgt->orig_nents, i) {
		sg_dma_address(sg) = 0x30000000 + i * 2 * PAGE_SIZE;
		sg_dma_len(sg) = sg->length;
	}
	mapping->map_dev = dev;
	mapping->dir = dir;
	mapping->sgt = sgt;
	mapping->dma_addr = sg_dma_address(sgt->sgl);
	dma_owner->sg_mapped = true;
	return 0;
}

static void owner_unmap_sgt(struct rga_dma_buffer *mapping)
{
	dma_owner->sg_unmaps++;
	dma_owner->unmap_dev = mapping->map_dev;
	dma_owner->unmap_dir = mapping->dir;
	dma_owner->sg_mapped = false;
}

static void owner_free_sgt(struct sg_table **sgt)
{
	dma_owner->sg_frees++;
	dma_owner->freed_while_mapped |= dma_owner->sg_mapped;
	rga_free_sgt(sgt);
	dma_owner->owned_sgt = NULL;
}

#define rga_dma_map_buf_pages owner_map
#define rga_dma_map_buf owner_map
#define rga_dma_unmap_buf owner_unmap
#define rga_dma_unmap_sgt owner_unmap_sgt
#define dma_sync_sg_for_device owner_sync
#define dma_sync_sg_for_cpu owner_sync
#define dma_sync_single_for_device(dev, addr, size, dir) ((void)(addr), owner_sync(dev, NULL, 0, dir))
#define dma_sync_single_for_cpu(dev, addr, size, dir) ((void)(addr), owner_sync(dev, NULL, 0, dir))
#define dma_mapping_error(dev, addr) 0
#define rga_mm_is_invalid_dma_buffer(buffer) (!(buffer))
#define rga_mm_lookup_sgt(buffer) ((buffer)->dma_buffer->sgt)
#define rga_mm_alloc_job_virt_sgt(origin, offset) ERR_PTR(-EOPNOTSUPP)
#define rga_mm_alloc_job_phys_sgt(origin) ERR_PTR(-EOPNOTSUPP)
#define rga_alloc_sgt_segment owner_alloc_sgt
#define rga_dma_max_segment_size(dev) PAGE_SIZE
#define rga_dma_map_sgt(...) (-EOPNOTSUPP)
#define rga_dma_map_sgt_pages owner_map_sgt_pages
#define rga_free_sgt owner_free_sgt
#define rga_shadow_active(virt) false
#define rga_shadow_copy_to_shadow(virt) do { } while (0)
#define rga_shadow_copy_from_shadow(virt) do { } while (0)
#define rga2_stage_get(job, buffer) ((struct rga_rga2_stage *)ERR_PTR(-EOPNOTSUPP))
#define rga2_user_stage_sgt(job, channel, buffer) ((struct sg_table *)ERR_PTR(-EOPNOTSUPP))
#undef rga_job_err
#define rga_job_err(...) do { } while (0)
#undef rga_job_log
#define rga_job_log(job, fmt, ...) pr_debug(fmt, ##__VA_ARGS__)
#undef DEBUGGER_EN
#define DEBUGGER_EN(mode) false
#define RGA_IOMMU_ADDR_ALIGN 16
#include "rga_memory_source.inc"

static int dma_owner_init(struct kunit *test)
{
	struct dma_owner_fixture *f = kunit_kzalloc(test, sizeof(*f), GFP_KERNEL);

	if (!f)
		return -ENOMEM;
	test->priv = f;
	dma_owner = f;
	f->scheduler.dev = kunit_device_register(test, "rga2-dma-owner");
	if (IS_ERR(f->scheduler.dev))
		return PTR_ERR(f->scheduler.dev);
	f->foreign.dev = kunit_device_register(test, "rga3-dma-owner");
	if (IS_ERR(f->foreign.dev))
		return PTR_ERR(f->foreign.dev);
	f->page = alloc_pages(GFP_KERNEL | GFP_DMA32, 1);
	if (!f->page)
		return -ENOMEM;
	f->scheduler.data = &dma_owner_rga2;
	f->foreign.data = &dma_owner_rga3;
	f->job.scheduler = &f->scheduler;
	f->origin.scheduler = &f->foreign;
	f->origin.type = RGA_DMA_BUFFER;
	f->origin.mm_flag = RGA_MEM_UNDER_4G | RGA_MEM_PHYSICAL_CONTIGUOUS;
	f->origin.dma_buffer = &f->preparation;
	f->preparation.map_dev = f->foreign.dev;
	f->preparation.iommu_mapped = true;
	f->preparation.dma_buf = &f->dmabuf;
	f->preparation.sgt = &f->sgt;
	sg_init_table(&f->sg, 1);
	sg_set_page(&f->sg, f->page, PAGE_SIZE, 0);
	sg_dma_address(&f->sg) = 0x20000000;
	sg_dma_len(&f->sg) = PAGE_SIZE;
	f->sgt.sgl = &f->sg;
	f->sgt.nents = f->sgt.orig_nents = 1;
	f->user_pages[0] = f->page;
	f->user_pages[1] = f->page + 1;
	f->userptr.pages = f->user_pages;
	f->userptr.page_count = 2;
	f->userptr.offset = 128;
	f->userptr.size = PAGE_SIZE + 128;
	f->userptr.addr = 0x400080;
	return 0;
}

static void dma_owner_exit(struct kunit *test)
{
	struct dma_owner_fixture *f = test->priv;

	rga_mm_release_job_iommu_mappings(&f->channel);
	if (f->owned_sgt)
		owner_free_sgt(&f->owned_sgt);
	__free_pages(f->page, 1);
}
#endif
