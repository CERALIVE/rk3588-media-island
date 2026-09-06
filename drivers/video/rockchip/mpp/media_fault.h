/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef ROCKCHIP_MEDIA_FAULT_H
#define ROCKCHIP_MEDIA_FAULT_H

#include <linux/device.h>
#include <linux/ratelimit.h>

static inline void media_fault_init(struct ratelimit_state *state)
{
	ratelimit_state_init(state, 5 * HZ, 10);
	/* Suppression summaries must not bypass the device's line budget. */
	ratelimit_set_flags(state, RATELIMIT_MSG_ON_RELEASE);
}

#define media_fault_report(dev, state, fmt, ...) ({ \
	bool emitted = __ratelimit(state); \
	if (emitted) \
		dev_err_ratelimited(dev, fmt, ##__VA_ARGS__); \
	emitted; \
})

#define mpp_fault(mpp, fmt, ...) \
	media_fault_report((mpp)->dev, &(mpp)->fault_limit, fmt, ##__VA_ARGS__)
#define rga_fault(sched, fmt, ...) \
	media_fault_report((sched)->dev, &(sched)->fault_limit, fmt, ##__VA_ARGS__)
#define rga_job_fault(job, fmt, ...) \
	rga_fault((job)->scheduler, "task %d: " fmt, (job)->request_id, ##__VA_ARGS__)

#endif
