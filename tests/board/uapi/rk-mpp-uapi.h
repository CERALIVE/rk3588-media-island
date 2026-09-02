/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * rk-mpp-uapi.h — the subset of the Rockchip MPP service UAPI this harness
 * speaks, transcribed from two pinned sources that must agree:
 *
 *   kernel side   include/uapi/linux/rk-mpp.h
 *                 @ armbian/linux-rockchip fd9f82366e235b8afbdf516765210e97d24dce93
 *                 (`MPP_IOC_MAGIC 'v'`, `MPP_IOC_CFG_V1`, `struct mpp_request`)
 *
 *   userspace side osal/inc/mpp_service.h
 *                 @ rockchip-linux/mpp 194af18 — the tree Debian's
 *                 librockchip-mpp1 1.5.0-1 packages
 *                 (`MppServiceCmdType`, `MppReqV1`, `MppServiceCmdCap`)
 *
 * The kernel spells the payload pointer `void __user *data` and userspace
 * spells it `RK_U64 data_ptr`; on aarch64 (the only architecture this harness
 * probes) both are eight bytes at the same offset, so the two declarations are
 * one ABI. The static assertions below pin that, and pin the ioctl magic — if
 * either drifts, this file fails to COMPILE rather than producing a wrong
 * measurement.
 *
 * The client-type constants are kernel-internal (`enum MPP_DEVICE_TYPE`,
 * drivers/video/rockchip/mpp/mpp_common.h at the same SHA) rather than UAPI,
 * but they cross the ioctl boundary as MPP_CMD_INIT_CLIENT_TYPE's payload, so
 * they are part of the contract in practice. Only the three clients the island
 * compiles are listed; do not extend this list speculatively.
 */

#ifndef CERALIVE_RK_MPP_UAPI_H
#define CERALIVE_RK_MPP_UAPI_H

#include <stdint.h>
#include <sys/ioctl.h>

/* include/uapi/linux/rk-mpp.h:13-15 */
#define MPP_IOC_MAGIC 'v'
#define MPP_IOC_CFG_V1 _IOW(MPP_IOC_MAGIC, 1, unsigned int)

/* include/uapi/linux/rk-mpp.h — request flags */
#define MPP_FLAGS_MULTI_MSG 0x00000001u
#define MPP_FLAGS_LAST_MSG 0x00000002u

/*
 * osal/inc/mpp_service.h — MppServiceCmdType. Values, not names, are the wire
 * contract; the island's uapi-parity CI job (todo 7) asserts these against both
 * pinned sources.
 */
enum mpp_service_cmd {
	MPP_CMD_QUERY_BASE = 0,
	MPP_CMD_PROBE_HW_SUPPORT = MPP_CMD_QUERY_BASE + 0,
	MPP_CMD_QUERY_HW_ID = MPP_CMD_QUERY_BASE + 1,
	MPP_CMD_QUERY_CMD_SUPPORT = MPP_CMD_QUERY_BASE + 2,

	MPP_CMD_INIT_BASE = 0x100,
	MPP_CMD_INIT_CLIENT_TYPE = MPP_CMD_INIT_BASE + 0,
	MPP_CMD_INIT_DRIVER_DATA = MPP_CMD_INIT_BASE + 1,
	MPP_CMD_INIT_TRANS_TABLE = MPP_CMD_INIT_BASE + 2,

	MPP_CMD_SEND_BASE = 0x200,
	MPP_CMD_SET_REG_WRITE = MPP_CMD_SEND_BASE + 0,
	MPP_CMD_SET_REG_READ = MPP_CMD_SEND_BASE + 1,

	MPP_CMD_POLL_BASE = 0x300,
	MPP_CMD_POLL_HW_FINISH = MPP_CMD_POLL_BASE + 0,

	MPP_CMD_CONTROL_BASE = 0x400,
	MPP_CMD_RESET_SESSION = MPP_CMD_CONTROL_BASE + 0,
};

/*
 * drivers/video/rockchip/mpp/mpp_common.h:53,55,57 — the three clients the
 * island compiles (RKVENC2, RKVDEC2, JPGDEC). The comment beside each vendor
 * row is the bit it occupies in the PROBE_HW_SUPPORT bitmap.
 */
enum mpp_client_type {
	MPP_CLIENT_RKVDEC = 9,   /* bit 0x00000200 */
	MPP_CLIENT_RKJPEGD = 13, /* bit 0x00002000 */
	MPP_CLIENT_RKVENC = 16,  /* bit 0x00010000 */
};

/*
 * include/uapi/linux/rk-mpp.h:66-72 (kernel) == MppReqV1 (userspace).
 * `data` is the userspace pointer the kernel copies from/into.
 */
struct mpp_request {
	uint32_t cmd;
	uint32_t flags;
	uint32_t size;
	uint32_t offset;
	uint64_t data_ptr;
};

/* osal/inc/mpp_service.h — MppServiceCmdCap, the QUERY_CMD_SUPPORT reply. */
struct mpp_service_cmd_cap {
	uint32_t support_cmd;
	uint32_t query_cmd;
	uint32_t init_cmd;
	uint32_t send_cmd;
	uint32_t poll_cmd;
	uint32_t ctrl_cmd;
};

/*
 * Layout is the contract. A silent struct change here would send a malformed
 * request to a real encoder, so it is a build failure instead.
 */
_Static_assert(sizeof(struct mpp_request) == 24,
	       "struct mpp_request must be 4+4+4+4+8 = 24 bytes on LP64");
_Static_assert(sizeof(struct mpp_service_cmd_cap) == 24,
	       "MppServiceCmdCap must be six u32");
_Static_assert(MPP_IOC_CFG_V1 == 0x40047601u,
	       "MPP_IOC_CFG_V1 must be _IOW('v', 1, unsigned int)");

#endif /* CERALIVE_RK_MPP_UAPI_H */
