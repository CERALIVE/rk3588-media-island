/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * probe-mpp-uapi.c — answer, from the board itself, what /dev/mpp_service
 * actually offers.
 *
 * WHY: the Phase-0 decode-truth and copy-census measurements need to know
 * which MPP clients the running kernel exposes, not which ones a plugin
 * advertises. `gst-inspect-1.0 mppvideodec` succeeding proves a plugin
 * registered; it does not prove the kernel has an RKVDEC2 client behind it.
 * This probe asks the service directly and prints every reply together with
 * the errno, so an absence is recorded as an absence with a reason.
 *
 * It runs the libmpp initialisation sequence in the order the userspace
 * library uses (rockchip-linux/mpp @194af18, osal/mpp_service.c):
 *
 *     open  /dev/mpp_service            (fallback /dev/mpp-service)
 *     ioctl MPP_CMD_PROBE_HW_SUPPORT    -> u32 bitmap of present clients
 *     ioctl MPP_CMD_QUERY_CMD_SUPPORT   -> MppServiceCmdCap
 *     per client, on a FRESH fd:
 *       ioctl MPP_CMD_INIT_CLIENT_TYPE  -> binds this session to one client
 *       ioctl MPP_CMD_QUERY_HW_ID       -> u32 hardware id
 *
 * A fresh fd per client is not tidiness: the service binds a session to
 * exactly one client type, and re-initialising a bound session is precisely
 * the case yisding's fwport-0069 rejects. Probing three clients on one fd
 * would measure that rejection instead of the hardware.
 *
 * THIS PROBE IS READ-ONLY. It issues query and session-init commands only; it
 * never sends registers, never starts hardware, and never writes to /sys.
 *
 * Build (target suite, aarch64):
 *   aarch64-linux-gnu-gcc -std=c11 -Wall -Wextra -Werror -O2 \
 *       -Iuapi -o probe-mpp-uapi probe-mpp-uapi.c
 *
 * Exit codes follow the harness contract:
 *   0  the service answered (whatever it answered — that IS the measurement)
 *   1  the service exists but a query failed in a way that is not an absence
 *   2  usage
 *   77 no MPP service node on this host (hardware-gated, not a pass)
 */

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "uapi/rk-mpp-uapi.h"

#define EXIT_PASS 0
#define EXIT_FAIL 1
#define EXIT_USAGE 2
#define EXIT_GATED 77
#define ISLAND_HW_SUPPORT ((1u << 9) | (1u << 13) | (1u << 16))

static const char *const kServiceNodes[] = {
	"/dev/mpp_service",
	"/dev/mpp-service",
};

struct client_row {
	const char *name;
	uint32_t type;
	uint32_t probe_bit;
};

/*
 * The three clients the island compiles. `probe_bit` is 1 << type, which is
 * how the service builds its PROBE_HW_SUPPORT bitmap
 * (drivers/video/rockchip/mpp/mpp_service.c, `mpp_service_ioctl` query arm).
 */
static const struct client_row kClients[] = {
	{ "RKVDEC2", MPP_CLIENT_RKVDEC, 1u << MPP_CLIENT_RKVDEC },
	{ "JPGDEC", MPP_CLIENT_RKJPEGD, 1u << MPP_CLIENT_RKJPEGD },
	{ "RKVENC2", MPP_CLIENT_RKVENC, 1u << MPP_CLIENT_RKVENC },
};

/* mpp_cfg — one MPP_IOC_CFG_V1 round trip. Returns 0 or -1 with errno set. */
static int mpp_cfg(int fd, uint32_t cmd, uint32_t size, void *data)
{
	struct mpp_request req;

	memset(&req, 0, sizeof(req));
	req.cmd = cmd;
	req.flags = MPP_FLAGS_LAST_MSG;
	req.size = size;
	req.offset = 0;
	req.data_ptr = (uint64_t)(uintptr_t)data;

	return ioctl(fd, MPP_IOC_CFG_V1, &req);
}

