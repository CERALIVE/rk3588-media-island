/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef CERALIVE_RGA_DMA_POLICY_H
#define CERALIVE_RGA_DMA_POLICY_H

#include <linux/types.h>

struct rga_dma_capability {
	u8 streaming_bits;
	u8 coherent_bits;
};

static inline struct rga_dma_capability rga3_dma_capability(void)
{
	return (struct rga_dma_capability) {
		.streaming_bits = 40,
		.coherent_bits = 32,
	};
}

static inline struct rga_dma_capability rga2_dma_capability(void)
{
	return (struct rga_dma_capability) {
		.streaming_bits = 32,
		.coherent_bits = 32,
	};
}

static inline unsigned int rga_staging_segment_limit(size_t max_mapping_size)
{
	if (!max_mapping_size || max_mapping_size > UINT_MAX)
		return UINT_MAX;

	return (unsigned int)max_mapping_size;
}

#endif
