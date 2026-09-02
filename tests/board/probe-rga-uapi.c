/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * probe-rga-uapi.c — ask /dev/rga what it is, then make it do one real copy.
 *
 * WHY: the copy census (todo 3(b)) and the RGA flip (todos 25-27) both need a
 * first-party answer to "is there a multi_rga character device on this board,
 * and can it blit an NV12 dma-buf". On the CURRENT shipped image there is no
 * /dev/rga at all — the mainline `rockchip-rga` driver is a V4L2 M2M device —
 * so the expected Phase-0 result is an ABSENCE with an errno, and that is
 * recorded as the baseline rather than treated as a tool failure.
 *
 * Three legs, in order:
 *   1. RGA_IOC_GET_DRVIER_VERSION  (vendor's spelling; the typo is the ABI)
 *   2. RGA_IOC_GET_HW_VERSION
 *   3. one RGA_BLIT_SYNC NV12 -> NV12 copy over dma-heap buffers
 *
 * The blit operands come from /dev/dma_heap/system-uncached (falling back
 * through the names libmpp uses: system-uncached, system, cma-uncached, cma),
 * because a dma-heap fd is what the real pipeline hands RGA — a malloc'd
 * buffer would exercise the RGA2 32-bit-MMU virtual-address path instead, i.e.
 * exactly the fallback the island exists to remove.
 *
 * THIS PROBE IS READ-ONLY WITH RESPECT TO SYSTEM STATE. It allocates its own
 * buffers, blits between them, and frees them. It changes no unit, no module,
 * and nothing under /sys.
 *
 * Build (target suite, aarch64):
 *   aarch64-linux-gnu-gcc -std=c11 -Wall -Wextra -Werror -O2 \
 *       -Iuapi -o probe-rga-uapi probe-rga-uapi.c
 *
 * Exit codes:
 *   0  the device answered (an answered "no such format" is still an answer)
 *   1  the device exists but a leg failed unexpectedly
 *   2  usage
 *   77 no /dev/rga on this host (hardware-gated, not a pass)
 */

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "uapi/rga-uapi.h"

#define EXIT_PASS 0
#define EXIT_FAIL 1
#define EXIT_USAGE 2
#define EXIT_GATED 77

#define RGA_NODE "/dev/rga"

#define BLIT_W 640
#define BLIT_H 360

/*
 * linux/dma-heap.h, transcribed rather than included so the probe builds in a
 * cross toolchain whose sysroot may predate the header.
 *   DMA_HEAP_IOCTL_ALLOC = _IOWR('H', 0x0, struct dma_heap_allocation_data)
 */
struct dma_heap_allocation_data {
	uint64_t len;
	uint32_t fd;
	uint32_t fd_flags;
	uint64_t heap_flags;
};
#define DMA_HEAP_IOCTL_ALLOC _IOWR('H', 0x0, struct dma_heap_allocation_data)

_Static_assert(sizeof(struct dma_heap_allocation_data) == 24,
	       "dma_heap_allocation_data must be u64 + u32 + u32 + u64");

/* The heap names libmpp tries, in its order (draft F6, MPP osal allocator). */
static const char *const kHeapNodes[] = {
	"/dev/dma_heap/system-uncached",
	"/dev/dma_heap/system",
	"/dev/dma_heap/cma-uncached",
	"/dev/dma_heap/cma",
};

struct dmabuf {
	int fd;
	size_t len;
	void *map;
	const char *heap;
};

static void dmabuf_release(struct dmabuf *b)
{
	if (b->map && b->map != MAP_FAILED)
		munmap(b->map, b->len);
	if (b->fd >= 0)
		close(b->fd);
	b->map = NULL;
	b->fd = -1;
}

/*
 * dmabuf_alloc — allocate `len` bytes from the first available dma-heap and
 * map it. Returns 0 on success; on failure every attempted heap has already
 * been reported with its errno.
 */
static int dmabuf_alloc(struct dmabuf *b, size_t len, const char *label)
{
	size_t i;

	b->fd = -1;
	b->map = NULL;
	b->len = len;
	b->heap = NULL;

	for (i = 0; i < sizeof(kHeapNodes) / sizeof(kHeapNodes[0]); i++) {
		struct dma_heap_allocation_data data;
		int heap_fd = open(kHeapNodes[i], O_RDWR | O_CLOEXEC);

		if (heap_fd < 0) {
			printf("dmabuf.%s.heap_open=%s errno=%d (%s)\n", label,
			       kHeapNodes[i], errno, strerror(errno));
			continue;
		}

		memset(&data, 0, sizeof(data));
		data.len = len;
		data.fd_flags = O_RDWR | O_CLOEXEC;

		if (ioctl(heap_fd, DMA_HEAP_IOCTL_ALLOC, &data) != 0) {
			printf("dmabuf.%s.alloc=%s errno=%d (%s)\n", label,
			       kHeapNodes[i], errno, strerror(errno));
			close(heap_fd);
			continue;
		}
		close(heap_fd);

		b->fd = (int)data.fd;
		b->heap = kHeapNodes[i];
		b->map = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED,
			      b->fd, 0);
		if (b->map == MAP_FAILED) {
			printf("dmabuf.%s.mmap=error errno=%d (%s)\n", label,
			       errno, strerror(errno));
			b->map = NULL;
			close(b->fd);
			b->fd = -1;
			continue;
		}
		printf("dmabuf.%s=ok heap=%s fd=%d bytes=%zu\n", label, b->heap,
		       b->fd, len);
		return 0;
	}

	printf("dmabuf.%s=unavailable\n", label);
	return -1;
}

