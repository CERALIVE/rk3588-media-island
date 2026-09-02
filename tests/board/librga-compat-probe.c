/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * librga-compat-probe.c — the A2 question, asked of the real library.
 *
 * THE QUESTION: librga is documented to run in a "compatibility mode" when the
 * multi_rga character device is absent. Phase 0 needs to know what that mode
 * ACTUALLY does on the shipped image, because the whole copy census depends on
 * whether an RGA call on today's board reaches hardware, silently degrades to
 * something else, or fails. The claim is not taken from documentation: this
 * probe calls `c_RkRgaInit()` and then `c_RkRgaBlit()` on a board with no
 * /dev/rga and records the return codes.
 *
 * HOW IT ASKS: `dlopen` + `dlsym`, never a link-time dependency. Three reasons,
 * all of them load-bearing:
 *   * the probe must cross-compile in the target-suite toolchain, which has no
 *     librga development package;
 *   * a missing library must be a REPORTED ABSENCE, not a loader error that
 *     kills the process before anything is printed;
 *   * the SONAME the board actually carries is itself part of the measurement,
 *     so the probe walks a candidate list and prints which one answered.
 *
 * The syscall half of the answer is captured by running this probe under
 * strace — that is what shows whether librga tried to open /dev/rga at all,
 * and what it fell back to:
 *
 *     strace -f -e trace=openat,ioctl -o librga-compat.strace \
 *         ./librga-compat-probe
 *
 * run-baseline.sh does exactly that. The probe prints the same command in its
 * own output so an operator running it by hand gets the full A2 evidence.
 *
 * ON THE ARGUMENT STRUCT: librga's `rga_info_t` (airockchip/librga
 * include/drmrga.h) has grown across releases and ends in `char reserve[386]`.
 * This probe declares only the stable leading PREFIX — `fd` through `mmuFlag`,
 * which is everything a plain blit reads — inside an over-allocated,
 * zero-filled backing buffer. librga only READS the struct, so a longer
 * `rga_info_t` in the installed library still lands inside memory we own and
 * zeroed, and every field we do not set takes its documented default. Copying
 * the whole tail of one librga release would look more complete and would be a
 * guess about the version the board happens to ship.
 *
 * THIS PROBE IS READ-ONLY. It allocates its own buffers and calls two library
 * entry points. It changes no unit, no module, and nothing under /sys.
 *
 * Build (target suite, aarch64):
 *   aarch64-linux-gnu-gcc -std=c11 -Wall -Wextra -Werror -O2 \
 *       -o librga-compat-probe librga-compat-probe.c -ldl
 *
 * Exit codes:
 *   0  librga answered, or is honestly absent (both are A2 evidence)
 *   1  librga loaded but its entry points could not be resolved
 *   2  usage
 */

#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define EXIT_PASS 0
#define EXIT_FAIL 1
#define EXIT_USAGE 2

#define PROBE_W 640
#define PROBE_H 360

/* airockchip/librga include/drmrga.h:113-122 */
typedef struct rga_rect {
	int xoffset;
	int yoffset;
	int width;
	int height;
	int wstride;
	int hstride;
	int format;
	int size;
} rga_rect_t;

/*
 * airockchip/librga include/drmrga.h:263-283 — the leading prefix only.
 * See the banner for why the tail is deliberately not declared.
 */
struct rga_info_prefix {
	int fd;
	void *virAddr;
	void *phyAddr;
	unsigned int hnd;
	int format;
	rga_rect_t rect;
	unsigned int blend;
	int bufferSize;
	int rotation;
	int color;
	int testLog;
	int mmuFlag;
};

/* Comfortably larger than any released rga_info_t (which ends in reserve[386]). */
#define RGA_INFO_BACKING_BYTES 2048

_Static_assert(sizeof(rga_rect_t) == 32, "rga_rect_t must be eight ints");
_Static_assert(sizeof(struct rga_info_prefix) <= RGA_INFO_BACKING_BYTES,
	       "the rga_info prefix must fit inside its backing allocation");

