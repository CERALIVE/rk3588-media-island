/* SPDX-License-Identifier: GPL-2.0-only */
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define PAGE_SIZE 4096
#define GFP_KERNEL 0
#define GFP_DMA32 0
#define __GFP_NOWARN 0
#define __GFP_NORETRY 0
#define DMA_BIDIRECTIONAL 0
#define RGA2_STAGE_MAX_SIZE (8 * PAGE_SIZE)
#define RGA2_STAGE_SESSION_MAX_SIZE (16 * PAGE_SIZE)
#define RGA2_STAGE_GLOBAL_MAX_SIZE (32 * PAGE_SIZE)
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define ERR_PTR(e) ((void *)(intptr_t)(e))
#define PTR_ERR(p) ((int)(intptr_t)(p))
#define IS_ERR(p) ((uintptr_t)(p) > UINTPTR_MAX - 4096)
#define DECLARE_BITMAP(name, size) unsigned long name[(size) / 64]
#define min_t(t, a, b) ((t)(a) < (t)(b) ? (t)(a) : (t)(b))
typedef uintptr_t dma_addr_t;
typedef long atomic64_t;
static void atomic64_inc(atomic64_t *p) { ++*p; }
static void atomic64_dec(atomic64_t *p) { --*p; }
static void atomic64_add(size_t n, atomic64_t *p) { *p += n; }
static void atomic64_sub(size_t n, atomic64_t *p) { *p -= n; }
static long atomic64_read(atomic64_t *p) { return *p; }
static atomic64_t rga2_stage_copy_in_bytes, rga2_stage_copy_out_bytes;
static atomic64_t rga2_stage_active_count, rga2_stage_active_bytes;
static atomic64_t rga2_stage_reuse_count, rga2_stage_attempt_count;
static atomic64_t rga2_stage_success_count, rga2_stage_failure_count;
static void rga2_stage_update_peak(long n) { (void)n; }
static int rga2_stage_reserve(atomic64_t *p, size_t n, long limit)
{ if (*p + (long)n > limit) return -EDQUOT; *p += n; return 0; }
struct page { unsigned char data[PAGE_SIZE]; unsigned long pfn; int refs; };
struct device { int unused; };
struct rga_rga2_stage { size_t size; struct rga_rga2_stage *next; };
struct rga_session { atomic64_t rga2_stage_active_bytes; };
struct rga_scheduler_t { struct device *dev; };
struct xarray { void *entries[16]; };
struct rga_job {
    struct xarray rga2_user_pages;
    size_t rga2_user_bytes;
    struct rga_rga2_stage *rga2_stage_list;
    struct rga_session *session;
    struct rga_scheduler_t *scheduler;
    bool success;
};
struct scatterlist { struct page *page; dma_addr_t dma; unsigned int length; };
struct sg_table { struct scatterlist *sgl; int orig_nents; };
struct rga_job_buffer { struct sg_table *rga2_user_sgt[3]; int rga2_user_sgt_count; bool writable; };
struct rga_virt_addr { struct page **pages; int result, page_count; size_t offset, size; };
struct rga_internal_buffer { struct rga_virt_addr *virt_addr; };
#define list_for_each_entry(p, head, member) for ((p) = *(head); (p); (p) = (p)->next)
#define xa_for_each(xa, index, entry) for ((index) = 0; (index) < 16; (index)++) \
    if (((entry) = (xa)->entries[index]))
