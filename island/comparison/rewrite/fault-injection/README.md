# Rewrite encoder fault controls [EXISTS]

Comparison-only MPP overlay on the pinned upstream snapshot. `port-rewrite.py`
first verifies every upstream driver byte, then applies `hooks.patch` and copies
the two local headers into the disposable kernel's `mpp-rewrite/`. RGA and the
production island driver are untouched. Enable
`CONFIG_ROCKCHIP_MPP_REWRITE_FAULT_INJECTION=y` with `DEBUG_FS`; it defaults off
and works with rewrite MPP built either in or as a module.

## Operator contract

### Optional idle-window control [PARTIAL]

The overlay now also publishes `inject_iommu_fault_idle_ms` (0600),
`inject_iommu_fault_idle_consumed`, `inject_iommu_fault_idle_fired`, and
`inject_iommu_fault_idle_state` (0400). It mirrors the production test seam's
one-shot delayed-work/PM-at-fire contract described in
`docs/FAULT-CAMPAIGN.md`. This tenth control is not a fifth matrix stimulus:
use the explicit `fault-controls-probe.sh --row idle-iommu-fault` experiment.

The new work object is device-owned allocated storage, not a global timer.
Completion preserves a hardware reference for an armed experiment until the
poller can schedule against that exact core; job release drops that reference.
No task or PM reference is held by the delayed work. Enqueue and disabling share
a spinlock; remove, shutdown and system suspend cancel before callback/resource
withdrawal. Initialization follows all fallible probe setup. The worker excludes
clock-on, rejects active work and calls the real registered handler. It records
the PM snapshot without a resume; idle delivery need not schedule recovery.

This supersedes the nine-control count and no-new-lock/work statement below
only for this additional control. The original nine controls and their
intentional differences remain unchanged. The wrapper accepts a fourth QEMU
argument string, defaults to `-smp 2`, and the configuration selects SMP. The
four new KUnit cases mirror production, including the forced-interleaving race;
the ten pre-existing upstream full-suite failures are still not repaired.
No board result or ready-to-deploy image is claimed here.

These controls can fail streams and quarantine cores. Use only a separately
authorized comparison image/campaign, never the production image. They are at
`/sys/kernel/debug/rkvenc-test/`; writable files are root-only `0600`, cumulative
consumption counters are read-only `0400`. Write `1` to arm a flag and `0` to
disarm it. Only exactly `1` fires; repeated writes before consumption are not a
queue. Each successful consumption clears the arm and increments its counter
once, atomically across the two encoder cores. Counters reset on driver reload.

| Control | Actual injection boundary | Consumption counter |
|---|---|---|
| `fail_service_attach_once` | RKVENC2 common probe, immediately after hardware allocation and service assignment; `-ENOMEM`, before any resource acquisition or publication | `fail_service_attach_once_consumed` |
| `fail_ccu_attach_once` | RKVENC2 core with a CCU, before cluster registration; `-ENODEV` through identity unlock, DMA-group unregister and real IOMMU-handler withdrawal | `fail_ccu_attach_once_consumed` |
| `fail_irq_request_once` | RKVENC2 common probe, before the primary IRQ request; `-EBUSY`, never registers the handler or marks it registered | `fail_irq_request_once_consumed` |
| `fail_clock_enable_once` | RKVENC2 power-on, before bulk clock enable; `-EIO` through the existing runtime-PM put, without publishing regs-live/power ownership | `fail_clock_enable_once_consumed` |
| `fail_session_alloc_once` | Validated initial RKVENC `MPP_CMD_INIT_CLIENT_TYPE`, under the session mutex; `-ENOMEM` after user-copy/support/conflicting-init checks, before either session field is committed, unlocking on error; never at `open()` | `fail_session_alloc_once_consumed` |
| `hang_task_once` | Keep the active activation, watchdog and live register lease; omit the encoder START write and return success, allowing normal timeout recovery | `hang_task_once_consumed` |
| `inject_iommu_fault_once` | After lease publication, call the existing software IOMMU handler with the selected core's registered domain and device identity, nominal IOVA `0xfffff000`, read-fault status; normal START still follows | `inject_iommu_fault_once_consumed` |
| `fail_reset_once` | Complete the encoder's real assert/deassert attempt, then force `-EIO` before reset-domain finish; do not bypass the pulse or failed-domain bookkeeping | `fail_reset_once_consumed` |
| `delay_task_completion_ms` | Detach a DONE encoder job under the session mutex, unlock, copy readback, then sleep before dropping the transferred list reference | `delay_consumed` |

The delay is a one-shot positive signed millisecond value, not a persistent
latency setting. Zero/negative values do not sleep or increment the counter.
Like the vendor seam it has no artificial maximum; choose a bounded campaign
value (the matrix uses 1000 ms). The poller retains the job, its imports and its
session during the uninterruptible sleep, without holding a session/spin lock.
Concurrent reset/close cannot reclaim the detached job. A close of the last
userspace fd may itself wait for an in-flight ioctl's file reference.

