// SPDX-License-Identifier: GPL-2.0-only
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <im2d.hpp>

namespace {
constexpr int kWidth = 64;
constexpr int kHeight = 64;
constexpr size_t kBytes = kWidth * kHeight * 4;
}

int main()
{
	void *src_data = std::calloc(1, kBytes);
	void *dst_data = std::calloc(1, kBytes);
	int release_fence_fd = -1;
	IM_STATUS status;

	if (!src_data || !dst_data) {
		std::fprintf(stderr, "allocation failed\n");
		std::free(src_data);
		std::free(dst_data);
		return 1;
	}

	std::memset(src_data, 0x5a, kBytes);
	rga_buffer_t src = wrapbuffer_virtualaddr(src_data, kWidth, kHeight,
						  RK_FORMAT_RGBA_8888);
	rga_buffer_t dst = wrapbuffer_virtualaddr(dst_data, kWidth, kHeight,
						  RK_FORMAT_RGBA_8888);

	errno = 0;
	status = improcess(src, dst, {}, {}, {}, {}, -1, &release_fence_fd,
			   nullptr, IM_ASYNC);
	std::printf("improcess_status=%d errno=%d release_fence_fd=%d\n",
		    status, errno, release_fence_fd);
	std::printf("VERDICT: %s\n",
		    release_fence_fd >= 0 ? "FENCES-SENT" : "REQUEST-RECORDED");

	std::free(src_data);
	std::free(dst_data);
	return 0;
}
