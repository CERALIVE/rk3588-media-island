# RGA blocking-review repair: host verification

Status: **[PARTIAL] — requested software gate passed; no board qualification.**
Source commit: `24a8b5b60`, on `fix/rga-table-ownership-memory-routing`, following
the reviewed `f5b2fb06e` tree. No release, tag, consumer-lane or image-pin operation.

## RED before repair

The low-buffer control and reset-lifetime regression were changed before any
driver source edits:

```text
LOW_RGA2_CONTROL ret=0 failed_maps=0 rga2_maps=0 iommu_maps=1 under4g=1
RED: reachable execution buffer lacks an RGA2-owned map

rga_failed_reset_retains_tables_test:
  expected retained PTE, observed NULL
  expected unmaps=0, observed 1
  expected retired=0, observed 1
  expected power references=1, observed 0
```

The reset case executed the maintained scheduler abort function in UML, with
reset failure supplied at the hardware boundary. Its first run had 110 passes,
one new failure and the one existing MPP skip. Before the wait-path edit, the
queued-deadline regression also failed: return zero, queued job still present,
and no queued retirement. Earlier fixture build/link failures were setup errors,
not RED behavioral evidence.

## Final results

| Gate | Result |
|---|---|
| Arm64 RGA and MPP module build | PASS, `KCFLAGS=-Werror`, both `.ko` outputs |
| Sparse, both modules | PASS, `C=2 CF=-Wsparse-error` |
| Built-module OF alias contract | PASS |
| Host memory gate | PASS; low control has `rga2_maps=1`, high controls avoid doomed maps |
| Live-table regression | PASS; 262,144 live entries in both arrangements, no overlaps, balanced failed construction |
| USERPTR/staging regression | PASS; aliases, writable spans, cancellation, fault unwinds and quotas retained |
| Routing/admission regression | PASS; busy-RGA3 preference, full-queue `-EAGAIN`, explicit RGA2 preserved |
| Producer series check | PASS, nine generated patches |
| Independent series parity | PASS, 87 source files and eight verbatim integration payloads |
| KUnit | **120 passed / 1 skipped / 0 failed**, 121 cases across 17 suites |
| RGA-related KUnit subset | **57 passed / 0 skipped / 0 failed** |
| Telemetry source contract and mutation fixtures | PASS, seven mutation/control cases |
| Compat and modernization checks | PASS |
| Changed C/header, Python and shell LSP errors | None |
| `.c.in` template diagnostics | No LSP server; emitted C compiled by the host regression gate |

The only KUnit skip is the unchanged MPP two-online-CPU interleaving case on
single-CPU UML. The ten additional RGA cases comprise three reset/poll/epoch
cases, five runtime-PM lifetime/deadline/admission cases, and two execution-DMA
ownership/error cases. The DMA fixture deliberately makes `sg_phys()` differ
from the execution DMA address and checks PTE content, device identity, both
sync directions, and unmap. These fixtures do not model the physical cache
hierarchy or prove correct pixels on RK3588.

The telemetry checker was updated from a `void` to an `int` reset declaration
contract, including its synthetic fixture. No existing test was removed or
skipped. The independent MPP hardening checker defect and previous Coccinelle
dispositions remain as documented in [the earlier receipt](rga-host-465598e26.md);
they were not changed or re-investigated. This is not a claim that the unrelated
full-repository MPP checker is now green.

## Reproduction and artifact custody

Run `bash scripts/check-rga-memory.sh`, `python3 scripts/build-series.py --check`
and `python3 scripts/verify-series-parity.py` from the checkout. The arm64 run
restaged maintained RGA/MPP sources into the existing prepared Linux 7.2 arm64
tree, then ran each module's `modules` target with `KCFLAGS=-Werror`, followed
by its aggregate object target with `C=2 CF=-Wsparse-error`. Provider configuration
and integration inputs were reused; this was not a full Image build.

UML used the pinned kernel tree and existing build directory from the earlier
receipt, refreshed with `tests/kunit/stage_ioctl.py`. The command was:

```sh
export TMPDIR="$PWD/.work/verification-465598/tmp"
python3 tests/kunit/stage_ioctl.py .work/verification-465598/linux
python3 .work/verification-465598/linux/tools/testing/kunit/kunit.py run \
  --kunitconfig="$PWD/tests/kunit" \
  --build_dir="$PWD/.work/verification-465598/kunit" \
  --jobs=12 --timeout=300 \
  --json="$PWD/.work/verification-465598/final-review.json"
```

Builds ran detached. All artifacts stayed on the development volume in ignored,
repo-local directories. Final successful builds were not repeated. The final
telemetry checker edit changed only the shell assertion/fixture, not compiled
source. SHA-256 receipts (logs/JSON relative to `.work/verification-465598/`):

```text
reset-red.log       2babf4519ae620fceefe29a7b173ed20c1ddb0928ec2a57b760c64ece76a9bc3
queue-red-valid.log 10823f57a2d0ef6c813a89141eab711f37c5be943bcb7030a6dae47e50f894b1
final-review.log    e914cecd5d6d23a4774a5cc925598572ca05fce967db91db67b282f95eab6d82
final-review.json   670e7aef007d495eb5aeb5c367706c0ae9de1a464d87a765576e8d2b71ee4b43
final-arm64.log     a3a2cb456fb42e40c8c91d90226910327dee02c8aa5145d7fdac0241a13bb060
rga_multicore.ko    a9df52a80da01f65b3bfe8fd72199dfb793f7a04e0f15b886750fda879811ff0
rk_vcodec.ko        32a99008dac34d4ae6b355c0fcb350c2fc5b14f2f4b3511e43efbb7bdd71524c
```

The module files reside under `.work/linux-arm64/drivers/video/rockchip/` in
their respective driver directories. No module was loaded onto a board.