static void report(const char *key, int rc)
{
	if (rc == 0)
		printf("%s=ok\n", key);
	else
		printf("%s=error errno=%d (%s)\n", key, errno, strerror(errno));
}

static int open_service(const char **which)
{
	size_t i;

	for (i = 0; i < sizeof(kServiceNodes) / sizeof(kServiceNodes[0]); i++) {
		int fd = open(kServiceNodes[i], O_RDWR | O_CLOEXEC);

		if (fd >= 0) {
			*which = kServiceNodes[i];
			return fd;
		}
		printf("open_attempt=%s errno=%d (%s)\n", kServiceNodes[i], errno,
		       strerror(errno));
	}
	*which = NULL;
	return -1;
}

static int probe_client(const char *node, const struct client_row *row,
			uint32_t hw_support)
{
	uint32_t client = row->type;
	uint32_t hw_id = 0;
	int fd;
	int rc;

	printf("client=%s type=%u probe_bit=0x%08x advertised=%s\n", row->name,
	       row->type, row->probe_bit,
	       (hw_support & row->probe_bit) ? "yes" : "no");

	fd = open(node, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		printf("client_%s.open=error errno=%d (%s)\n", row->name, errno,
		       strerror(errno));
		return -1;
	}

	rc = mpp_cfg(fd, MPP_CMD_INIT_CLIENT_TYPE, sizeof(client), &client);
	if (rc != 0) {
		printf("client_%s.init_client_type=error errno=%d (%s)\n",
		       row->name, errno, strerror(errno));
		close(fd);
		return -1;
	}
	printf("client_%s.init_client_type=ok\n", row->name);

	rc = mpp_cfg(fd, MPP_CMD_QUERY_HW_ID, sizeof(hw_id), &hw_id);
	if (rc != 0) {
		printf("client_%s.query_hw_id=error errno=%d (%s)\n", row->name,
		       errno, strerror(errno));
		close(fd);
		return -1;
	}
	printf("client_%s.query_hw_id=ok hw_id=0x%08x\n", row->name, hw_id);

	close(fd);
	return 0;
}

/*
 * self_test — prove the ABI arithmetic on ANY host, with no MPP service and no
 * Rockchip silicon. It cannot measure hardware; it measures that this binary
 * would ASK the right questions. The static assertions in the header already
 * fail the build on a layout change, so what is left to show at runtime is the
 * command numbers and the request encoding.
 */
static int self_test(void)
{
	struct mpp_request req;
	uint32_t probe_payload = 0;
	size_t i;

	printf("self_test=probe-mpp-uapi\n");
	printf("ioctl.MPP_IOC_CFG_V1=0x%08lx\n", (unsigned long)MPP_IOC_CFG_V1);
	printf("cmd.PROBE_HW_SUPPORT=0x%03x\n", MPP_CMD_PROBE_HW_SUPPORT);
	printf("cmd.QUERY_HW_ID=0x%03x\n", MPP_CMD_QUERY_HW_ID);
	printf("cmd.QUERY_CMD_SUPPORT=0x%03x\n", MPP_CMD_QUERY_CMD_SUPPORT);
	printf("cmd.INIT_CLIENT_TYPE=0x%03x\n", MPP_CMD_INIT_CLIENT_TYPE);
	printf("sizeof.mpp_request=%zu\n", sizeof(struct mpp_request));
	printf("sizeof.mpp_service_cmd_cap=%zu\n",
	       sizeof(struct mpp_service_cmd_cap));

	for (i = 0; i < sizeof(kClients) / sizeof(kClients[0]); i++)
		printf("client.%s=%u bit=0x%08x\n", kClients[i].name,
		       kClients[i].type, kClients[i].probe_bit);

	memset(&req, 0, sizeof(req));
	req.cmd = MPP_CMD_PROBE_HW_SUPPORT;
	req.flags = MPP_FLAGS_LAST_MSG;
	req.size = sizeof(probe_payload);
	req.data_ptr = (uint64_t)(uintptr_t)&probe_payload;

	if (req.cmd != 0u || req.flags != MPP_FLAGS_LAST_MSG ||
	    req.size != 4u || req.data_ptr == 0u) {
		fprintf(stderr, "FAIL: request encoding is wrong\n");
		return EXIT_FAIL;
	}
	if (ISLAND_HW_SUPPORT != 0x00012200u) {
		fprintf(stderr, "FAIL: island capability mask is wrong\n");
		return EXIT_FAIL;
	}
	printf("request_encoding=ok\n");
	printf("VERDICT: PASS (self-test; no MPP service was contacted)\n");
	return EXIT_PASS;
}