/* librga RK_FORMAT_YCbCr_420_SP — the NV12 constant shared with the kernel UAPI. */
#define LIBRGA_FORMAT_YCbCr_420_SP 0xa

typedef int (*rkrga_init_fn)(void);
typedef int (*rkrga_blit_fn)(void *src, void *dst, void *src1);
typedef void (*rkrga_deinit_fn)(void);

static const char *const kSonames[] = {
	"librga.so.2",
	"librga.so",
	"librga.so.1",
	"/usr/lib/aarch64-linux-gnu/librga.so.2",
};

static void print_strace_hint(const char *argv0)
{
	printf("strace_command=strace -f -e trace=openat,ioctl -o "
	       "librga-compat.strace %s\n",
	       argv0);
}

static void *load_librga(const char **which)
{
	size_t i;

	for (i = 0; i < sizeof(kSonames) / sizeof(kSonames[0]); i++) {
		void *h = dlopen(kSonames[i], RTLD_NOW | RTLD_LOCAL);

		if (h) {
			*which = kSonames[i];
			return h;
		}
		printf("dlopen_attempt=%s error=%s\n", kSonames[i], dlerror());
	}
	*which = NULL;
	return NULL;
}

/* fill_operand — populate the prefix of one rga_info_t inside `backing`. */
static void fill_operand(uint8_t *backing, void *vaddr, int size)
{
	struct rga_info_prefix *info = (struct rga_info_prefix *)backing;

	memset(backing, 0, RGA_INFO_BACKING_BYTES);
	info->fd = -1;
	info->virAddr = vaddr;
	info->mmuFlag = 1; /* librga: use the MMU path for a virtual address */
	info->bufferSize = size;
	info->rect.xoffset = 0;
	info->rect.yoffset = 0;
	info->rect.width = PROBE_W;
	info->rect.height = PROBE_H;
	info->rect.wstride = PROBE_W;
	info->rect.hstride = PROBE_H;
	info->rect.format = LIBRGA_FORMAT_YCbCr_420_SP;
	info->rect.size = size;
}

