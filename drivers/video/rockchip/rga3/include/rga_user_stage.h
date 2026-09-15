/* SPDX-License-Identifier: GPL-2.0-only */
/* Included by rga_mm.c: the job pool keys original PFNs, not virtual ranges. */
#ifndef RGA_USER_STAGE_H
#define RGA_USER_STAGE_H

struct rga2_user_page {
	struct page *origin;
	struct page *page;
	struct device *dev;
	dma_addr_t dma;
	DECLARE_BITMAP(writable, PAGE_SIZE);
};

static void rga2_user_stage_release(struct rga_job *job)
{
	struct rga2_user_page *entry;
	unsigned long index;
	bool success = rga2_stage_job_succeeded(job);

	xa_for_each(&job->rga2_user_pages, index, entry) {
		unsigned long start = 0, end;
		void *origin, *copy;

		dma_unmap_page(entry->dev, entry->dma, PAGE_SIZE, DMA_BIDIRECTIONAL);
		if (success && !bitmap_empty(entry->writable, PAGE_SIZE)) {
			origin = kmap_local_page(entry->origin);
			copy = kmap_local_page(entry->page);
			while ((start = find_next_bit(entry->writable, PAGE_SIZE, start)) < PAGE_SIZE) {
				end = find_next_zero_bit(entry->writable, PAGE_SIZE, start);
				memcpy(origin + start, copy + start, end - start);
				atomic64_add(end - start, &rga2_stage_copy_out_bytes);
				start = end;
			}
			kunmap_local(copy);
			kunmap_local(origin);
			set_page_dirty_lock(entry->origin);
		}
		put_page(entry->origin);
		__free_page(entry->page);
		kfree(entry);
		atomic64_dec(&rga2_stage_active_count);
	}
	xa_destroy(&job->rga2_user_pages);
	atomic64_sub(job->rga2_user_bytes, &rga2_stage_active_bytes);
	atomic64_sub(job->rga2_user_bytes, &job->session->rga2_stage_active_bytes);
	job->rga2_user_bytes = 0;
}

static struct rga2_user_page *rga2_user_stage_page(struct rga_job *job, struct page *origin)
{
	struct rga2_user_page *entry;
	struct rga_rga2_stage *stage;
	size_t bytes = job->rga2_user_bytes;
	int ret;

	entry = xa_load(&job->rga2_user_pages, page_to_pfn(origin));
	if (entry) {
		atomic64_inc(&rga2_stage_reuse_count);
		return entry;
	}
	atomic64_inc(&rga2_stage_attempt_count);
	list_for_each_entry(stage, &job->rga2_stage_list, node)
		bytes += stage->size;
	if (bytes > RGA2_STAGE_MAX_SIZE - PAGE_SIZE)
		return ERR_PTR(-E2BIG);
	ret = rga2_stage_reserve(&job->session->rga2_stage_active_bytes,
				 PAGE_SIZE, RGA2_STAGE_SESSION_MAX_SIZE);
	if (ret)
		return ERR_PTR(ret);
	ret = rga2_stage_reserve(&rga2_stage_active_bytes, PAGE_SIZE, RGA2_STAGE_GLOBAL_MAX_SIZE);
	if (ret)
		goto uncharge_session;
	entry = kzalloc(sizeof(*entry), GFP_KERNEL);
	if (!entry) {
		ret = -ENOMEM;
		goto uncharge_global;
	}
	entry->page = alloc_page(GFP_KERNEL | GFP_DMA32 | __GFP_NOWARN | __GFP_NORETRY);
	if (!entry->page) {
		ret = -ENOMEM;
		goto free_entry;
	}
	copy_highpage(entry->page, origin);
	entry->dev = job->scheduler->dev;
	entry->dma = dma_map_page(entry->dev, entry->page, 0, PAGE_SIZE, DMA_BIDIRECTIONAL);
	if (dma_mapping_error(entry->dev, entry->dma)) {
		ret = -EIO;
		goto free_page;
	}
	ret = xa_err(xa_store(&job->rga2_user_pages, page_to_pfn(origin), entry, GFP_KERNEL));
	if (ret)
		goto unmap;
	get_page(origin);
	entry->origin = origin;
	job->rga2_user_bytes += PAGE_SIZE;
	atomic64_inc(&rga2_stage_success_count);
	atomic64_inc(&rga2_stage_active_count);
	atomic64_add(PAGE_SIZE, &rga2_stage_copy_in_bytes);
	rga2_stage_update_peak(atomic64_read(&rga2_stage_active_bytes));
	return entry;

unmap:
	dma_unmap_page(entry->dev, entry->dma, PAGE_SIZE, DMA_BIDIRECTIONAL);
free_page:
	__free_page(entry->page);
free_entry:
	kfree(entry);
uncharge_global:
	atomic64_sub(PAGE_SIZE, &rga2_stage_active_bytes);
uncharge_session:
	atomic64_sub(PAGE_SIZE, &job->session->rga2_stage_active_bytes);
	atomic64_inc(&rga2_stage_failure_count);
	return ERR_PTR(ret);
}

static struct sg_table *rga2_user_stage_sgt(struct rga_job *job,
					   struct rga_job_buffer *channel,
					   struct rga_internal_buffer *buffer)
{
	struct rga_virt_addr *virt = buffer->virt_addr;
	struct rga2_user_page *entry;
	struct sg_table *sgt;
	struct scatterlist *sg;
	size_t start, end;
	int i, ret;

	if (!virt || !virt->pages || virt->result != virt->page_count)
		return ERR_PTR(-EOPNOTSUPP);
	if (channel->rga2_user_sgt_count == ARRAY_SIZE(channel->rga2_user_sgt))
		return ERR_PTR(-E2BIG);
	sgt = kzalloc(sizeof(*sgt), GFP_KERNEL);
	if (!sgt)
		return ERR_PTR(-ENOMEM);
	ret = sg_alloc_table(sgt, virt->page_count, GFP_KERNEL);
	if (ret) {
		kfree(sgt);
		return ERR_PTR(ret);
	}
	/* Each DMA mapping belongs to the shared page; the SG only describes it. */
	for_each_sg(sgt->sgl, sg, sgt->orig_nents, i) {
		entry = rga2_user_stage_page(job, rga_virt_original_page(virt, i));
		if (IS_ERR(entry)) {
			ret = PTR_ERR(entry);
			rga_free_sgt(&sgt);
			return ERR_PTR(ret);
		}
		sg_set_page(sg, entry->page, PAGE_SIZE, 0);
		sg_dma_address(sg) = entry->dma;
		sg_dma_len(sg) = PAGE_SIZE;
		if (channel->writable) {
			start = i ? 0 : virt->offset;
			end = min_t(size_t, PAGE_SIZE, virt->offset + virt->size - (size_t)i * PAGE_SIZE);
			bitmap_set(entry->writable, start, end - start);
		}
	}
	channel->rga2_user_sgt[channel->rga2_user_sgt_count++] = sgt;
	return sgt;
}

#endif