`target_session_pid` is a selector, **not a tenth injection control**. It matches
the opener's kernel TID saved at `open()`, not a worker's `current`. Zero accepts
any encoder session. Nonmatching sessions leave the arm untouched; a consumed
hang/IOMMU shot clears the matching selector. Reset and delay are global to
encoder work, as in the vendor seam. For discovery,
`rkvenc-test/sessions/<opener-tid>-<session-id>/` exists for each open MPP fd and
is removed on release. Use only one targeted shot at a time. A missing registered
IOMMU leaves its shot armed rather than pretending delivery succeeded.

The IOMMU shot is **software delivery, not invalid DMA or a physical fault IRQ**.
The reset shot is a failed *result*, not a stuck physical reset line. Hardware
recovery, survivor throughput and subsequent core usability are measured outcomes,
not promised by the injector. Five allocation/probe/clock failure controls complete
the nine-control surface. No RGA or malformed-ioctl control is added; malformed
ioctls keep their existing separate userspace-stimulus path.

All five new controls are encoder-scoped; CCU injection additionally requires a
CCU phandle. None consumes on an ineligible device/session. Repeated initialization
of the same client leaves the session-alloc shot armed; conflicting initialization
still returns `-EBUSY`. The checks introduce no lock, work item, session field,
activation reference or register lease. The per-service atomics live for the
service's lifetime, and failed probes use the original devm/identity unwind.
The two seams cannot be enabled together: the overlay header emits a compile-time
error because they would share `/sys/kernel/debug/rkvenc-test`.

### Adopted-base semantic differences (intentional)

The four existing runtime hooks are preserved, not silently corrected:

- Reset is **RKVENC2-only**, whereas production injects in generic MPP recovery.
  The base consumes after reaching the deassert attempt, not after an assert
  failure which already exits through `out_finish`.
- Hang is checked **before** IOMMU here; production checks IOMMU first. Arm one
  targeted shot at a time, never interpret simultaneous arming as equivalent.
- IOMMU uses fixed `0xfffff000`, not production's allocation-derived IOVA. It
  invokes the **real registered handler with the real domain/device identity**;
  START follows and the handler schedules normal recovery. Contrary to the
  inherited contract note, production `mpp_rkvenc2.c:1711` actually passes NULL
  as domain. This overlay deliberately does not copy that argument.
- Delay detaches the DONE job before sleeping; production sleeps before its
  pending-list removal. Here the transferred list reference retains the job,
  imports and session until `rk_mpp_job_put`, with the session mutex released.
- `task_pid_nr(current)` equals production `current->pid`
  (`mpp_common.c:523`), and `%d-%u` matches production session-directory identity
  (`mpp_service.c:376`). Neither is a TGID nor a PID read in a recovery worker.

### Base supersessions

File layout, Kconfig symbol, session-directory convention, existing hooks and
selector `atomic_cmpxchg` clear are unchanged. The two headers are extended
additively. The old Kconfig help's two lines beginning `Four one-shot` become
three lines describing nine. Regeneration replaces patch hunk coordinates and
adds this semantic record, not any frozen source bytes. This README replaces
the old "not a fifth" selector count, "No allocation/probe/clock injection"
claim, and obsolete matrix-adapter paragraph; its existing four control rows,
lifetime explanation, QEMU recipe and full-suite debt remain intact. The staging
tool retains the adopted function/call order and duplicate-application check,
adding three digest checks, five self-test legs and `--no-fault-seam`.
The client-init hunk uses eleven context lines so its validated
`MPP_CMD_INIT_CLIENT_TYPE` boundary is visible in the exported patch; other hunks
use Git's default three lines. Both come from the same frozen-snapshot baseline.

The superseded text is enumerated against the adopted four-control version:

| Base file / lines | Supersession |
|---|---|
| Staged `Kconfig:21` | `Four one-shot debugfs controls for encoder timeout, software IOMMU` becomes the nine-control probe/clock/client-init description; the following fault/reset/completion line is retained |
| `README.md:35` | Selector is "not a fifth" becomes "not a tenth" |
| `README.md:47-49` | "No allocation/probe/clock injection" becomes five added controls, retaining the RGA/malformed-ioctl exclusion |
| `README.md:53-59` | Unimplemented matrix-adapter claim becomes the existing rewrite profile and separate five-control probe drill; the overlap warning at lines 60-64 is retained |
| `README.md:105` | Existing ten-failure baseline gains the explicit `NOT-OURS baseline debt` label |
| `hooks.patch` hunk headers/context | Regenerated from the frozen snapshot; no existing driver hook is removed or reordered |
| `port-rewrite.py` snapshot/copy loops and self-test tail | Factored into `verify_snapshot` / `stage_modules` to test both modes; adopted `stage_fault_overlay` and its duplicate-application refusal are retained |

Both headers have additions only. `run-kunit.sh` and `.kunitconfig` remain
byte-identical to the adopted base. There are no other semantic supersessions.

