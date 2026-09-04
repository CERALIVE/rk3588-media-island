# RGA async-fence release-1 decision

## Verdict: ON

Release 1 keeps `CONFIG_ROCKCHIP_RGA_ASYNC=y`. This verdict is frozen by todo
54 and can change only in a later ordinary island release.

Pinned librga 1.10.0's public source package does not contain implementation
sources, so the implementation audit uses the public source mirror at
`tsukumijima/librga@73300181798b48301f44ef44f232f85ec4c67948` and verifies the
version against the official 1.10.0 binary. `imcopy`, `imresize`, `imcrop`, and
`imrotate` pass acquire fd `-1`; direct `improcess` preserves its caller's
acquire fd. `rga_task_submit()` selects `RGA_BLIT_ASYNC`, copies that acquire fd
into `dstinfo.in_fence_fd`, and `NormalRga::RkRgaBlit()` copies the driver's
`out_fence_fd` back to the writable release-fence pointer. The job API uses
`RGA_IOC_REQUEST_SUBMIT` and likewise copies `acquire_fence_fd` in and the
release fd out for `IM_ASYNC`.

Radxa's 2.2.0 source at
`tsukumijima/librga-rockchip@0e53dff20e05012920e6c99ca33835db7b65fad9`
has the same contract: the ordinary operation path uses
`RGA_BLIT_SYNC`/`RGA_BLIT_ASYNC`; its job path uses
`RGA_IOC_REQUEST_SUBMIT`, accepts an acquire fd, and returns the release fd in
async mode. `imconfig` changes process-local policy and submits no ioctl in
either release.

## Intercepted request

`tests/board/librga-async-probe.cpp` was cross-linked to the official
`v1.10.0` aarch64 `librga.so` and run under qemu-aarch64 with
`librga-ioctl-trace.c` preloaded. The shim replaced `/dev/rga` with `/dev/null`,
so the driver answer was intentionally `-ENOTTY`; the request bytes are the
evidence. The observed call was:

```text
librga-trace ioctl=RGA_BLIT_ASYNC request-prefix=000000000000000090258212a37f000090358212a37f000090398212a37f0000000000004000400000000000400040000000000000000000a0658212a37f0000a0758212a37f0000a0798212a37f00000000000040004000000000004000400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003f0000003f000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 result=-ENOTTY
im2d_rga_impl rga_task_submit(2109): acquir_fence[-1], release_fence_ptr[non-null], usage[0x4000000]
```

This is sufficient to keep the fence ABI on: the engine's normal calls remain
synchronous, while explicit `IM_ASYNC` constructs an async ioctl with a writable
release-fence destination. Todo 26(9) owns the later hardware proof that the
returned fd is a visible `sync_file` and every async row is clean.

## Kernel proof

The disabled inline substitutes are deleted. `rga_fence.c` is always linked
into `rga_multicore.ko` and uses mainline `dma_fence_context_alloc`, `dma_fence_init`,
`sync_file_create`, `sync_file_get_fence`, callback, wait, status, error,
signal, and put APIs. The `rockchip-rga-fence` KUnit matrix starts each fence
unsignalled, then proves completion, timeout, IRQ error, explicit cancel,
submit-time abort, session close, scheduler shutdown, and driver remove all
signal it with the corresponding terminal status.
