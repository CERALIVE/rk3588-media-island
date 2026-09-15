# RGA round-2 regression locks

Status: **[PARTIAL] — requested software gates passed; no board qualification.**

Starting tip: `82252c4b0`, following production repair `24a8b5b60` on
`fix/rga-table-ownership-memory-routing`. Test commits: `b07904672` (timing) and
`7d1a4b0c1` (low USERPTR). No production driver, UAPI, integration payload or
generated patch changed. No PR, tag, release, consumer-lane or image-pin action.

## What the tests now distinguish

- **Reset epoch ordering:** `rga_start_reset_preserves_error_recovery_test`
  starts with the previous epoch already claimed. The fixture's `set_reg()`
  invokes the initialization reset followed immediately by error recovery.
  Both resets must execute, and error recovery must claim the new epoch.
  Freshly initialized, unclaimed state cannot stand in for this precondition.
- **Milliseconds versus jiffies:** `rga_wait_one_second_per_task_test` asserts
  `RGA_JOB_TIMEOUT_DELAY == 1000` and captures the actual `wait_event_timeout()`
  argument for one and three tasks. Its expectations are one and three seconds
  of kernel ticks (`HZ` and `3 * HZ`), not a conversion of the driver constant.
  The queued cancellation test checks the captured wait too. Existing expired
  hardware-job fixtures use literal 1,001 ms rather than the constant plus one.
- **Low USERPTR execution ownership:** two new DMA-ownership cases use actual
  low backing pages, a foreign RGA3 preparation mapping, and no stageable flag.
  Production `rga_alloc_sgt_segment()` and `rga_free_sgt()` are staged verbatim;
  Linux constructs the SG table. The fake backend supplies a one-page segment
  limit and nonidentity DMA mappings, not a replacement ownership algorithm.
  Two page-bounded entries cover the complete backing pages despite a 128-byte
  user offset. The cases assert RGA2 mapping ownership and reuse, DMA PTE values
  `0x30000000` / `0x30002000`, sync SG/device/direction on both paths,
  bidirectional unmap before SG free, repeated-release safety, and preservation
  of the foreign preparation mapping. A map error must free the constructed SG,
  publish no execution mapping, preserve the output address, and allow a later
  successful map/release.

The DMA API, physical cache hierarchy, GUP and hardware are not exercised. These
are deterministic ownership/SG/PTE boundary tests, not pixel or coherency proof.

## Individual mutation results

Each row ran alone. Before the next row, the staging tool restored all selected
production functions and headers from the unchanged checkout, and the full suite
ran GREEN. No compiler failure is counted as a behavioral RED.

| Isolated mutation | Observed behavioral RED | Full restored run |
|---|---|---|
| Move `media_recovery_started()` from before `set_reg()` to immediately before `set_bit(RGA_JOB_STATE_RUNNING, ...)` | Reset case: one reset instead of two; claimed epoch 1 instead of 2. **122 pass / 1 fail / 1 skip** | **123 pass / 0 fail / 1 skip** |
| Restore `RGA_JOB_TIMEOUT_DELAY` to `HZ`, retaining conversion | Literal contract sees 100 instead of 1,000; captured waits are 10/30 instead of 100/300 jiffies. Both wait cases fail. **121 pass / 2 fail / 1 skip** | **123 pass / 0 fail / 1 skip** |
| Remove only `msecs_to_jiffies()` from the wait call | Captured waits are 1,000/3,000 instead of 100/300 jiffies. Both wait cases fail. **121 pass / 2 fail / 1 skip** | **123 pass / 0 fail / 1 skip** |
| Restore the foreign-mapping bypass for RGA2 USERPTR only | Zero execution mappings instead of one; forced map error returns success without constructing/mapping an SG. Both new USERPTR cases fail; DMA-BUF cases remain green. **121 pass / 2 fail / 1 skip** | **123 pass / 0 fail / 1 skip** |
| Select physical rather than DMA PTE addresses for low USERPTR only | PTEs are `0x00b3e000` / `0x00b3f000`, not `0x30000000` / `0x30002000`. Ownership case fails; DMA-BUF cases remain green. **122 pass / 1 fail / 1 skip** | **123 pass / 0 fail / 1 skip** |

The kernel uses **HZ=100**, so both units regressions are observable rather than
accidentally equivalent at HZ=1000. The PTE mutation independently proves the
nonidentity address assertions, even when an RGA2 mapping still exists.

Mutations were applied only to disposable KUnit build inputs, never to tracked
production files. The epoch mutation changes `rga_fault_source.inc`; the constant
mutation changes the staged `rga3/include/rga_drv.h`; conversion changes
`runtime_pm_rga_jobs.inc`; both USERPTR mutations change `rga_memory_source.inc`.
These `.inc` files otherwise contain byte-preserved production function bodies
with source line markers. The USERPTR ownership rollback inserts this former
RGA2 bypass at the start of `rga_mm_map_job_iommu_buffer()`, narrowed to USERPTR
so the existing DMA-BUF regression cannot be the reason for RED:

```c
if (job->scheduler->data->mmu == RGA_MMU &&
    origin->type == RGA_VIRTUAL_ADDRESS)
        return origin->dma_buffer;
```

The independent PTE mutation replaces `*use_dma_address = true` in the low-memory
branch of `rga_mm_get_rga2_sgt()` with
`*use_dma_address = buffer->type != RGA_VIRTUAL_ADDRESS`.

