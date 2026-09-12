/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef __RGA_TEST_H__
#define __RGA_TEST_H__

#include <linux/atomic.h>
#include <linux/types.h>

struct rga_fault_knob {
	atomic_t armed;
	atomic_t consumed;
};

static inline bool rga_fault_consume_flag(struct rga_fault_knob *knob)
{
	if (atomic_cmpxchg(&knob->armed, 1, 0) != 1)
		return false;

	atomic_inc(&knob->consumed);
	return true;
}

struct rga_scheduler_t;

#if IS_ENABLED(CONFIG_ROCKCHIP_RGA_CERALIVE_TEST)
int rga_test_init(void);
void rga_test_exit(void);
bool rga_test_irq_timeout(void);
bool rga_test_hang_task(void);
bool rga_test_fail_reset(void);
bool rga_test_inject_iommu_fault(void);
bool rga_iommu_test_prepare(struct rga_scheduler_t *scheduler);
void rga_iommu_test_fault(struct rga_scheduler_t *scheduler);
#else
static inline int rga_test_init(void) { return 0; }
static inline void rga_test_exit(void) { }
static inline bool rga_test_irq_timeout(void) { return false; }
static inline bool rga_test_hang_task(void) { return false; }
static inline bool rga_test_fail_reset(void) { return false; }
static inline bool rga_test_inject_iommu_fault(void) { return false; }
static inline bool rga_iommu_test_prepare(struct rga_scheduler_t *scheduler) { return false; }
static inline void rga_iommu_test_fault(struct rga_scheduler_t *scheduler) { }
#endif

#endif
