# Direct ioctl input-boundary tests [EXISTS]

## What executes

`tests/kunit/ioctl_mpp_test.c` and `ioctl_rga_test.c` call `mpp_dev_ioctl()`
and `rga_ioctl()` directly in the existing KUnit kernel. They also call the
actual open/release handlers with two independent `struct file` instances.
There are no userspace syscalls, real device nodes, or physical boards.

The older suites compile helper headers only. The new staging step,
`tests/kunit/stage_ioctl.py`, selects complete named functions **verbatim** from
`mpp_common.c`, `rga_drv.c`, and `rga_job.c`. It emits their prototypes, complete
unchanged bodies, and source line markers into build-local `.inc` files. Missing
or ambiguous definitions fail staging. Its self-test proves exact-name selection
(including `request` versus `__request`), mutation propagation, and rejection of
missing/duplicate definitions. Generated includes are never maintained by hand.

Driver structs/constants come from the maintained headers. The native
`mpp_msg_v1` wire layout is selected from `mpp_common.c`, not redeclared from
memory: four `u32` fields followed by `u64 data_ptr`, 24 bytes. `rk-mpp.h` defines
`MPP_IOC_CFG_V1 = _IOW('v', 1, unsigned int)`. V2 is defined but not implemented.
RGA's ABI is in `drivers/video/rockchip/rga3/include/rga.h`, including the
historically misspelled `RGA_IOC_GET_DRVIER_VERSION`.

`ioctl_test_memory.h` models registered readable/writable user ranges. A short or
invalid range returns a copy residual without dereferencing the invalid address;
failed reads zero the destination, matching the relevant `copy_from_user`
contract. The fixture self-test checks exact-end copies, one-byte overruns,
wraparound pointers, both directions, and surrounding canaries. MPP's scalar
tests additionally assert that rejection makes **no payload access** and leaves
the output sentinel unchanged, even if more memory is mapped than declared.

Kernel allocations, IDRs, mutexes, rwsems, lists and krefs are real. Allocation
wrappers count the driver functions' alloc/free calls; they do not replace
allocations with a success-only model. RGA pool tests replace only the DMA import
backend with a deterministic reference ledger to exercise transactional unwind.
RGA hardware submission is an explicit stop point returning `-ENODEV`, **not a
replacement validator**. Unknown selectors must fail before reaching it.
MPP hardware dependencies fail the test if called. Telemetry filesystem creation
is omitted; the session's actual kref operations still run.

## Case table

All sizes below derive from the actual types/constants in the test source.
`UINT_MAX` and `0x80000000` exercise negative-as-unsigned/wraparound-class values
in the **32-bit** wire fields. Native `SIZE_MAX` is not representable there;
the pre-existing `media_request_size_rejects_overflow_test` remains unchanged and
is not duplicated. Pointer wrap cases use `ULONG_MAX`/`U64_MAX`.