static void fill_img(struct rga_img_info_t *img, int dmabuf_fd, uint32_t format)
{
	memset(img, 0, sizeof(*img));
	/*
	 * The legacy blit path takes the dma-buf fd in yrgb_addr; the driver
	 * resolves it through dma_buf_get(). uv_addr stays zero so the vendor's
	 * own NV12 plane-offset derivation applies.
	 */
	img->yrgb_addr = (uint64_t)(uint32_t)dmabuf_fd;
	img->format = format;
	img->act_w = BLIT_W;
	img->act_h = BLIT_H;
	img->vir_w = BLIT_W;
	img->vir_h = BLIT_H;
	img->enable = 1;
}

static int do_blit(int rga_fd, const struct dmabuf *src, const struct dmabuf *dst)
{
	/*
	 * See uapi/rga-uapi.h: only the leading prefix of `struct rga_req` is
	 * declared, and the driver's fixed-size copy_from_user is satisfied by
	 * this over-allocated zero-filled backing buffer.
	 */
	uint8_t backing[RGA_REQ_BACKING_BYTES];
	struct rga_req_prefix *req = (struct rga_req_prefix *)backing;

	memset(backing, 0, sizeof(backing));
	req->render_mode = RGA_BITBLT_MODE;
	fill_img(&req->src, src->fd, RGA_FORMAT_YCbCr_420_SP);
	fill_img(&req->dst, dst->fd, RGA_FORMAT_YCbCr_420_SP);

	if (ioctl(rga_fd, RGA_BLIT_SYNC, backing) != 0) {
		printf("blit_sync=error errno=%d (%s)\n", errno, strerror(errno));
		return -1;
	}
	printf("blit_sync=ok geometry=%dx%d format=NV12->NV12\n", BLIT_W, BLIT_H);
	return 0;
}

static int self_test(void)
{
	uint8_t backing[RGA_REQ_BACKING_BYTES];
	struct rga_req_prefix *req = (struct rga_req_prefix *)backing;
	struct dmabuf src;

	printf("self_test=probe-rga-uapi\n");
	printf("ioctl.RGA_IOC_GET_DRVIER_VERSION=0x%08lx\n",
	       (unsigned long)RGA_IOC_GET_DRVIER_VERSION);
	printf("ioctl.RGA_IOC_GET_HW_VERSION=0x%08lx\n",
	       (unsigned long)RGA_IOC_GET_HW_VERSION);
	printf("ioctl.RGA_BLIT_SYNC=0x%04x\n", RGA_BLIT_SYNC);
	printf("ioctl.DMA_HEAP_IOCTL_ALLOC=0x%08lx\n",
	       (unsigned long)DMA_HEAP_IOCTL_ALLOC);
	printf("sizeof.rga_version_t=%zu\n", sizeof(struct rga_version_t));
	printf("sizeof.rga_hw_versions_t=%zu\n",
	       sizeof(struct rga_hw_versions_t));
	printf("sizeof.rga_img_info_t=%zu\n", sizeof(struct rga_img_info_t));
	printf("sizeof.rga_req_prefix=%zu backing=%d\n",
	       sizeof(struct rga_req_prefix), RGA_REQ_BACKING_BYTES);

	memset(backing, 0, sizeof(backing));
	req->render_mode = RGA_BITBLT_MODE;
	fill_img(&req->src, 7, RGA_FORMAT_YCbCr_420_SP);
	fill_img(&req->dst, 8, RGA_FORMAT_YCbCr_420_SP);

	if (req->src.yrgb_addr != 7u || req->dst.yrgb_addr != 8u ||
	    req->src.format != RGA_FORMAT_YCbCr_420_SP ||
	    req->dst.act_w != BLIT_W || req->dst.enable != 1u) {
		fprintf(stderr, "FAIL: request prefix was not populated\n");
		return EXIT_FAIL;
	}
	/* Everything past the declared prefix must still read as zero. */
	{
		size_t i;

		for (i = sizeof(struct rga_req_prefix); i < sizeof(backing); i++) {
			if (backing[i] != 0) {
				fprintf(stderr,
					"FAIL: request tail is not zeroed at %zu\n",
					i);
				return EXIT_FAIL;
			}
		}
	}
	printf("request_encoding=ok\n");

	/*
	 * The dma-heap leg is exercised where a heap exists (most Linux hosts
	 * ship /dev/dma_heap/system) and reported honestly where it does not.
	 * Either way the self-test passes: it is proving the probe's own code
	 * paths, not the presence of Rockchip silicon.
	 */
	if (dmabuf_alloc(&src, (size_t)BLIT_W * BLIT_H * 3 / 2, "selftest") == 0) {
		memset(src.map, 0x80, src.len);
		printf("dmabuf_roundtrip=ok\n");
		dmabuf_release(&src);
	} else {
		printf("dmabuf_roundtrip=skipped (no usable dma-heap here)\n");
	}

	printf("VERDICT: PASS (self-test; no RGA device was contacted)\n");
	return EXIT_PASS;
}

