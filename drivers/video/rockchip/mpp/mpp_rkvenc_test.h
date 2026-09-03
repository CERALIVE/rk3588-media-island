/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef __MPP_RKVENC_TEST_H__
#define __MPP_RKVENC_TEST_H__

#include <linux/atomic.h>
#include <linux/types.h>

struct mpp_fault_knob {
	atomic_t armed;
	atomic_t consumed;
};

static inline bool mpp_fault_consume_flag(struct mpp_fault_knob *knob)
{
	if (atomic_cmpxchg(&knob->armed, 1, 0) != 1)
		return false;

	atomic_inc(&knob->consumed);
	return true;
}

static inline unsigned int mpp_fault_consume_delay(struct mpp_fault_knob *knob)
{
	int delay_ms = atomic_xchg(&knob->armed, 0);

	if (delay_ms <= 0)
		return 0;

	atomic_inc(&knob->consumed);
	return delay_ms;
}

#if IS_ENABLED(CONFIG_ROCKCHIP_MPP_CERALIVE_TEST)
int mpp_rkvenc_test_init(void);
void mpp_rkvenc_test_exit(void);
bool mpp_rkvenc_test_fail_service_attach(void);
bool mpp_rkvenc_test_fail_ccu_attach(void);
bool mpp_rkvenc_test_fail_irq_request(void);
bool mpp_rkvenc_test_fail_clock_enable(void);
bool mpp_rkvenc_test_fail_session_alloc(void);
unsigned int mpp_rkvenc_test_completion_delay_ms(void);
#else
static inline int mpp_rkvenc_test_init(void) { return 0; }
static inline void mpp_rkvenc_test_exit(void) { }
static inline bool mpp_rkvenc_test_fail_service_attach(void) { return false; }
static inline bool mpp_rkvenc_test_fail_ccu_attach(void) { return false; }
static inline bool mpp_rkvenc_test_fail_irq_request(void) { return false; }
static inline bool mpp_rkvenc_test_fail_clock_enable(void) { return false; }
static inline bool mpp_rkvenc_test_fail_session_alloc(void) { return false; }
static inline unsigned int mpp_rkvenc_test_completion_delay_ms(void) { return 0; }
#endif

#endif
