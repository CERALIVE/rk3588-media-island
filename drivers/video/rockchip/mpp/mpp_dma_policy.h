/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef CERALIVE_MPP_DMA_POLICY_H
#define CERALIVE_MPP_DMA_POLICY_H

#include <linux/types.h>

struct mpp_dma_capability {
	u8 streaming_bits;
	u8 coherent_bits;
};

static inline struct mpp_dma_capability mpp_dma_capability_island(void)
{
	return (struct mpp_dma_capability) {
		.streaming_bits = 32,
		.coherent_bits = 32,
	};
}

static inline unsigned int mpp_dma_segment_limit(size_t max_mapping_size)
{
	if (!max_mapping_size || max_mapping_size > U32_MAX)
		return U32_MAX;

	return (unsigned int)max_mapping_size;
}

#endif