## Requested gate results

| Gate | Result |
|---|---|
| Full restored KUnit | **123 passed / 1 skipped / 0 failed**, 124 cases, 17 suites |
| RGA-related KUnit subset | **60 passed / 0 skipped / 0 failed** |
| KUnit staging self-test | PASS |
| Host memory gate | PASS; low control `rga2_maps=1`; table, routing, USERPTR alias/staging, unwind and quota checks pass |
| Both arm64 modules | PASS, `KCFLAGS=-Werror`, `rk_vcodec.ko` and `rga_multicore.ko` linked |
| Sparse, both modules | PASS, `C=2 CF=-Wsparse-error`; all 13 selected RGA and eight selected MPP source objects checked |
| Built-module OF aliases | PASS |
| Telemetry source and mutation/control fixtures | PASS, seven cases |
| Producer series check | PASS, nine patches |
| Independent series parity | PASS, 87 source files and eight verbatim integration payloads |
| Changed test C/headers and staging Python LSP errors | None |

The skip remains `mpp_fault_idle_enqueue_races_disable_test`, which requires two
online CPUs and self-skips on single-CPU UML. No test was deleted, weakened or
given a new skip. The three added cases are one wait-contract case and two
low-USERPTR cases; the reset case was strengthened in place.

The previously triaged MPP hardening checker and Coccinelle findings were neither
edited nor re-investigated. The known full-repository MPP checker failure is not
waived by this requested-gate result; see [the original triage](rga-host-465598e26.md).

## Reproduction and evidence

Using the existing prepared pinned UML tree, run from the checkout:

```sh
export TMPDIR="$PWD/.work/verification-465598/tmp"
python3 tests/kunit/stage_ioctl.py --self-test
python3 tests/kunit/stage_ioctl.py .work/verification-465598/linux
python3 .work/verification-465598/linux/tools/testing/kunit/kunit.py run \
  --kunitconfig="$PWD/tests/kunit" \
  --build_dir="$PWD/.work/verification-465598/kunit" \
  --jobs=12 --timeout=300 --json="$PWD/.work/round2/control.json"
```

For a mutation, first stage, apply only its change above to the disposable build
input, then run. Restage and rerun before trying another mutation. The final
restoration run already executes the full unchanged `.kunitconfig`; it was not
repeated after successful verification. Builds ran detached with logs on the
development volume; each run retained parsed JSON, console log, raw KTAP and exit
status. The kernel boots with `mem=1G` through the existing KUnit runner.

The remaining commands were `bash scripts/check-rga-memory.sh`,
`bash scripts/check-telemetry-contract.sh` (also `--self-test`),
`python3 scripts/build-series.py --check`, and
`python3 scripts/verify-series-parity.py`. The existing prepared arm64 tree and
provider configuration were reused. Both module-local `clean` targets ran before
restaging from the checkout; the `modules` targets linked both outputs with
`KCFLAGS=-Werror`, followed by aggregate-object targets with `C=2
CF=-Wsparse-error`. This is module verification, not a full kernel Image build.

Raw receipts are in ignored `.work/round2/`. Each mutation label has `.log`,
`.json`, `.ktap` and `.exit` files; every `-red` exited 1 and every `-green` exited
0. SHA-256 custody of all ten raw KTAP runs:

```text
epoch-red.ktap                 1375e92132e43ca92bf670e71e3595e3a1fc909a2bd55b5865fe8efb41892159
epoch-green.ktap               ff4e4509eb5eaed0f1b6ea069519e115c7236bf68b1fbc8a3fee339c324b8b39
timeout-constant-red.ktap      eca6606406411eb2b1db4db5f175906873547962c2ff0aaa2ce2be95b040d369
timeout-constant-green.ktap    d78b327033dc747dc5c45984b0c2ae79fe1a76077cf699f4bf609703f0f2c855
timeout-conversion-red.ktap    441a54beb49419618150259f1b6c765528ed52c9f5aad10baf3bb41a4dd58a03
timeout-conversion-green.ktap  84c1ce670f6529495045dfee75523f52cd1a55fcd243669d38af0a5804a2fd34
userptr-owner-red.ktap         189e3f021d9b297bf431f811d5664059645c03883258c11d8b2e00c16cd0b87d
userptr-owner-green.ktap       4d16597777b0f9b4a87df1cc8d53bf40edafcae9d063b9774d04477df0027fb7
userptr-physical-pte-red.ktap  c6a54d24b8fa84b66e7985c6b23028289ade1a7d1c297a99144d8df1d6b5169f
userptr-physical-pte-green.ktap 214d41511642948a4548aadf3fe0f3ea14d962686cbb3152991d206b74ebf2b1
```

All five restored JSON files have SHA-256
`9e6a460cc43807a068faf7cbc8e51078f8ff48a1b2098d559d329d70846ceb17`.
The remaining gate log hashes are:

```text
arm64.log     a3a2cb456fb42e40c8c91d90226910327dee02c8aa5145d7fdac0241a13bb060
memory.log    fa3752755ded035ba13d2e128561abe2e4fa7b188d6d424105de49cfdf12ad95
telemetry.log 4351cd168b49ca81e3b1a741d4212a6bcb00f379c7c88f2be2cd5d319e0cb7a0
series.log    5ef87d1eedffd24b4af3acbff13386539662bafeaf5761a43910ea06424a2aec
```
