/* SPDX-License-Identifier: GPL-2.0 */
#ifndef __ROCKCHIP_RGA_REQUEST_VALIDATION_H__
#define __ROCKCHIP_RGA_REQUEST_VALIDATION_H__

#include <linux/errno.h>
#include <linux/overflow.h>
#include <linux/types.h>

#define RGA_REQUEST_FORMAT_NV12 0x0a
#define RGA_REQUEST_FORMAT_RESERVED_17 0x17
#define RGA_REQUEST_FORMAT_RESERVED_27 0x27
#define RGA_REQUEST_FORMAT_MAX 0x34
#define RGA_REQUEST_FORMAT_UNKNOWN 0x100
#define RGA_REQUEST_MAX_PLANES 3

struct rga_plane_buffer {
	u64 descriptor;
	u64 offset;
	u64 size;
	u64 required;
};

struct rga_plane_request {
	u32 active_width;
	u32 active_height;
	u32 x_offset;
	u32 y_offset;
	u32 width_stride;
	u32 height_stride;
	u32 format;
	u32 plane_count;
	u32 byte_stride;
	u32 byte_stride_align;
	u32 max_byte_stride;
	bool format_supported;
	struct rga_plane_buffer planes[RGA_REQUEST_MAX_PLANES];
};

static inline bool rga_request_format_valid(u32 format)
{
	return format <= RGA_REQUEST_FORMAT_MAX &&
		format != RGA_REQUEST_FORMAT_RESERVED_17 &&
		format != RGA_REQUEST_FORMAT_RESERVED_27;
}

static inline int rga_user_request_validate(u32 id, u32 task_count,
					    u64 task_pointer,
					    u32 task_count_max)
{
	if (!id || !task_count || !task_pointer || task_count > task_count_max)
		return -EINVAL;

	return 0;
}

static inline int
rga_plane_request_validate(const struct rga_plane_request *plane)
{
	u32 width_end;
	u32 height_end;
	u32 i;

	if (!plane->active_width || !plane->active_height ||
	    !plane->plane_count || plane->plane_count > RGA_REQUEST_MAX_PLANES)
		return -EINVAL;
	if (check_add_overflow(plane->active_width, plane->x_offset,
			       &width_end) ||
	    check_add_overflow(plane->active_height, plane->y_offset,
			       &height_end) ||
	    plane->width_stride < width_end ||
	    plane->height_stride < height_end)
		return -EINVAL;
	if (!rga_request_format_valid(plane->format) ||
	    !plane->format_supported || !plane->byte_stride ||
	    !plane->byte_stride_align ||
	    !IS_ALIGNED(plane->byte_stride, plane->byte_stride_align) ||
	    plane->byte_stride > plane->max_byte_stride)
		return -EINVAL;

	for (i = 0; i < RGA_REQUEST_MAX_PLANES; i++) {
		const struct rga_plane_buffer *buffer = &plane->planes[i];
		u64 end;

		if (i >= plane->plane_count) {
			if (buffer->descriptor || buffer->offset ||
			    buffer->size || buffer->required)
				return -EINVAL;
			continue;
		}
		if (!buffer->descriptor || !buffer->size || !buffer->required ||
		    check_add_overflow(buffer->offset, buffer->required, &end) ||
		    end > buffer->size)
			return -EINVAL;
	}

	return 0;
}

#endif
