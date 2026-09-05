/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef ROCKCHIP_MEDIA_MAP_H
#define ROCKCHIP_MEDIA_MAP_H

#include <linux/errno.h>
#include <linux/dma-buf.h>
#include <linux/iosys-map.h>
#include <linux/vmalloc.h>

static inline int media_map_read(void *dst, const struct iosys_map *map,
				size_t span, size_t offset, size_t bytes)
{
	if (iosys_map_is_null(map) || offset > span || bytes > span - offset)
		return -EINVAL;
	iosys_map_memcpy_from(dst, map, offset, bytes);
	return 0;
}

/* Only for RAM mappings created by vmap(), not exporter-owned dma-buf maps. */
static inline void media_vunmap(struct iosys_map *map)
{
	if (iosys_map_is_set(map))
		vunmap(map->vaddr);
	iosys_map_clear(map);
}

static inline void media_dma_vunmap(struct dma_buf *buffer, struct iosys_map *map)
{
	dma_buf_vunmap_unlocked(buffer, map);
	iosys_map_clear(map);
}

#endif