| Interface | Inputs | Asserted result |
|---|---|---|
| MPP outer ioctl | V2, unknown ioctl | `-EINVAL` |
| MPP V1 envelope | null, invalid pointer, zero bytes, 23 bytes | `-EFAULT` |
| MPP V1 envelope | complete no-payload INIT_TRANS_TABLE | `0` |
| MPP command | unknown command `UINT_MAX` | Existing `-EFAULT` ABI |
| MPP request chain | 1, 16 terminated messages | `0`, active message list empty afterward |
| MPP request chain | 17 messages | `-EINVAL`, no stranded message object |
| MPP request chain | two declared through MULTI/LAST flags, only one provided; second header short by one byte | `-EFAULT`, active list empty |
| MPP translation table | zero payload, one `u16`, maximum 80 `u16` | `0`, nonempty successful copies publish the correct element count |
| MPP translation table | maximum +1 byte, maximum +1 element, odd byte count, `UINT_MAX`, high bit | `-EINVAL` |
| MPP translation table | declared two elements with one supplied; null/wrapped payload pointer | Existing `-EINVAL` ABI |
| MPP scalar output | QUERY_HW_SUPPORT sizes 1, 3, 5, `UINT_MAX`, high bit, with a mapped 4-byte buffer | `-EINVAL`; one envelope copy, no payload access, sentinel unchanged |
| MPP scalar output | size 4, or legacy size/offset/flags all zero, valid pointer | `0`, truthful zero capabilities on this no-device fixture |
| MPP scalar output | size 4, null/wrapped pointer or actual buffer only 3 bytes | `-EFAULT` |
| MPP scalar inputs | QUERY_HW_ID, INIT_CLIENT_TYPE, INIT_DRIVER_DATA with sizes 0, 1, 3, 5, `UINT_MAX`, high bit; QUERY_CMD_SUPPORT with the same nonzero invalid sizes | `-EINVAL` before payload access |
| MPP legacy discovery | HW_SUPPORT/CMD_SUPPORT size zero with nonzero offset or flags | `-EINVAL`, no payload access, sentinel unchanged |
| MPP legacy discovery | HW_SUPPORT/CMD_SUPPORT size/offset/flags zero with null/wrapped pointer or only three accessible bytes | Existing checked-word errors: `-EFAULT` for HW_SUPPORT, `-EINVAL` for CMD_SUPPORT |
| MPP command-support query | exact word containing INIT_BASE | `0`, returns INIT_BUTT |
| MPP client index | unprobed 0, 0x12, 0x13, DEVICE_BUTT, `UINT_MAX`, high bit, each with size four | `-EINVAL` |
| RGA outer envelopes | all eight RGA_IOC commands, each with null/wrapped pointer or structure short by one byte | `-EFAULT` |
| RGA outer command | unknown ioctl | Existing `-EINVAL` ABI |
| RGA CONFIG task array | 1 and maximum 256 complete descriptors | `0`, session kref remains 2 (file + request) |
| RGA CONFIG and SUBMIT task array | 0, 257, `UINT_MAX`, high-bit task counts | `-EINVAL` before hardware submission |
| RGA CONFIG and SUBMIT task array | two declared, one supplied; one descriptor short by a byte; wrapped pointer | `-EFAULT`, held request reference balanced |
| RGA CONFIG and SUBMIT task array | null task pointer | Existing `-EINVAL` ABI |
| RGA CONFIG selectors | sync/async; AUTO, both RGA3 cores, RGA2 core0, full mask; every defined render opcode | `0` at configuration only, not a pixel-validity or hardware-completion claim |
| RGA CONFIG selectors | sync 0/`UINT_MAX`, core bits 0x10/0xff, render opcode 0xff | `-EINVAL` before publication |
| RGA CONFIG ownership | another open file's valid request id | `-EPERM` |
| RGA CONFIG id | nonexistent `UINT_MAX` | `-EINVAL` |
| Legacy BLIT_SYNC and BLIT_ASYNC | null task, wrapped task, task short by one byte | `-EINVAL`, `-EFAULT`, `-EFAULT`, respectively |
| Legacy BLIT_SYNC and BLIT_ASYNC | unknown core bits or render opcode | `-EINVAL`, no submission call |
| Legacy BLIT_SYNC and BLIT_ASYNC | complete envelope and known selectors | Reach the named hardware stop point (`-ENODEV`), transient request retired |
| RGA IMPORT/RELEASE pools | zero count with nonnull pointer | Existing no-op `0` |
| RGA IMPORT/RELEASE pools | maximum +1 (41), `UINT_MAX`, high bit | `-EFBIG` |
| RGA IMPORT/RELEASE pools | two declared/one supplied, one descriptor short by a byte, null/wrapped pointer | `-EFAULT`, balanced power calls |
| RGA pool maximum | import/release 40 complete descriptors through fake DMA backend | Import returns last positive handle (existing ABI); release returns `0`; backend refs return to zero |
| RGA pool unwind | second import fails `-EBADF`; output copy fails; second buffer has unknown type | `-EBADF`, `-EFAULT`, `-EOPNOTSUPP`; no invisible imported handle survives |
| RGA CREATE copyback | flags readable, id destination short by one byte | `-EFAULT`; request count 0, session kref 1, allocation count unchanged |
| RGA CANCEL | foreign id, own id, repeat cancel | `-EPERM`, `0`, `-EINVAL` |

MPP has **no declared array-count field**: MULTI_MSG/LAST_MSG terminate a chain.
The zero-length row therefore supplies no readable envelope; the off-by-one rows
leave the promised next message unreadable. These tests do not invent a count
field or treat an unknown userspace allocation length as kernel knowledge.

## Findings and red proof

### Legacy discovery correction (2026-09-09)