static void usage(const char *argv0)
{
	fprintf(stderr,
		"usage: %s [--self-test]\n"
		"  (no args)    probe " RGA_NODE " on this host\n"
		"  --self-test  verify the ABI encoding with no hardware\n",
		argv0);
}

int main(int argc, char **argv)
{
	struct rga_version_t drv;
	struct rga_hw_versions_t hw;
	struct dmabuf src;
	struct dmabuf dst;
	size_t nv12_bytes = (size_t)BLIT_W * BLIT_H * 3 / 2;
	int failures = 0;
	int rga_fd;
	uint32_t i;

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

	rga_fd = open(RGA_NODE, O_RDWR | O_CLOEXEC);
	if (rga_fd < 0) {
		printf("rga_node=absent path=%s errno=%d (%s)\n", RGA_NODE,
		       errno, strerror(errno));
		printf("VERDICT: GATED (no %s on this host)\n", RGA_NODE);
		return EXIT_GATED;
	}
	printf("rga_node=%s\n", RGA_NODE);

	memset(&drv, 0, sizeof(drv));
	if (ioctl(rga_fd, RGA_IOC_GET_DRVIER_VERSION, &drv) == 0)
		printf("driver_version=ok major=%u minor=%u revision=%u str=%.*s\n",
		       drv.major, drv.minor, drv.revision, RGA_VERSION_SIZE,
		       (const char *)drv.str);
	else {
		printf("driver_version=error errno=%d (%s)\n", errno,
		       strerror(errno));
		failures++;
	}

	memset(&hw, 0, sizeof(hw));
	if (ioctl(rga_fd, RGA_IOC_GET_HW_VERSION, &hw) == 0) {
		printf("hw_version=ok cores=%u\n", hw.size);
		for (i = 0; i < hw.size && i < RGA_HW_SIZE; i++)
			printf("hw_core[%u]=major=%u minor=%u revision=%u str=%.*s\n",
			       i, hw.version[i].major, hw.version[i].minor,
			       hw.version[i].revision, RGA_VERSION_SIZE,
			       (const char *)hw.version[i].str);
	} else {
		printf("hw_version=error errno=%d (%s)\n", errno, strerror(errno));
		failures++;
	}

	if (dmabuf_alloc(&src, nv12_bytes, "src") != 0 ||
	    dmabuf_alloc(&dst, nv12_bytes, "dst") != 0) {
		printf("blit_sync=skipped (no dma-heap operand available)\n");
		close(rga_fd);
		printf("VERDICT: %s (version legs only)\n",
		       failures ? "FAIL" : "PASS");
		return failures ? EXIT_FAIL : EXIT_PASS;
	}

	memset(src.map, 0x40, src.len);
	memset(dst.map, 0x00, dst.len);

	if (do_blit(rga_fd, &src, &dst) == 0) {
		const uint8_t *out = dst.map;
		printf("blit_first_bytes=%02x%02x%02x%02x\n", out[0], out[1],
		       out[2], out[3]);
	} else {
		/*
		 * A refused blit is a measurement, not a harness fault: it is
		 * how a board whose multi_rga rejects dma-buf operands is
		 * recorded. The errno above is the finding.
		 */
		printf("blit_sync=refused (errno recorded above)\n");
	}

	dmabuf_release(&src);
	dmabuf_release(&dst);
	close(rga_fd);

	if (failures > 0) {
		printf("VERDICT: FAIL (%d version query(ies) refused)\n",
		       failures);
		return EXIT_FAIL;
	}
	printf("VERDICT: PASS (device answered; rows above)\n");
	return EXIT_PASS;
}
