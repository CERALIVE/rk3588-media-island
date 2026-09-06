# Runtime-PM balance audit

Status: [EXISTS] — static audit and regression fixes; off-hardware verification
is recorded below. This is only the runtime-PM half of the medium promotions.
No thermal adapter, cooling map, thermal verdict, or board measurement is included.

## Scope and method

Baseline: `1e3c013` (main after PRs #3, #4, #5 and #6). Locations below refer to
that baseline so findings remain reproducible after edits move line numbers.
Paths beginning `mpp/` or `rga3/` are relative to `drivers/video/rockchip/`.

The census searched the entire maintained driver tree for `pm_runtime_get*`,
`pm_runtime_resume_and_get`, `pm_runtime_put*`, `pm_runtime_enable`,
`pm_runtime_disable`, `pm_runtime_use_autosuspend`, and
`pm_runtime_set_autosuspend_delay`. Each acquisition function was read through
every return and unwind, then traced through its callers to completion, reset,
cancellation and probe cleanup. A reference transferred to a running job or a
powered decoder queue is not expected to be released at the submit return.

There are no `pm_runtime_get_sync()` or `pm_runtime_get()` calls. The eight
compiled acquisition sites use seven `pm_runtime_resume_and_get()` calls and
one conditional dump acquisition; the exact census is in the next section.
Failed `resume_and_get` calls retain
no usage reference; adding a put to those failure returns would introduce an
underflow, not fix a leak.

This audit is distinct from the runtime-PM fault class already covered by
[`FAULT-CAMPAIGN.md`](FAULT-CAMPAIGN.md). It checks ownership and unwind paths,
not whether a physical power domain resumes correctly.

## Acquisition and release ledger

| Acquisition | Every exit / reference owner | Baseline verdict |
|---|---|---|
| `mpp_common.c:172`, `mpp_dump_task` | Non-positive conditional get owns nothing. Positive result reads a bounded register loop and reaches the put at 177 without an intervening return. Capture occurs after the put. | BALANCED |
| `mpp_common.c:301`, `mpp_power_on` | Resume failure returns without a ref; clock failure relaxes wakeup and puts at 313; success transfers one ref to its caller. | BALANCED locally |
| `mpp_common.c:3020`, `mpp_dev_probe` | Earlier resource/IOMMU/init failures occur before acquisition. Resume failure goes to `failed` with no ref. Clock failure puts at 3029 before `failed`. ID read success disables clocks and puts at 3037. Negative `reg_id` skips both get and put. `failed` disables PM; success leaves PM enabled with no usage ref. | BALANCED |
| `mpp_rkvdec2_link.c:974`, `rkvdec2_link_power_on` | Already-enabled latch returns without another get. IOMMU attach failure precedes get. Resume failure clears latch with no put. Clock failure puts at 987. Activation failure unwinds IRQ/clocks, puts at 1015, clears latch. Success transfers one ref to the queue; `link_power_off:1032–1048` atomically clears latch and puts once. | BALANCED |
| `mpp_rkvdec2_link.c:1827`, `rkvdec2_ccu_power_on` (CCU) | Already-enabled latch takes no ref. Resume failure clears latch. CCU clock failure puts at 1838. Every subsequent core failure reaches the CCU put at 1899. Success transfers ownership to the queue; `ccu_power_off:1908–1927` clears latch and puts CCU once at 1916. | BALANCED |
| `mpp_rkvdec2_link.c:1849`, `rkvdec2_ccu_power_on` (each core) | Failed resume is not counted in `powered`. Clock failure puts the current core at 1860 before unwinding earlier cores. `powered` increments only after clocks succeed, before activation. Activation failure therefore includes the current core in the reverse put loop at 1893; `activated` separately limits IOMMU cleanup. Success puts each core at 1925 when queue power ends. | BALANCED |
| `rga_drv.c:463`, `rga_power_enable` | Resume failure owns nothing; bulk-clock failure puts at 485 without incrementing `pd_refcount`; success increments it and transfers a ref. `rga_power_disable:490–514` decrements it and puts once; its idle/zero guard does not itself acquire anything. | Local unwind BALANCED; caller leak PM-B01 below |
| `rga_drv.c:1681`, `rga_drv_probe` | All allocation/resource/IRQ/clock-lookup failures precede get. Failed resume goes directly to `pm_disable`. Clock failure goes through the one `pm_put:1780`. All version branches converge on the put at 1729; later IOMMU failure disables PM without a second put. Success owns no ref. | BALANCED; autosuspend missing (PM-A01) |

The ninth lexical acquisition, `mpp_av1dec.c:738`, is in an **unselectable**
client (`ROCKCHIP_MPP_AV1DEC=n`). It was still read: both early returns own no
ref; successful conditional acquisition reaches `put_noidle:743` before either
IRQ result. No AV1 device is added to the island verdict denominator.

## Caller and lifecycle trace

### MPP task references

`mpp_task_worker_default:1260–1334` selects the actual core and calls
`mpp_task_run:998–1147`. GRF and IOMMU-attach failures precede power acquisition;
power-on failure is already unwound. IOMMU prepare, activate, backend run and
commit failures each reach exactly one `mpp_power_off` (1062, 1090, 1105, 1132).
The worker's `mpp_taskqueue_fail_running` only retires the task; it does not put
again. On success the running task owns the reference.

IRQ/timeout processing is serialized by the HANDLE claim, IRQ disable and
timeout-work cancellation in `try_process_running_task:1214–1257`. Encoder ISR
(`mpp_rkvenc2.c:2014–2050`), JPEG ISR (`mpp_jpgdec.c:509–535`), and default
decoder ISR (`mpp_rkvdec2.c:650–678`) clear `cur_task` before reaching
`mpp_task_finish:2731–2791`. A missing current task does not put. Finish and
reset-error branches all converge on the put at 2770. The diagnostic dump's
conditional reference is separate and balanced. Poll interruption/nonblocking
`EAGAIN` leaves the running reference with the worker, not the waiting ioctl.

`mpp_power_off:321–335` uses autosuspend when pending/running work exists and
synchronous suspend otherwise; both branches decrement once. Runtime callbacks
do not acquire usage references. Decoder callbacks separately manage clocks;
clock-reference counts must not be confused with runtime-PM usage counts.

### Decoder queue references

The current RK3588 DT dispatches cores to `rkvdec2_core_probe` and defaults the
CCU to software scheduling. Soft and hard CCU workers share the same latched
power owner. Soft-worker reset failure retains power while tasks remain owned;
it does not acquire again on retry. Both workers release at their empty
pending/running-list tail (2512 / 3121). Failed power-on retires the pending
task after the local unwind, without a second put. Hard mode also returns its
prepared table on failure. These are queue-lifetime refs, not one get per task.

The compiled standalone-link alternative was also traced: `mpp_task_queue`
can return `EBUSY` or `ENOMEM` after acquiring queue power, but the pending or
running task still owns that queue epoch. Its worker retries or processes the
session abort and releases via the empty-queue tail at 1558. Those returns are
not orphaned per-call references. Reset-failure retention is not proof of
successful hardware recovery, and this audit makes no such claim.

Encoder and decoder post-common-probe failures reach `mpp_dev_remove` after
their private unwind; the hardware-ID ref was already put. The JPEG IRQ-failure
branch does not perform that cleanup (PM-B02). Service removal flushes/stops
workers before driver removal. Static balance assumes valid bound-device and
queue lifetimes; it does not certify arbitrary live unbind or corrupted queues.

### RGA references

- `rga_power_enable_all:517–535` unwinds only successfully enabled earlier
  schedulers on failure. Import/release ioctls (1247–1265) call disable-all after
  either result from the buffer helper, but not after failed enable-all.
- `rga_job_commit:569–683` owns a temporary mapping ref. Both command-buffer
  allocation branches, task-buffer allocation, mapping, register initialization
  and shutdown-at-insertion errors reach one disable; pre-power errors do not.
  Success releases this temporary ref at 669, independently of execution.
- `rga_job_run:271–296` takes the execution ref. Failed power-on owns nothing;
  failed register programming puts once. `rga_job_next` clears a failed running
  publication without another put. Its job mutex prevents abort from observing
  a half-started job.
- Completion removes `running_job` under the mutex, then `rga_isr_thread`
  releases its execution ref at 1437. Timeout cleanup removes the same owner
  and releases at `rga_job.c:482`. Null/not-finished/too-young branches leave
  ownership unchanged; they do not put.
- Scheduler shutdown and global abort take a **separate temporary reset ref**.
  Each releases that ref only if acquisition succeeded (973 / 1027), and
  independently releases a removed running job (971 / 1015), even if the
  temporary acquisition failed. Two puts here correspond to two real gets.
- Per-request cancellation removes matching queued jobs without putting an
  execution ref they never acquired. A removed running job must release one;
  its status-gated branch at 1093 is PM-B01. Null or another request's running
  job must not put. Cleanup and restart occur after ownership withdrawal.

The legacy, unselectable `mpp_rkvdec.c:770–797` additionally ignores an indirect
`mpp_power_on` failure before calling `mpp_power_off`. This is **not** either
RK3588 RKVDEC2 core, and is not fixed or promoted here. Enabling that client in
a future island requires addressing this separate inherited error path.

## Findings

### PM-B01 — RGA cancellation can leak the execution reference

At `rga_job.c:1093`, cancellation puts only if the removed running job's saved
scheduler status equals `WORKING`. Global abort sets `ABORT` at 994, starts the
next queued job at 1008 **before** releasing the old execution and temporary
reset refs, and `rga_power_enable:476` changes status only from `IDLE`. Thus the
next job runs with status `ABORT` and still owns a PM ref. Cancelling that job
removes it but skips its put, leaving `pd_refcount` and runtime usage elevated.

Fix: release based on the running job actually removed under `job_mutex`, not
the scheduler's status. This also covers the equivalent overlap with another
temporary mapping/import reference. Do not force status to `WORKING` to conceal
the ownership bug.

### PM-B02 — JPEG failed IRQ registration leaves PM enabled

`mpp_jpgdec.c:640–643` returns after successful `mpp_dev_probe` without calling
`mpp_dev_remove`. The hardware-ID usage reference is balanced, but runtime PM,
wakeup and the common device attachment remain initialized on failed probe.
Fix: call the common removal unwind before returning the IRQ error. This is an
enable/disable lifecycle defect, **not** a second usage-reference leak.

### PM-A01 — all three RGA cores lack autosuspend policy

`rga_drv.c:1677–1681` enables runtime PM without setting an autosuspend delay or
using autosuspend. Normal release at 512 always forces synchronous suspend.
Fix: configure 2000 ms, matching the island MPP domain policy, and mark last
busy / put-autosuspend at normal release. Clocks remain explicitly gated per
reference; only the power-domain idle policy changes. Failed clock activation
still uses synchronous unwind. The delay is a conservative starting policy,
not a board-measured optimum or a thermal-control mechanism. Probe success and
clock-failure puts explicitly suspend synchronously so failed probe cannot leave
a delayed suspend behind. Remove requests immediate suspension after draining
jobs, disables PM, and undoes autosuspend policy; both probe-error exits also
undo that policy. No usage reference is acquired by that removal suspend call.

API reference: [Linux runtime-PM documentation](https://docs.kernel.org/power/runtime_pm.html).
`pm_runtime_disable` is not a put and cannot repair a leaked usage count.

## Per-device verdict

| Island device | Autosuspend configured (baseline → fixed) | Get/put balance verdict | Fix applied |
|---|---|---|---|
| `mpp_srv` | No; N/A, software-only, no delay | BALANCED: no runtime-PM acquisitions | None; do not invent a hardware PM lifecycle |
| `rkvenc0` | Yes, 2000 ms (`mpp_common.c:2957–2973`) | BALANCED | None |
| `rkvenc1` | Yes, 2000 ms (same common probe) | BALANCED | None |
| `rkvenc_ccu` | No; N/A, software-only, no delay | BALANCED: no runtime-PM acquisitions | None; cores own hardware power |
| `rkvdec0` | Yes, 2000 ms (common probe) | BALANCED, including partial CCU unwind | None |
| `rkvdec1` | Yes, 2000 ms (common probe) | BALANCED, including partial CCU unwind | None |
| `rkvdec_ccu` | Yes, 2000 ms (`mpp_rkvdec2.c:1838–1841`) | BALANCED | None |
| `jpegd` | Yes, 2000 ms (common probe) | Usage refs BALANCED; one enable-lifecycle imbalance at `mpp_jpgdec.c:642` (PM-B02) | Common cleanup on failed IRQ request |
| `rga3_core0` | No → Yes, 2000 ms (PM-A01) | Found one shared leak at `rga_job.c:1093` (PM-B01) → BALANCED | Ownership-based cancel put; autosuspend |
| `rga3_core1` | No → Yes, 2000 ms (PM-A01) | Same PM-B01 → BALANCED | Same shared fixes |
| `rga2_core0` | No → Yes, 2000 ms (PM-A01) | Same PM-B01 → BALANCED | Same shared fixes |

The service and encoder CCU nodes in
`integration/0010-arm64-dts-rk3588-mpp-encoder-nodes.patch:29–39` have neither
registers, clocks nor `power-domains`. Their probes allocate software state.
They are explicit exceptions to “autosuspend every device”, not missing hardware
coverage. All **nine hardware devices** have a configured autosuspend policy
after the fixes. RGA's compile-time `RGA_DISABLE_PM` alternative remains unchanged
and is not defined by the production island build.

## Regression tests and proof limits

The KUnit staging script compiles the byte-preserved RGA power block and complete
`rga_job_run`, `rga_job_next`, scheduler-abort and request-abort functions with
maintained types. It separately compiles the complete JPEG probe and its actual
private device struct. Linux runtime PM runs on registered fixture devices, with
a fake domain callback and clock/register backend. No board is contacted.

- `rga_cancel_after_reset_balances_power_test` reproduces reset → next-job →
  cancel, checks the real `usage_count`, `pd_refcount` and counted clock refs,
  and repeats cancellation to exclude a second release.
- `rga_cancel_pending_preserves_running_power_test` proves cancelling a queued
  request does not put another request's running-job reference.
- Resume, clock and register-error tests check all three admission failure
  boundaries; failed resumes acquire nothing and later failures unwind once.
- `rga_release_uses_autosuspend_test` checks a zero usage count with clocks off
  while the real PM state remains active until the configured delay. It does
  not sleep or claim a measured hardware suspend latency.
- `jpeg_probe_pm_lifetime_test` exercises failed IRQ, successful probe and
  failed common probe. Common hardware setup/teardown is a fixture using the
  real PM enable/disable API; the test proves the JPEG caller invokes cleanup,
  not physical IOMMU or wakeup teardown.
- The staging self-test checks the real RGA probe's delay/use/enable-before-get
  order and rejects deletion mutations of each policy call. This small source
  contract complements, rather than substitutes for, executed ownership tests.

Baseline UML with the new behavioral tests: **84 passed, 3 failed, 87 total**.
The three failures were PM-B01's retained usage/clock ref, PM-B02's enabled PM
after failed IRQ registration, and PM-A01's forced immediate suspension. An
initial test compile lacked `mpp_debug.h`; it was corrected before this measured
RED run and is not counted as a regression reproduction.

These tests do not validate silicon, clock-provider behavior, IRQ concurrency,
real DMA mappings, live platform unbind, or decoder recovery efficacy. The static
ledger and narrow executable regressions are the deliverable, not a new hardware
qualification result. The thermal half and the combined plan checkbox remain
untouched.

### Local verification

Run with a pristine pinned kernel staged in repo-local `.work/linux`:

```sh
python3 tests/kunit/stage_ioctl.py --self-test
python3 tests/kunit/stage_ioctl.py .work/linux
TMPDIR="$PWD/.work/tmp" .work/linux/tools/testing/kunit/kunit.py run \
  --kunitconfig="$PWD/tests/kunit" --build_dir="$PWD/.work/kunit" \
  --jobs=12 --timeout=180
```

Create `.work/tmp` before running UML. The final local run passed **87/87**,
including all eight new cases; no existing test was changed or weakened.
Evidence is retained in gitignored `test-results/runtime-pm/red.log` and
`green.log`. `local-gates.log` records passing shellcheck, all board/DT/tooling
self-tests, UAPI parity, host and arm64 probe builds, module/telemetry contracts,
shim lint, ownership lint, generated-series check and independent parity.
Board harnesses ran only their local `--self-test` modes.

Changed KUnit C/header and Python LSP error diagnostics were clean. Production
driver LSP diagnostics did **not** resolve the corrected compile context after
two attempts (missing RGA include paths and stale module/anonymous-struct flags
in the cached context); no clean production-LSP result is claimed. Target module
linking and sparse remain the authoritative CI gates, not those stale diagnostics.