The original IOCTL-B01 check below incorrectly classified two established query
shapes as malformed. Installed `librockchip-mpp1 1.5.0-1`, built from
[`tsukumijima/mpp-rockchip@194af181db3a02a095c01db84e176d972e19b216`](https://github.com/tsukumijima/mpp-rockchip/tree/194af181db3a02a095c01db84e176d972e19b216),
sends HW_SUPPORT and CMD_SUPPORT with size, offset and flags all zero. Their
payload remains one accessible `u32`. Its native descriptor is the existing
24-byte layout, not a new ABI or a compat32 envelope.

Rejecting discovery clears the library's hardware-ID census. The H.264 HAL then
defaults from unknown ID zero to VEPU541 instead of selecting VEPU580 for
`0x50603312`. On Rock, emulating only those query rejections reproduced both
size-four INIT_CLIENT_TYPE failures for absent clients 0x12/0x13 and the encoder
stall: a VEPU541 batch starting with 780 bytes at offset 0x10004 is outside the
VEPU580 register map and is correctly rejected. Normal discovery on the same
board/library completed the 30-frame encode. The unsupported-client and
register-range rejections are not additional kernel defects and remain intact.

The corrected contract admits the observed zero-size shape only for these two
query commands, with offset and flags zero. Size-four handling is unchanged.
All other zero-size scalar commands and all nonzero malformed sizes retain
their no-payload-access rejection. The compatibility branch does not identify
or trust an executable: every caller receives the same shape validation and
the existing `get_user`/`put_user` checks. Zero in this legacy shape means an
implicit word, not permission to read an inaccessible buffer.

The corrected tests first failed three of nine ioctl cases on the previous
driver. Coverage retains every earlier malformed nonzero-size, pointer,
canary, allocation and lifecycle assertion, and adds nonzero-offset/flag
rejections for the legacy shape plus the observed unimplemented client values.
This production ABI correction is independent of test-only idle-IOMMU work.

### Original boundary-hardening receipt (historical)

Baseline `cb5302b` with the first new tests, before driver edits:

```text
rockchip-mpp-ioctl: pass:5 fail:1 total:6
  mpp_ioctl_scalar_size_test: declared 0/1/3/5/UINT_MAX/high-bit sizes returned 0
rockchip-rga-ioctl: pass:5 fail:2 total:7
  rga_ioctl_semantics_test: unknown selectors accepted; EPERM/EINVAL became EFAULT
  rga_ioctl_legacy_test: malformed selectors reached submission (6 calls, expected 2)
Testing complete. Ran 75 tests: passed: 72, failed: 3
```

The complete red transcript is retained locally at `.work/ioctl-red.log`.
All 62 pre-existing tests passed. The fixtures were then extended with independent
copy-model checks and the other scalar-input commands; no existing test changed.

The fixed tree passed **78/78 UML KUnit tests**, including all 16 new cases, on
2026-09-05. The complete green transcript is `.work/ioctl-green.log`. Both
sequential lifecycle tests passed with every per-pair baseline assertion intact.
Changed C/header/Python LSP error diagnostics were clean using the generated
kernel compilation contexts. Series parity, UAPI parity and the local lint/tool
self-tests also passed; the separate full CI run remains the module-link gate.

| Finding | Fix |
|---|---|
| IOCTL-B01 — scalar requests disregard their declared payload size | Require exactly `sizeof(u32)`, except the two precisely bounded legacy discovery queries documented above |
| IOCTL-B02 — unknown selectors enter RGA request state | Check sync mode in `rga_request_check`; check every copied task's core mask and render opcode before publishing a replacement task list |
| IOCTL-B03 — RGA wrappers erase specific configuration errno | Preserve `PTR_ERR` at request/config and legacy wrappers; retain `-EFAULT` for actual copy failures |

No UAPI struct layout or command number changes. Known scalar shapes and all
defined selector values remain accepted. Rejecting previously accepted malformed
shapes and exposing the underlying errno are deliberate behavior changes.

## Sequential lifecycle proof

Each interface runs 32 cycles with two independent open file objects (64 releases).
MPP modifies each session's table and allocates its real message object before
close; both the service list and allocation count must return to zero after every
pair. Each new session must start with zero table/message counts and kref 1.

RGA creates one real IDR request per file, observes session krefs 1 → 2, rejects
cross-session cancellation, cancels one request explicitly, and leaves the other
for **the real owning-file release/abort path**. After each pair: both IDRs empty,
session/request counts zero, and only the two fixture manager allocations remain.
Fixture teardown frees those two, returning the allocation count to zero.
Configured task-list allocations and create-copyback unwind are also checked by
each test's teardown. This is reference/allocation balance, **not a kmemleak scan**.

## Reproduce

Use a private clone of the kernel pinned by `kernel-pin.env` at `.work/linux`.
The staging script installs Kconfig/Makefile hooks idempotently. CI invokes the
same script in its existing KUnit job; static-analysis jobs/configs are unchanged.

```bash
python3 tests/kunit/stage_ioctl.py --self-test
python3 tests/kunit/stage_ioctl.py .work/linux
TMPDIR="$PWD/.work" .work/linux/tools/testing/kunit/kunit.py run \
  --kunitconfig="$PWD/tests/kunit" --build_dir="$PWD/.work/kunit" --jobs=12
```

The new selection requires a 64-bit kernel with COMPAT and both hardware drivers
off, avoiding duplicate production symbols. It does not require a device tree.
The existing x86 KUnit runner can also compile this hardware-free selection.

## Explicit limits

- Real architecture-specific user-address validation, partial page faults and
  compat/32-bit ABI execution are not tested. The range fixture models the copy
  result; it is not real `uaccess` or a proof about every possible kernel memory
  read. No universal memory-safety claim follows from a finite table.
- Real DMA-BUF imports, IOMMU/PM resources, register submission, live fences,
  concurrent racing closes, device probe/remove and bound-codec session teardown
  are not exercised. Sequential file sessions are not physical device cycles.
- RGA descriptor geometry/plane validation remains in its existing suite and at
  the real pre-mapping submission boundary. A successful CONFIG stores a list;
  it does not certify that the list could execute on hardware.
- Existing batch-session-fd switching and codec-specific register commands are
  outside the new table. No new coverage is claimed for those branches merely
  because their containing handler is compiled.