## Matrix integration boundary

The four matrix controls match `tests/board/fault-matrix.sh --driver rewrite`.
That profile maps the real rewrite telemetry and session directory, preserving
consumption/reset/cleanup/survivor assertions with the explicit
`GAP:no-sessions-summary` on `iommu_maps`. Pass the measured support bitmap via
`--expect-bits`; the default is not a board measurement. The five new controls
belong to `fault-controls-probe.sh`; its `session-alloc` row lets the canonical
`rkvenc-invalid-ioctl --case session-allocation-failure` arm its own knob after
open. No fabricated vendor telemetry aliases are provided here. In
particular, global delay is not targeted to the doomed process, and the existing
100-frame kill trigger does not itself prove overlap with the delayed completion.
The eventual campaign must retain evidence of which session consumed that shot
and whether teardown overlapped it. No board campaign or hardware verdict follows
from these source-level controls.

## Hardware-free validation

Stage into a fresh kernel checkout under this repository's `.work/` using the
normal `scripts/port-rewrite.py KERNEL_TREE UPSTREAM_GIT` command. Its self-test
also proves that the overlay applies to the pinned snapshot and refuses a second
application. Neither command operates on a board.
`pins.env` pins `hooks.patch` and both copied headers; missing independent hunks
fail the digest check even if the remaining patch would apply. Use
`--no-fault-seam` to stage only the original snapshot and providers. The
`scripts/check-fault-seam-parity.sh` gate compares the debugfs and harness name
sets without QEMU; `--ktap-log .work/rewrite-fault-kunit/test.log` additionally
requires the complete passing seam suite and prints the production/rewrite
case-name table. Its committed KTAP fixtures are synthetic parser inputs, not
execution receipts.

From the staged kernel, run both the upstream inline suite and the new suite,
with `REPO` set to the absolute repository checkout path:

```sh
python3 tools/testing/kunit/kunit.py run --arch arm64 \
  --cross_compile aarch64-linux-gnu- \
  --kunitconfig="$REPO/island/comparison/rewrite/fault-injection/.kunitconfig" \
  --build_dir="$REPO/.work/rewrite-fault-kunit" --jobs=12 \
  --make_options=KCFLAGS=-Werror --timeout=180 '*mpp*rewrite*'
```

The configuration enables lockdep. KASAN is explicitly off here: the GCC 16
ARM64 KASAN build exceeds the 2048-byte frame warning in two existing upstream
fixtures (`rk_mpp_hw_take_active_if_kunit` and
`rk_mpp_hw_prepare_active_retry_kunit`); neither warning is suppressed. This
recipe is not KASAN qualification. The existing full comparison-module gate
still uses its edge-test KASAN configuration.

Alternatively, from the repository root use the fail-closed wrapper:

```sh
bash island/comparison/rewrite/fault-injection/run-kunit.sh \
  .work/linux-rewrite-fault .work/rewrite-fault-kunit
```

An optional third argument `rk-mpp-rewrite-fault` selects only the new cases.
The wrapper also scans the raw kernel log: KUnit can report a passing assertion
count while lockdep has emitted a warning. A passing KTAP count alone is not a
clean run.

**Full-suite blocker, reproduced on the unmodified snapshot:** in the local
ARM64 QEMU/lockdep configuration, upstream `rk_mpp_rewrite` reports 99 passed,
10 failed (109 total): **NOT-OURS baseline debt**. The ten failing case names match with and without the
overlay; they include NULL-dereference faults in incomplete register/batch/close
fixtures, link-table and generation assertions, and cleanup-reference failures.
No case is skipped, weakened or repaired by this overlay. Thus the full command
above currently returns failure: the new-control results are not full-suite
clearance, and that baseline debt must be resolved separately.

The new `rk-mpp-rewrite-fault` suite exercises the actual publish-and-START
function against RAM-backed MMIO, checks watchdog/lease preservation and target
misses, delivers into the real IOMMU callback and observes scheduled work plus
the activation generation, reuses the upstream reset backend trace to prove
both pulse edges precede the forced error, and re-enters the real session abort
and FD-release paths at a retained poll completion. Only the recovery worker and
sleep are replaced by fixture-local observers: no live service state is changed.
It proves injection and reference accounting, not real DMA teardown or recovery
of RK3588 hardware. Existing generation/recovery fixtures remain enabled.

The extended suite has nine one-shot control cases, five selector cases and the
inherited lease/target case. Clock injection executes the real power-on/error
unwind with a reset-backend trace, real runtime PM and a zero-clock fixture.
Service/CCU/IRQ/client-init cases execute the exact errno helpers used by the
hooks with ineligible, armed and spent shots; they do **not** execute OF probe,
devm rollback or a userspace `get_user`. Those boundaries remain board-gated.
The selector-concurrent-write case replays the atomic steps deterministically,
just like production's test; it is not a live-race test. The header stays one
fixture/suite translation-unit include to preserve the adopted file layout.
