/* SPDX-License-Identifier: GPL-2.0-only */
/* Exercise the actual probe, but never open a device or submit a real ioctl. */
#define main rga_probe_main
#define open test_open
#define close test_close
#define ioctl test_ioctl
#include "probe-rga-uapi.c"
#undef ioctl
#undef close
#undef open
#undef main

#include <stdarg.h>

static int driver_result;
static int hardware_result;
static unsigned int version_calls;
static unsigned int blit_calls;

int test_open(const char *path, int flags, ...)
{
	(void)flags;
	if (strcmp(path, RGA_NODE) == 0)
		return 100;
	/* The version tests deliberately have no dma-heap operands. */
	errno = ENOENT;
	return -1;
}

int test_close(int fd)
{
	if (fd != 100) {
		fprintf(stderr, "FAIL: unexpected close fd=%d\n", fd);
		exit(EXIT_FAIL);
	}
	return 0;
}

int test_ioctl(int fd, unsigned long command, ...)
{
	va_list args;
	void *payload;
	int result;

	if (fd != 100) {
		fprintf(stderr, "FAIL: unexpected ioctl fd=%d\n", fd);
		exit(EXIT_FAIL);
	}
	va_start(args, command);
	payload = va_arg(args, void *);
	va_end(args);

	if (command == RGA_BLIT_SYNC) {
		const struct rga_req_prefix *request = payload;

		blit_calls++;
		if (request->src.rd_mode != 1u || request->dst.rd_mode != 1u) {
			errno = EINVAL;
			return -1;
		}
		return 0;
	}
	if (command == RGA_IOC_GET_DRVIER_VERSION) {
		struct rga_version_t *version = payload;

		*version = (struct rga_version_t){
			.major = 1, .minor = 3, .revision = 11, .str = "1.3.11",
		};
		result = driver_result;
	} else if (command == RGA_IOC_GET_HW_VERSION) {
		struct rga_hw_versions_t *hardware = payload;

		*hardware = (struct rga_hw_versions_t){ .size = 3 };
		result = hardware_result;
	} else {
		fprintf(stderr, "FAIL: unexpected ioctl command=0x%lx\n", command);
		exit(EXIT_FAIL);
	}
	version_calls++;
	/* Stale errno must not turn a successful ioctl into a refusal. */
	errno = EFAULT;
	return result;
}

int main(void)
{
	const struct {
		int driver;
		int hardware;
		int expected;
	} cases[] = {
		{ 1, 1, EXIT_PASS },
		{ 0, 0, EXIT_PASS },
		{ 1, 0, EXIT_PASS },
		{ 0, 1, EXIT_PASS },
		{ -1, 1, EXIT_FAIL },
		{ 1, -1, EXIT_FAIL },
		{ -1, -1, EXIT_FAIL },
	};
	char name[] = "probe-rga-uapi";
	char *argv[] = { name, NULL };
	const struct dmabuf src = { .fd = 7 };
	const struct dmabuf dst = { .fd = 8 };
	int failures = 0;
	size_t i;

	for (i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
		int result;

		driver_result = cases[i].driver;
		hardware_result = cases[i].hardware;
		version_calls = 0;
		result = rga_probe_main(1, argv);
		if (result != cases[i].expected || version_calls != 2) {
			fprintf(stderr,
				"FAIL: driver=%d hardware=%d exit=%d expected=%d calls=%u\n",
				driver_result, hardware_result, result,
				cases[i].expected, version_calls);
			failures++;
		}
	}
	printf("version_return_regressions=%s (mock ioctls; no hardware)\n",
	       failures ? "FAIL" : "PASS");
	if (do_blit(100, &src, &dst) != 0 || blit_calls != 1) {
		fprintf(stderr, "FAIL: submitted src/dst read modes must both be 1\n");
		failures++;
	}
	printf("probe_regressions=%s (mock ioctls; no hardware)\n",
	       failures ? "FAIL" : "PASS");
	return failures ? EXIT_FAIL : EXIT_PASS;
}
