# MPP code-quality sweep — 2026-09-05 [PARTIAL]

## Scope and acceptance boundary

Baseline: `cb5302b` (modernization PR #3), including `3baee6c` (provider-cache
PR #4), fetched before branching. Kernel base:
`8d3ae59288f1e7d58d76558a6ee96d533bc5019f`, verified in both cached kernel
trees. Private copies of the configured arm64 tree and existing UML KUnit tree
were used so concurrent work could not change the analysis inputs.

The selected composite is `drivers/video/rockchip/mpp/rk_vcodec.o`:
`mpp_service`, `mpp_common`, `mpp_iommu`, `mpp_trace`, `mpp_rkvenc2`,
`mpp_rkvdec2`, `mpp_rkvdec2_link`, and `mpp_jpgdec`. Sparse and instrumented
arm64 compiles cover these eight translation units. Coccinelle report mode
scans the entire MPP directory, including retained but unselected clients.
No RGA source, RGA IOCTL entry point, kernel pin, device configuration, or
physical board was changed. Existing RGA helper tests remain in the unchanged
KUnit selection; running them does not constitute an RGA driver sweep.

**The full-driver zero-KASAN / zero-serious-lockdep / zero-kmemleak acceptance
bar is NOT established.** UML and generic x86 QEMU have no RK3588 codec, IOMMU,
interrupt, reset, or device-tree provider hardware. They execute the production
helpers included by KUnit, not the complete codec drivers. For those hardware
paths each runtime detector **requires physical board boot, not run here**.

## Tool results

| Tool | Execution and observed result | Limits |
|---|---|---|
| sparse | Completed `C=2 CF=-Wsparse-error`, GCC `KCFLAGS=-Werror`, all eight selected objects; no diagnostics | Pinned sparse `37156835e3d725b6d750f000be33ba3814bb2310` (`v0.6.5-rc1`), not the older distro parser |
| coccinelle | Completed the pinned kernel's standard report-mode semantic-patch set over MPP; nine initial source reports, individually disposed below | Report mode does not run patch-only `api/kmalloc_objs.cocci`; the tool explicitly reports that omission |
| smatch | **NOT RUN** | Not installed and no invocation exists in `scripts/` or CI. `docs/CI.md` already makes this conditional; no new smatch toolchain was installed |
| KASAN | UML kernel built and booted with `KASAN=y`, `KASAN_GENERIC=y`; existing 62/62 tests passed, no KASAN report | Helper coverage only; instrumented arm64 MPP composite also compiles |
| UBSAN | Enabled in the same UML build (`UBSAN=y`, `UBSAN_BOUNDS=y`); no runtime UB report | Resolved config is retained; not a claim that every optional UBSAN mode is enabled |
| lockdep | `DEBUG_KERNEL=y`, `PROVE_LOCKING=y`; UML boot prints the lock dependency validator banner, no locking warning | Not a test of the real queue/IRQ/DMA-reservation lock graph |
| KCSAN | Separate two-vCPU x86-64 QEMU kernel via the existing `kunit.py` runner; 62/62 baseline tests passed, no KCSAN report | UML rejected `KCSAN=y` because it lacks `HAVE_ARCH_KCSAN`; QEMU uses the kernel runner's shipped x86 config, not a new board emulator |
| kmemleak | Separate UML kernel with `DEBUG_KMEMLEAK=y`, `DEBUG_KMEMLEAK_AUTO_SCAN=y`; 62/62 baseline tests passed; first automatic scan returned with `found_leaks=0` | A short default KUnit boot is insufficient; diagnostic-only delay described below. No long-duration leak soak |

The three separate arm64 configurations also compiled the complete selected MPP
composite with `-Werror`: (1) KASAN + UBSAN + lockdep, (2) KCSAN, (3) kmemleak
+ lockdep. KCSAN requires `EXPERT=y` on this arm64 kernel; checking the resolved
config caught its initial omission. These are instrumented **object builds**,
not bootable arm64 images or module-link claims. No sanitizer report count is
inferred from a successful compile.

## Finding ledger

Locations below name the initial baseline so they remain interpretable after
the fix shifts line numbers. Severity rates the reviewed defect, not the
capitalization of the semantic patch's message.

| ID | Initial report | Severity | Disposition and rationale |
|---|---|---|---|
| MPP-H01 | `mpp_rkvenc2.c:3465`, `mpp_rkvdec2.c:1898`: opportunity for `min()` | Low | **FIXED.** Reviewing both resource-to-RCB allocation paths exposed narrowing of `resource_size_t` to `u32` *before* the minimum. Both use `mpp_rcb_sram_size()` in `mpp_request_bounds.h`, computing `min_t(u64, requested, available)` before returning `u32`. Multi-gigabyte spans now clamp rather than wrap. Trusted DT and small real SRAM bound severity; no real-board failure is claimed. |
| MPP-H02 | `mpp_iommu.c:1068`: missing `put_device()` after `of_find_device_by_node()` | None (false positive) | **LEDGERED, no fix.** Error paths reach `err_put_pdev`, which calls `platform_device_put()`. That wrapper calls `put_device(&pdev->dev)` in pinned `drivers/base/platform.c:590–593`. Success transfers the held reference to `info->pdev`; `mpp_iommu_remove()` releases it. Both probe unwind and device removal call that teardown from `mpp_common.c`. Adding the suggested release would double-put the error path or prematurely release the successful probe's reference. |
| MPP-H03 | `mpp_rkvdec2_link.c:1129`: iterator referenced after loop | None (false positive) | **LEDGERED, no fix.** `dump_mem_region` starts at zero and becomes one only immediately before `break` on a real list member with no completion IRQ. The post-loop dereference is guarded by that flag and stays under `running_lock`. Empty lists and fully completed lists do not dereference the terminal iterator. The rule does not track this flag/break implication. |
| MPP-H04 | `mpp_rkvenc2.c:2757`: preceding lock at line 2713 | None (false positive) | **LEDGERED, no fix.** Under the same DEVFREQ preprocessor condition and `enc->devfreq` guard, the reset function locks at entry and unlocks at `out_unlock`. Reset failure jumps to that label, and success falls through it; there is no intervening return or reassignment of `enc->devfreq`. DEVFREQ is not selected by the production closure either. Do not remove synchronization to satisfy this path-insensitive report. |
| MPP-H05 | `mpp_rkvenc2.c:1155`: use `str_enabled_disabled()` | Informational | **LEDGERED, deferred style-only conversion.** Existing ternary produces the same two strings, on a diagnostic path. No bounds, ownership, or synchronization defect; avoid unrelated diagnostic churn in this correctness change. |
| MPP-H06 | `mpp_rkvdec2_link.c:2147`: use `str_write_read()` | Informational | **LEDGERED, deferred style-only conversion.** Existing ternary has identical output for the boolean status bit. No runtime defect; same rationale as H05. |
| MPP-H07 | `mpp_rkvenc2.c:1325`: unsigned `offset_bs > 0` | None (false positive) | **LEDGERED, no fix.** The rule notices the signed return type of `mpp_query_reg_offset_info()`, but its implementation returns a stored `u32` offset or zero, never an errno. The unsigned destination preserves the offset bits; `> 0` is an intentional nonzero-length sync check, not an impossible condition or missed negative errno. This disposition does not certify every caller's buffer bounds. |
| MPP-H08 | `mpp_vepu2.c:207`: same unsigned comparison | None (false positive; unselected client) | **LEDGERED, no fix.** Same offset accessor and nonzero-length semantics as H07. Coccinelle sees the retained source even though VEPU2 is not compiled. No additional client was enabled. |

H01 covers two reports; H02–H08 cover the other seven. No findings are suppressed
in sparse, coccinelle, KUnit, or the kernel configuration.

### MPP-H09 — stale reset-error source checker (Low, FIXED)

The broader local gate found `check-mpp-hardening.py` reporting 22/23 rather
than passing: its reset-return assertion searched only `mpp_dev_reset()`, but
PR #3 had extracted the actual hardware operation into `mpp_dev_reset_once()`.
The driver still propagates errors through `mpp_hw_recover()`. The checker now
follows all three functions and additionally requires the IOMMU-refresh fallback
error and saved recovery result. Its self-test first reproduced rejection of
the correct current source; it now accepts that source and rejects four
independent mutations that swallow hardware-reset, IOMMU-refresh, callback, or
wrapper errors. No driver reset behavior changed and no assertion was removed.

### Final verification

- **63/63 KUnit tests passed in each of the three final builds:** KASAN + UBSAN
  + lockdep UML, KCSAN two-vCPU QEMU, and kmemleak UML. Full boot logs contain
  no sanitizer, runtime-UB, locking, or suspected-leak report; the final kmemleak
  scan again returned `found_leaks=0` before shutdown.
- Sparse again completed all eight selected objects with no diagnostics.
  Coccinelle again completed; H01's two reports disappeared and the seven
  explicitly ledgered reports remained. The standard rules also print four
  metavariable-authoring warnings (`noop_llseek` / `nonseekable_open`), not MPP
  source findings; they did not prevent rule execution.
- All three instrumented arm64 MPP composite builds passed. The normal configured
  `rk_vcodec.ko` linked with strict modpost and `KCFLAGS=-Werror`, using the
  existing configured provider symbol table, without unresolved-symbol suppression.
- Series generation and independent parity passed (84 source files, eight
  integration payloads). Shellcheck, harness/tool self-tests, shim and DT-ownership
  source checks, modernization/module/telemetry contracts, all 23 MPP hardening
  assertions, its eight self-test checks, and all 11 UAPI tests passed. Existing
  board-probe host self-tests passed; their DMA-heap exercise explicitly reported
  no usable host heap and was not claimed as hardware coverage.
- LSP diagnostics were clean for all five changed code files after providing
  a temporary compilation database derived from these builds. The initial bare
  editor context lacked kernel headers; clang also needed `-fms-extensions` for
  the kernel's anonymous struct fields. That editor-only setup was not committed.

The checker failure and its red regression are retained separately in
`final-gates.log` and `checker-red.log`; `final-gates-rest.log` records the fixed
checker and remaining gates. No full cloud CI run or physical-board qualification
is claimed by these local results.

### Regression proof for H01

The shared helper was first extracted with the original narrowing semantics:
`u32 size = available; return min(requested, size);`. The new
`mpp_rcb_sram_size_clamps_before_narrowing_test` then failed under the
KASAN/UBSAN/lockdep UML build: **62 passed, one failed**. Two assertions failed:

```text
mpp_rcb_sram_size(4096, 1ULL << 32) == 0       (expected 4096)
mpp_rcb_sram_size(8192, (1ULL << 32) + 4096) == 4096 (expected 8192)
```

The test also covers resource-limited, request-limited, equal, zero, and
`U32_MAX`/`U64_MAX` boundaries. Both real allocation call sites use this tested
helper; neither carries a second private minimum. Existing tests are unchanged.

## Reproduction and evidence

Use the staging and configuration steps from `.github/workflows/ci.yml` and
`README.md`. There is no `docs/kernel-build-from-source.md` in this repository.
The initial cached arm64 tree used the CI image fragment plus the island fragment
and the exact three-client selection. Build tools used locally were host GCC
16.2.1, arm64 GCC 16.1.0, and sparse at the CI pin above. Coccinelle 1.3 was
installed with OCaml and `libpython3.13` in a disposable Debian Trixie container;
the first attempt failed to load that Python library and was not counted as a run.

After staging current MPP source into the configured kernel tree:

```bash
make -C .work/hardening-linux ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  -j12 CHECK="$PWD/.work/sparse/sparse" C=2 CF=-Wsparse-error \
  M=drivers/video/rockchip/mpp rk_vcodec.o KCFLAGS=-Werror
make -C .work/hardening-linux ARCH=arm64 coccicheck MODE=report \
  M=drivers/video/rockchip/mpp J=8
```

The existing CI KUnit staging copies the production helper headers and
`tests/kunit/` into the pinned kernel and adds its Kconfig/Makefile hooks.
Use that same staging for each following invocation, with separate build dirs:

```bash
TMPDIR="$PWD/test-results/hardening" \
.work/hardening-uml/tools/testing/kunit/kunit.py run \
  --kunitconfig="$PWD/tests/kunit" --build_dir="$PWD/.work/hardening-kasan" \
  --jobs=12 --timeout=180 --kconfig_add=CONFIG_DEBUG_KERNEL=y \
  --kconfig_add=CONFIG_KASAN=y --kconfig_add=CONFIG_KASAN_GENERIC=y \
  --kconfig_add=CONFIG_UBSAN=y --kconfig_add=CONFIG_UBSAN_BOUNDS=y \
  --kconfig_add=CONFIG_PROVE_LOCKING=y

.work/hardening-uml/tools/testing/kunit/kunit.py run --arch=x86_64 \
  --kunitconfig="$PWD/tests/kunit" --build_dir="$PWD/.work/hardening-kcsan-qemu" \
  --jobs=12 --timeout=180 --kconfig_add=CONFIG_DEBUG_KERNEL=y \
  --kconfig_add=CONFIG_KCSAN=y --kconfig_add=CONFIG_SMP=y --qemu_args='-smp 2'
```

For kmemleak use another UML build directory and select `DEBUG_KERNEL`,
`DEBUG_FS`, `DEBUG_KMEMLEAK`, and `DEBUG_KMEMLEAK_AUTO_SCAN`. **Do not count a
normal subsecond KUnit boot as a completed leak scan.** The existing executor
halts before the scanner's `SECS_FIRST_SCAN=60` delay. For this run only, the
private kernel's `lib/kunit/executor.c` included `linux/delay.h` and delayed
`kunit_handle_shutdown()` by `msleep(65000)` when AUTO_SCAN was enabled. The
private `mm/kmemleak.c` added a `pr_info` immediately after the automatic
`kmemleak_scan()` call and mutex unlock to print `kmemleak_found_leaks`.
No detector algorithm, minimum object age, suppression, or test was changed.
The exact diagnostic diff is retained with the raw evidence, not shipped in
the generated island series. The boot showed:

```text
kmemleak: Kernel memory leak detector initialized
kmemleak: Automatic memory scanning thread started
hardening: retaining KUnit boot for the first kmemleak scan
kmemleak: hardening: automatic kmemleak scan returned; found_leaks=0
reboot: System halted
```

Evidence is repository-local and ignored under `test-results/hardening/`:
static-analysis logs, baseline and regression KUnit logs, full kernel boot logs,
resolved configs, instrumented arm64 compile logs, and the diagnostic-only
kmemleak harness diff. A failed initial configuration or dependency attempt is
retained separately rather than overwritten by a successful run. Smatch and
full-driver board-runtime gaps remain open regardless of helper test results.

## Input-boundary KUnit work — separate branch, 2026-09-05

The parallel input-boundary task is on `test/ioctl-input-boundaries`, based on
the same `cb5302b`. Its detailed case table and reproduction instructions travel
with that branch in `docs/IOCTL-BOUNDARY-TESTS.md`. This section is appended,
not a replacement or reinterpretation of the static-analysis results above.

The first executable UML run compiled byte-preserved MPP/RGA ioctl and session
functions with bounded user-copy fixtures: **72/75 passed, three new tests red**;
all 62 pre-existing tests passed. Findings:

- **IOCTL-B01:** MPP scalar requests accessed four bytes regardless of their
  declared size. Sizes 0/1/3/5/UINT_MAX/high-bit returned success. The branch
  requires exactly one word before the five scalar command paths access data.
- **IOCTL-B02:** RGA CONFIG stored unknown sync modes/core bits/render opcodes;
  the same malformed legacy descriptors reached the hardware submission seam.
  The branch rejects unknown selectors before publishing a replacement list.
- **IOCTL-B03:** RGA's request/config and legacy wrappers replaced specific
  errors with EFAULT. The branch propagates the underlying errno, including
  EPERM for another session's request and EINVAL for invalid configuration.

Both sequential lifecycle tests already passed on the baseline: 32 cycles ×
two independent files per interface, real session/message/request allocations
and krefs, empty service list/IDRs after each pair, no surviving request/session
allocation. DMA imports are a reference-counted fixture, not real DMA-BUFs.
This task does not claim a kmemleak scan, real uaccess/compat behavior, hardware
completion, probe/remove coverage, or a change to the detector tooling above.
Final branch verification is reported with the input-boundary task's delivery.

**Input-boundary delivery verified:** commits `e584127` (suite and fixes) and
`8bf90ab` (case table/proof limits), pushed on `test/ioctl-input-boundaries` after
a fresh fetch and no-op rebase onto `origin/main`. Local UML passed **78/78**;
all 16 new cases and both 32-cycle/two-file lifecycle tests passed. Changed
C/header/Python LSP error diagnostics were clean with kernel compile contexts.
[CI run 34007195868](https://github.com/CERALIVE/rk3588-media-island/actions/runs/34007195868)
passed all 13 jobs, including KUnit, strict arm64 module links, both DTBs, and the
unchanged static-analysis gate. No PR was opened and no plan checkbox was edited.
