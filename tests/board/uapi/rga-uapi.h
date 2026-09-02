/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * rga-uapi.h — the subset of the Rockchip multi_rga UAPI this harness speaks.
 *
 * Transcribed from drivers/video/rockchip/rga3/include/rga.h
 *   @ armbian/linux-rockchip fd9f82366e235b8afbdf516765210e97d24dce93
 *     (rk-6.1-rkr5.1, DRIVER_VERSION 1.3.7)
 *
 * READ THIS BEFORE EXTENDING THE REQUEST STRUCT.
 *
 * The island imports rga3/ from a DIFFERENT tree — the yisding donor
 * rockchip-linux/kernel@b4ef083dc0c3608e744deabb43dc6b781aadbe6e (develop-6.1,
 * DRIVER_VERSION 1.3.11), per docs/media-island/phase0/shim-table.md. The two
 * versions agree on the ioctl numbers, on `struct rga_version_t`,
 * `struct rga_hw_versions_t` and `struct rga_img_info_t`, and on the leading
 * layout of `struct rga_req`; they are NOT known to agree on its tail, which
 * has grown repeatedly (mosaic, OSD, pre-intr, gauss, rgba5551 …).
 *
 * So this header deliberately declares only the STABLE LEADING PREFIX of the
 * blit request and nothing beyond it, and probe-rga-uapi.c passes that prefix
 * inside an over-allocated, zero-filled backing buffer. The kernel's
 * `copy_from_user(&req, arg, sizeof(struct rga_req))` therefore always reads
 * initialised memory of our own, whatever tail the running driver expects, and
 * every field we do not set takes the vendor's own zero default. Hand-copying
 * the full 1.3.7 tail would look more complete and would be a guess about a
 * struct the island does not import.
 *
 * The version ioctls carry their payload size in the ioctl number itself, so a
 * layout mistake in `rga_version_t` / `rga_hw_versions_t` cannot go unnoticed:
 * it would change the encoded number and the driver would answer ENOTTY. The
 * static assertions below pin those numbers to the vendor values.
 */

#ifndef CERALIVE_RGA_UAPI_H
#define CERALIVE_RGA_UAPI_H

#include <stdint.h>
#include <sys/ioctl.h>

/* rga.h:9-21 */
#define RGA_IOC_MAGIC 'r'
#define RGA_IOW(nr, type) _IOW(RGA_IOC_MAGIC, nr, type)
#define RGA_IOR(nr, type) _IOR(RGA_IOC_MAGIC, nr, type)
#define RGA_IOWR(nr, type) _IOWR(RGA_IOC_MAGIC, nr, type)

/* rga.h:23-32 — the legacy (RGA2-era) command numbers are RAW, not _IOC-encoded. */
#define RGA_BLIT_SYNC 0x5017
#define RGA_BLIT_ASYNC 0x5018
#define RGA_FLUSH 0x5019
#define RGA_GET_RESULT 0x501a
#define RGA_GET_VERSION 0x501b
#define RGA_CACHE_FLUSH 0x501c
#define RGA2_GET_VERSION 0x601b

/* rga.h:285-297 */
#define RGA_VERSION_SIZE 16
#define RGA_HW_SIZE 5

struct rga_version_t {
	uint32_t major;
	uint32_t minor;
	uint32_t revision;
	uint8_t str[RGA_VERSION_SIZE];
};

struct rga_hw_versions_t {
	struct rga_version_t version[RGA_HW_SIZE];
	uint32_t size;
};

/*
 * rga.h:14-15 — declared AFTER the structs so the encoded payload size is the
 * one this file actually defines. Note the vendor's own spelling of
 * "DRVIER": it is a typo in the UAPI and is therefore load-bearing.
 */
#define RGA_IOC_GET_DRVIER_VERSION RGA_IOR(0x1, struct rga_version_t)
#define RGA_IOC_GET_HW_VERSION RGA_IOR(0x2, struct rga_hw_versions_t)

/* rga.h:89-96 — scheduler core mask (RGA3 core0/core1, RGA2 core0). */
enum rga_scheduler_core {
	RGA3_SCHEDULER_CORE0 = 1 << 0,
	RGA3_SCHEDULER_CORE1 = 1 << 1,
	RGA2_SCHEDULER_CORE0 = 1 << 2,
	RGA2_SCHEDULER_CORE1 = 1 << 3,
	RGA_CORE_MASK = 0xf,
	RGA_NONE_CORE = 0x0,
};

/* rga.h:106-113 — process-mode selector (`render_mode`). */
enum rga_render_mode {
	RGA_BITBLT_MODE = 0x0,
	RGA_COLOR_PALETTE_MODE = 0x1,
	RGA_COLOR_FILL_MODE = 0x2,
};

/* rga.h:165+ — the two surface formats this probe uses. */
enum rga_surf_format_subset {
	RGA_FORMAT_YCbCr_422_SP = 0x8,
	RGA_FORMAT_YCbCr_420_SP = 0xa, /* NV12 */
	RGA_FORMAT_RGBA_8888 = 0x0,
};

/* rga.h:569-599 — stable across 1.3.7 and 1.3.11. */
struct rga_img_info_t {
	uint64_t yrgb_addr;
	uint64_t uv_addr;
	uint64_t v_addr;
	uint32_t format;

	uint16_t act_w;
	uint16_t act_h;
	uint16_t x_offset;
	uint16_t y_offset;

	uint16_t vir_w;
	uint16_t vir_h;

	uint16_t endian_mode;
	uint16_t alpha_swap;

	uint16_t rotate_mode;
	uint16_t rd_mode;

	uint16_t compact_mode;
	uint16_t is_10b_endian;

	uint16_t enable;
};

/*
 * rga.h:623-632 — the leading prefix of `struct rga_req`, and no more. See the
 * banner: everything past `pat` is left to the zero-filled backing buffer.
 */
struct rga_req_prefix {
	uint8_t render_mode;
	struct rga_img_info_t src;
	struct rga_img_info_t dst;
	struct rga_img_info_t pat;
};

/*
 * The backing allocation for a blit request. Comfortably larger than any
 * released `struct rga_req` (1.3.7 measures well under 1 KiB) so the driver's
 * fixed-size copy_from_user always lands inside memory we own and zeroed.
 */
#define RGA_REQ_BACKING_BYTES 4096

_Static_assert(sizeof(struct rga_version_t) == 28,
	       "rga_version_t must be 3 x u32 + 16 bytes of string");
_Static_assert(sizeof(struct rga_hw_versions_t) == 144,
	       "rga_hw_versions_t must be 5 x rga_version_t + u32");
_Static_assert(sizeof(struct rga_img_info_t) == 56,
	       "rga_img_info_t must be 3 x u64 + u32 + 12 x u16, 8-byte aligned");
_Static_assert(RGA_IOC_GET_DRVIER_VERSION == 0x801c7201u,
	       "RGA_IOC_GET_DRVIER_VERSION must be _IOR('r', 0x1, rga_version_t)");
_Static_assert(RGA_IOC_GET_HW_VERSION == 0x80907202u,
	       "RGA_IOC_GET_HW_VERSION must be _IOR('r', 0x2, rga_hw_versions_t)");
_Static_assert(sizeof(struct rga_req_prefix) <= RGA_REQ_BACKING_BYTES,
	       "the request prefix must fit inside its backing allocation");

#endif /* CERALIVE_RGA_UAPI_H */
