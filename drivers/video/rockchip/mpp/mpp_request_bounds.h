/* SPDX-License-Identifier: (GPL-2.0+ OR MIT) */
#ifndef __ROCKCHIP_MPP_REQUEST_BOUNDS_H__
#define __ROCKCHIP_MPP_REQUEST_BOUNDS_H__

#include <linux/align.h>
#include <linux/errno.h>
#include <linux/minmax.h>
#include <linux/types.h>

struct mpp_req_class {
	u32 base_s;
	u32 base_e;
};

struct mpp_req_part {
	u32 offset;
	u32 size;
};

struct mpp_req_coverage {
	u32 bytes;
	u32 lo;
	u32 hi;
};

static inline int mpp_req_shape(u32 offset, u32 size)
{
	u32 end;

	if (size < sizeof(u32))
		return -EINVAL;
	if (!IS_ALIGNED(offset, sizeof(u32)) ||
	    !IS_ALIGNED(size, sizeof(u32)))
		return -EINVAL;
	end = offset + size - sizeof(u32);
	if (end < offset)
		return -EINVAL;

	return 0;
}

static inline int mpp_req_element_count(u32 size, u32 element_size,
					u32 capacity, u32 *count)
{
	if (!element_size || !size || size % element_size ||
	    size / element_size > capacity)
		return -EINVAL;

	*count = size / element_size;
	return 0;
}

static inline int mpp_req_count_room(u32 count, u32 capacity)
{
	return count < capacity ? 0 : -EINVAL;
}

static inline int mpp_iova_offset_check(size_t mapped_len, u32 offset)
{
	return mapped_len && offset < mapped_len ? 0 : -EINVAL;
}

static inline int mpp_req_buffer_check(u32 offset, u32 size, u32 base,
				       u32 max_size, u32 off_s, u32 off_e,
				       u32 *checked_size)
{
	u32 req_off;

	if (mpp_req_shape(offset, size))
		return -EINVAL;
	if (offset < base)
		return -EINVAL;
	req_off = offset - base;
	if (size > (u32)-1 - req_off)
		return -EINVAL;
	if (req_off + size < off_s || max_size < off_e || req_off > max_size)
		return -EINVAL;

	*checked_size = min(size, max_size - req_off);
	return 0;
}

static inline int mpp_req_class_part(u32 offset, u32 size,
				     const struct mpp_req_class *class,
				     struct mpp_req_part *part)
{
	u32 end;
	u32 start;

	if (mpp_req_shape(offset, size))
		return -EINVAL;
	end = offset + size - sizeof(u32);
	start = max(offset, class->base_s);
	end = min(end, class->base_e);
	if (end < start)
		return -EINVAL;

	part->offset = start;
	part->size = end - start + sizeof(u32);
	return 0;
}

static inline void mpp_req_coverage_init(struct mpp_req_coverage *coverage)
{
	coverage->bytes = 0;
	coverage->lo = (u32)-1;
	coverage->hi = 0;
}

static inline void mpp_req_coverage_add(struct mpp_req_coverage *coverage,
					const struct mpp_req_part *part)
{
	coverage->lo = min(coverage->lo, part->offset);
	coverage->hi = max(coverage->hi, part->offset + part->size);
	coverage->bytes += part->size;
}

static inline int mpp_req_coverage_check(u32 offset, u32 size,
					 const struct mpp_req_class *classes,
					 u32 class_count,
					 const struct mpp_req_coverage *coverage)
{
	u32 map_s = (u32)-1;
	u32 map_e = 0;
	u32 owned = 0;
	u32 request_e;
	u32 i;

	if (mpp_req_shape(offset, size) || !class_count || !coverage->bytes)
		return -EINVAL;
	request_e = offset + size;

	for (i = 0; i < class_count; i++) {
		u32 class_s = classes[i].base_s;
		u32 class_e = classes[i].base_e + sizeof(u32);

		map_s = min(map_s, class_s);
		map_e = max(map_e, class_e);
		if (class_e <= coverage->lo || class_s >= coverage->hi)
			continue;
		if (class_s < coverage->lo || class_e > coverage->hi)
			return -EINVAL;
		owned += class_e - class_s;
	}

	if (offset < map_s || request_e > map_e)
		return -EINVAL;
	if (coverage->bytes != coverage->hi - coverage->lo &&
	    owned != coverage->bytes)
		return -EINVAL;

	return 0;
}

static inline int mpp_req_window_offset(u32 offset, u32 size, u32 base,
					u32 buffer_size, u32 *window_offset)
{
	u32 start;

	if (mpp_req_shape(offset, size) || !buffer_size || offset < base)
		return -EINVAL;
	start = offset - base;
	if (start >= buffer_size || size > buffer_size - start)
		return -EINVAL;

	*window_offset = start;
	return 0;
}

#endif