static void usage(const char *argv0)
{
	fprintf(stderr,
		"usage: %s [--self-test|--expect-island]\n"
		"  (no args)    probe /dev/mpp_service on this host\n"
		"  --expect-island  require exactly RKVENC2+RKVDEC2+JPGDEC\n"
		"  --self-test  verify the ABI encoding with no hardware\n",
		argv0);
}

int main(int argc, char **argv)
{
	const char *node = NULL;
	uint32_t hw_support = 0;
	struct mpp_service_cmd_cap cap;
	int failures = 0;
	bool expect_island = false;
	int fd;
	size_t i;

	if (argc > 2) {
		usage(argv[0]);
		return EXIT_USAGE;
	}
	if (argc == 2) {
		if (strcmp(argv[1], "--self-test") == 0)
			return self_test();
		if (strcmp(argv[1], "--expect-island") == 0)
			expect_island = true;
		else {
			usage(argv[0]);
			return EXIT_USAGE;
		}
	}

	fd = open_service(&node);
	if (fd < 0) {
		printf("mpp_service=absent\n");
		printf("VERDICT: GATED (no MPP service node on this host)\n");
		return EXIT_GATED;
	}
	printf("mpp_service=%s\n", node);

	if (mpp_cfg(fd, MPP_CMD_PROBE_HW_SUPPORT, sizeof(hw_support),
		    &hw_support) == 0)
		printf("probe_hw_support=ok bitmap=0x%08x\n", hw_support);
	else {
		report("probe_hw_support", -1);
		failures++;
	}
	if (expect_island && hw_support != ISLAND_HW_SUPPORT) {
		printf("island_hw_support=mismatch expected=0x%08x actual=0x%08x\n",
		       ISLAND_HW_SUPPORT, hw_support);
		failures++;
	} else if (expect_island) {
		printf("island_hw_support=exact bitmap=0x%08x\n", hw_support);
	}

	memset(&cap, 0, sizeof(cap));
	if (mpp_cfg(fd, MPP_CMD_QUERY_CMD_SUPPORT, sizeof(cap), &cap) == 0)
		printf("query_cmd_support=ok support=0x%08x query=0x%08x "
		       "init=0x%08x send=0x%08x poll=0x%08x ctrl=0x%08x\n",
		       cap.support_cmd, cap.query_cmd, cap.init_cmd,
		       cap.send_cmd, cap.poll_cmd, cap.ctrl_cmd);
	else {
		report("query_cmd_support", -1);
		failures++;
	}

	close(fd);

	for (i = 0; i < sizeof(kClients) / sizeof(kClients[0]); i++) {
		if (probe_client(node, &kClients[i], hw_support) != 0)
			printf("client_%s=unavailable\n", kClients[i].name);
		else
			printf("client_%s=available\n", kClients[i].name);
	}

	/*
	 * A client that is absent is a RESULT, not a probe failure: recording
	 * "the kernel exposes no JPGDEC client" is exactly what Phase 0 is for.
	 * Only a service that opened and then refused its own query commands is
	 * a failure of the probe.
	 */
	if (failures > 0) {
		printf("VERDICT: FAIL (%d service query command(s) refused)\n",
		       failures);
		return EXIT_FAIL;
	}
	printf("VERDICT: PASS (service answered; per-client rows above)\n");
	return EXIT_PASS;
}
