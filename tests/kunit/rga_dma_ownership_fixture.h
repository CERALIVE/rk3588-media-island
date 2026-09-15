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
	struct device *sync_dev;
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
}

#define rga_dma_map_buf_pages owner_map
#define rga_dma_map_buf owner_map
#define rga_dma_unmap_buf owner_unmap
#define rga_dma_unmap_sgt owner_unmap
#define dma_sync_sg_for_device owner_sync
#define dma_sync_sg_for_cpu owner_sync
#define dma_sync_single_for_device(dev, addr, size, dir) ((void)(addr), owner_sync(dev, NULL, 0, dir))
#define dma_sync_single_for_cpu(dev, addr, size, dir) ((void)(addr), owner_sync(dev, NULL, 0, dir))
#define dma_mapping_error(dev, addr) 0
#define rga_mm_is_invalid_dma_buffer(buffer) (!(buffer))
#define rga_mm_lookup_sgt(buffer) ((buffer)->dma_buffer->sgt)
#define rga_mm_alloc_job_virt_sgt(origin, offset) ERR_PTR(-EOPNOTSUPP)
#define rga_mm_alloc_job_phys_sgt(origin) ERR_PTR(-EOPNOTSUPP)
#define rga_alloc_sgt_segment(...) ERR_PTR(-EOPNOTSUPP)
#define rga_dma_map_sgt(...) (-EOPNOTSUPP)
#define rga_dma_map_sgt_pages(...) (-EOPNOTSUPP)
#define rga_free_sgt(sgt) do { } while (0)
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
	f->page = alloc_page(GFP_KERNEL);
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
	return 0;
}

static void dma_owner_exit(struct kunit *test)
{
	struct dma_owner_fixture *f = test->priv;

	rga_mm_release_job_iommu_mappings(&f->channel);
	__free_page(f->page);
}
#endif