static void *xa_load(struct xarray *xa, unsigned long index) { assert(index < 16); return xa->entries[index]; }
static int store_error, allocation_error, mapping_error, maps, live_pages;
static void *xa_store(struct xarray *xa, unsigned long index, void *value, int flags)
{ (void)flags; if (store_error) return ERR_PTR(-ENOMEM); xa->entries[index] = value; return NULL; }
static int xa_err(void *p) { return IS_ERR(p) ? PTR_ERR(p) : 0; }
static void xa_destroy(struct xarray *xa) { memset(xa, 0, sizeof(*xa)); }
static unsigned long page_to_pfn(struct page *p) { return p->pfn; }
static void get_page(struct page *p) { p->refs++; }
static void put_page(struct page *p) { p->refs--; }
static void set_page_dirty_lock(struct page *p) { (void)p; }
static struct page *alloc_page(int flags)
{ (void)flags; if (allocation_error) return NULL; live_pages++; return calloc(1, sizeof(struct page)); }
static void __free_page(struct page *p) { live_pages--; free(p); }
#define kzalloc(n, flags) calloc(1, (n))
#define kfree(p) free(p)
static void *kmap_local_page(struct page *p) { return p->data; }
static void kunmap_local(void *p) { (void)p; }
static void copy_highpage(struct page *to, struct page *from) { memcpy(to->data, from->data, PAGE_SIZE); }
static dma_addr_t dma_map_page(struct device *dev, struct page *p, int offset, int size, int dir)
{ (void)dev; (void)offset; (void)size; (void)dir; if (mapping_error) return UINTPTR_MAX; maps++; return (uintptr_t)p; }
static bool dma_mapping_error(struct device *dev, dma_addr_t dma) { (void)dev; return dma == UINTPTR_MAX; }
static void dma_unmap_page(struct device *dev, dma_addr_t dma, int size, int dir)
{ (void)dev; (void)dma; (void)size; (void)dir; maps--; }
static void bitmap_set(unsigned long *bits, size_t start, size_t len)
{ for (size_t i = start; i < start + len; i++) bits[i / 64] |= 1UL << (i % 64); }
static unsigned long find_next_bit(unsigned long *bits, size_t size, size_t start)
{ while (start < size && !(bits[start / 64] & (1UL << (start % 64)))) start++; return start; }
static unsigned long find_next_zero_bit(unsigned long *bits, size_t size, size_t start)
{ while (start < size && (bits[start / 64] & (1UL << (start % 64)))) start++; return start; }
static bool bitmap_empty(unsigned long *bits, size_t size) { return find_next_bit(bits, size, 0) == size; }
static struct page *rga_virt_original_page(struct rga_virt_addr *virt, int i) { return virt->pages[i]; }
static bool rga2_stage_job_succeeded(struct rga_job *job) { return job->success; }
static int sg_alloc_table(struct sg_table *sgt, int count, int flags)
{ (void)flags; sgt->sgl = calloc(count, sizeof(*sgt->sgl)); sgt->orig_nents = count; return sgt->sgl ? 0 : -ENOMEM; }
static void rga_free_sgt(struct sg_table **sgt) { free((*sgt)->sgl); free(*sgt); *sgt = NULL; }
#define for_each_sg(list, sg, n, i) for ((i) = 0, (sg) = (list); (i) < (n); (i)++, (sg)++)
static void sg_set_page(struct scatterlist *sg, struct page *p, int size, int offset)
{ (void)size; (void)offset; sg->page = p; }
#define sg_dma_address(sg) ((sg)->dma)
#define sg_dma_len(sg) ((sg)->length)

#include "rga_user_stage.h"

int main(void)
{
    struct page origin = { .pfn = 1 };
    struct page *pages[] = { &origin };
    struct rga_session session = { 0 };
    struct device dev = { 0 };
    struct rga_scheduler_t scheduler = { .dev = &dev };
    struct rga_job job = { .session = &session, .scheduler = &scheduler, .success = true };
    struct rga_job_buffer first = { .writable = true }, alias = { .writable = true };
    struct rga_virt_addr a = { .pages = pages, .result = 1, .page_count = 1, .offset = 16, .size = 32 };
    struct rga_virt_addr b = { .pages = pages, .result = 1, .page_count = 1, .offset = 32, .size = 32 };
    struct rga_internal_buffer ba = { .virt_addr = &a }, bb = { .virt_addr = &b };
    memset(origin.data, 0x5a, PAGE_SIZE);
    struct sg_table *sa = rga2_user_stage_sgt(&job, &first, &ba);
    struct sg_table *sb = rga2_user_stage_sgt(&job, &alias, &bb);
    assert(!IS_ERR(sa) && !IS_ERR(sb));
    assert(sa->sgl->dma == sb->sgl->dma && job.rga2_user_bytes == PAGE_SIZE);
    memset(sa->sgl->page->data + 16, 0xa5, 48);
    origin.data[8] = 0x33;
    rga_free_sgt(&sa); rga_free_sgt(&sb);
    rga2_user_stage_release(&job);
    assert(origin.data[8] == 0x33 && origin.data[15] == 0x5a && origin.data[64] == 0x5a);
    for (int i = 16; i < 64; i++) assert(origin.data[i] == 0xa5);
    for (int fault = 0; fault < 3; fault++) {
        allocation_error = fault == 0; mapping_error = fault == 1; store_error = fault == 2;
        assert(IS_ERR(rga2_user_stage_page(&job, &origin)));
        rga2_user_stage_release(&job);
        assert(!maps && !live_pages && !rga2_stage_active_bytes && !session.rga2_stage_active_bytes);
    }
    allocation_error = mapping_error = store_error = 0;
    job.rga2_user_bytes = RGA2_STAGE_MAX_SIZE;
    assert(PTR_ERR(rga2_user_stage_page(&job, &origin)) == -E2BIG);
    job.rga2_user_bytes = 0;
    session.rga2_stage_active_bytes = RGA2_STAGE_SESSION_MAX_SIZE;
    assert(PTR_ERR(rga2_user_stage_page(&job, &origin)) == -EDQUOT);
    session.rga2_stage_active_bytes = 0;
    struct rga2_user_page *entry = rga2_user_stage_page(&job, &origin);
    assert(!IS_ERR(entry));
    bitmap_set(entry->writable, 0, PAGE_SIZE);
    memset(entry->page->data, 0, PAGE_SIZE);
    job.success = false;
    rga2_user_stage_release(&job);
    assert(origin.data[8] == 0x33 && origin.data[16] == 0xa5);
    assert(!origin.refs && !maps && !live_pages && !rga2_stage_active_bytes);
    puts("PASS: shared USERPTR aliases, partial writes, cancellation, allocation/map/xarray failures, quotas");
}