static int run_probe(const char *argv0)
{
	const char *soname = NULL;
	void *handle;
	rkrga_init_fn init_fn;
	rkrga_blit_fn blit_fn;
	rkrga_deinit_fn deinit_fn;
	uint8_t *src_backing = NULL;
	uint8_t *dst_backing = NULL;
	uint8_t *src_pixels = NULL;
	uint8_t *dst_pixels = NULL;
	int pixel_bytes = PROBE_W * PROBE_H * 3 / 2;
	int init_rc;
	int blit_rc;

	print_strace_hint(argv0);
	printf("rga_node_present=%s\n",
	       access("/dev/rga", F_OK) == 0 ? "yes" : "no");

	handle = load_librga(&soname);
	if (!handle) {
		printf("librga=absent\n");
		printf("VERDICT: PASS (librga is not installed here; recorded "
		       "as the A2 answer for this host)\n");
		return EXIT_PASS;
	}
	printf("librga=%s\n", soname);

	dlerror();
	init_fn = (rkrga_init_fn)dlsym(handle, "c_RkRgaInit");
	blit_fn = (rkrga_blit_fn)dlsym(handle, "c_RkRgaBlit");
	deinit_fn = (rkrga_deinit_fn)dlsym(handle, "c_RkRgaDeInit");

	printf("symbol.c_RkRgaInit=%s\n", init_fn ? "found" : "missing");
	printf("symbol.c_RkRgaBlit=%s\n", blit_fn ? "found" : "missing");
	printf("symbol.c_RkRgaDeInit=%s\n", deinit_fn ? "found" : "missing");

	if (!init_fn || !blit_fn) {
		printf("VERDICT: FAIL (librga loaded but its C entry points "
		       "could not be resolved)\n");
		dlclose(handle);
		return EXIT_FAIL;
	}

	errno = 0;
	init_rc = init_fn();
	printf("c_RkRgaInit=%d errno=%d (%s)\n", init_rc, errno,
	       strerror(errno));

	src_backing = calloc(1, RGA_INFO_BACKING_BYTES);
	dst_backing = calloc(1, RGA_INFO_BACKING_BYTES);
	src_pixels = calloc(1, (size_t)pixel_bytes);
	dst_pixels = calloc(1, (size_t)pixel_bytes);
	if (!src_backing || !dst_backing || !src_pixels || !dst_pixels) {
		printf("VERDICT: FAIL (out of memory building the operands)\n");
		free(src_backing);
		free(dst_backing);
		free(src_pixels);
		free(dst_pixels);
		dlclose(handle);
		return EXIT_FAIL;
	}
	memset(src_pixels, 0x40, (size_t)pixel_bytes);

	fill_operand(src_backing, src_pixels, pixel_bytes);
	fill_operand(dst_backing, dst_pixels, pixel_bytes);

	errno = 0;
	blit_rc = blit_fn(src_backing, dst_backing, NULL);
	printf("c_RkRgaBlit=%d errno=%d (%s)\n", blit_rc, errno,
	       strerror(errno));
	printf("dst_first_bytes=%02x%02x%02x%02x\n", dst_pixels[0],
	       dst_pixels[1], dst_pixels[2], dst_pixels[3]);
	printf("blit_changed_destination=%s\n",
	       dst_pixels[0] == 0x40 ? "yes" : "no");

	if (deinit_fn)
		deinit_fn();

	free(src_backing);
	free(dst_backing);
	free(src_pixels);
	free(dst_pixels);
	dlclose(handle);

	/*
	 * A non-zero blit return is a RESULT — it is the compatibility-mode
	 * answer this probe exists to record. Only an unresolvable library is a
	 * probe failure.
	 */
	printf("VERDICT: PASS (return codes recorded above)\n");
	return EXIT_PASS;
}

static int self_test(void)
{
	uint8_t backing[RGA_INFO_BACKING_BYTES];
	struct rga_info_prefix *info = (struct rga_info_prefix *)backing;
	uint8_t pixels[16];
	size_t i;

	printf("self_test=librga-compat-probe\n");
	printf("sizeof.rga_rect_t=%zu\n", sizeof(rga_rect_t));
	printf("sizeof.rga_info_prefix=%zu backing=%d\n",
	       sizeof(struct rga_info_prefix), RGA_INFO_BACKING_BYTES);

	memset(pixels, 0, sizeof(pixels));
	fill_operand(backing, pixels, PROBE_W * PROBE_H * 3 / 2);

	if (info->fd != -1 || info->virAddr != (void *)pixels ||
	    info->mmuFlag != 1u || info->rect.width != PROBE_W ||
	    info->rect.format != LIBRGA_FORMAT_YCbCr_420_SP) {
		fprintf(stderr, "FAIL: operand prefix was not populated\n");
		return EXIT_FAIL;
	}
	for (i = sizeof(struct rga_info_prefix); i < sizeof(backing); i++) {
		if (backing[i] != 0) {
			fprintf(stderr,
				"FAIL: operand tail is not zeroed at %zu\n", i);
			return EXIT_FAIL;
		}
	}
	printf("operand_encoding=ok\n");
	printf("VERDICT: PASS (self-test; librga was not loaded)\n");
	return EXIT_PASS;
}

static void usage(const char *argv0)
{
	fprintf(stderr,
		"usage: %s [--self-test]\n"
		"  (no args)    dlopen librga and run the A2 init+blit probe\n"
		"  --self-test  verify the operand encoding with no librga\n",
		argv0);
}

int main(int argc, char **argv)
{
	if (argc > 2) {
		usage(argv[0]);
		return EXIT_USAGE;
	}
	if (argc == 2) {
		if (strcmp(argv[1], "--self-test") == 0)
			return self_test();
		usage(argv[0]);
		return EXIT_USAGE;
	}
	return run_probe(argv[0]);
}
