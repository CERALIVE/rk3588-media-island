/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef _ROCKCHIP_MPP_TELEMETRY_H
#define _ROCKCHIP_MPP_TELEMETRY_H

#include <linux/bitops.h>
#include <linux/kernel.h>

struct mpp_session_telemetry_values {
	u32 client;
	u64 tasks;
	u64 bytes;
};

static inline bool mpp_telemetry_mark_once(unsigned long *state,
					   unsigned int bit)
{
	return !test_and_set_bit(bit, state);
}

static inline int mpp_telemetry_format_load(char *buf, size_t size,
					    const char *name, u32 load,
					    u32 load_frac, u32 utilization,
					    u32 utilization_frac)
{
	return scnprintf(buf, size,
			 "%-25s load: %3d.%02d%% utilization: %3d.%02d%%\n",
			 name, load, load_frac, utilization, utilization_frac);
}

static inline int
mpp_telemetry_format_session(char *buf, size_t size,
			     const struct mpp_session_telemetry_values *values)
{
	return scnprintf(buf, size, "client:\t%u\ntasks:\t%llu\nbytes:\t%llu\n",
			 values->client, values->tasks, values->bytes);
}

#endif
