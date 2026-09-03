/* SPDX-License-Identifier: GPL-2.0-only */
#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>

#define RGA_BLIT_ASYNC 0x5018
#define RGA_GET_VERSION 0x501b
#define RGA2_GET_VERSION 0x601b
#define RGA_REQUEST_PREFIX_BYTES 256

typedef int (*open_fn)(const char *path, int flags, ...);
typedef int (*ioctl_fn)(int fd, unsigned long request, ...);

static open_fn real_open;
static ioctl_fn real_ioctl;

static void resolve_symbols(void)
{
	if (!real_open)
		real_open = (open_fn)dlsym(RTLD_NEXT, "open");
	if (!real_ioctl)
		real_ioctl = (ioctl_fn)dlsym(RTLD_NEXT, "ioctl");
}

int open(const char *path, int flags, ...)
{
	mode_t mode = 0;
	va_list ap;

	resolve_symbols();
	if (flags & O_CREAT) {
		va_start(ap, flags);
		mode = va_arg(ap, mode_t);
		va_end(ap);
	}
	if (strcmp(path, "/dev/rga") == 0) {
		fprintf(stderr, "librga-trace open path=/dev/rga replacement=/dev/null\n");
		return real_open("/dev/null", flags & ~O_CREAT);
	}

	return flags & O_CREAT ? real_open(path, flags, mode) : real_open(path, flags);
}

int ioctl(int fd, unsigned long request, ...)
{
	void *arg;
	va_list ap;

	resolve_symbols();
	va_start(ap, request);
	arg = va_arg(ap, void *);
	va_end(ap);

	if (request == RGA_BLIT_ASYNC) {
		const unsigned char *bytes = arg;
		size_t i;

		fprintf(stderr, "librga-trace ioctl=RGA_BLIT_ASYNC request-prefix=");
		for (i = 0; i < RGA_REQUEST_PREFIX_BYTES; i++)
			fprintf(stderr, "%02x", bytes[i]);
		fprintf(stderr, " result=-ENOTTY\n");
		errno = ENOTTY;
		return -1;
	}
	if (request == RGA_GET_VERSION || request == RGA2_GET_VERSION) {
		memset(arg, 0, 16);
		memcpy(arg, "1.3.11", 7);
		fprintf(stderr, "librga-trace ioctl=0x%lx version=1.3.11 result=0\n",
			request);
		return 0;
	}

	fprintf(stderr, "librga-trace ioctl=0x%lx passthrough\n", request);
	return real_ioctl(fd, request, arg);
}
