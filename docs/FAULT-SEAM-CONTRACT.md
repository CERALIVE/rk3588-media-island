# Fault-seam contract

The authoritative statement of the island's fault-injection seam: which controls
exist, where each one is injected in the maintained driver, which harness row consumes it, and the
exact vocabulary a ledger cell may carry.

Source line numbers and the initial coverage findings below are historical evidence
at island commit `66d3f4973a9e4957493fb96af1af73ef38e79e78`, not coordinates in today's files.

Path shorthands, all relative to this repository's root:

| shorthand | file |
|---|---|
| `F` | `drivers/video/rockchip/mpp/mpp_rkvenc_test.c` |
| `H` | `drivers/video/rockchip/mpp/mpp_rkvenc_test.h` |
| `V` | `drivers/video/rockchip/mpp/mpp_rkvenc2.c` |
| `C` | `drivers/video/rockchip/mpp/mpp_common.c` |
| `KP` | the sibling `rk3588-kernel-patches` repository |

The MPP seam compiles to nothing when `CONFIG_ROCKCHIP_MPP_CERALIVE_TEST=n`:
`H:45-57` supplies a `static inline` false/zero stub for every entry point, so the
call sites listed below become dead branches the compiler removes.

---

## T1 — MPP controls

Nine one-shot controls plus one selector. Every flag knob is registered by
`mpp_rkvenc_test_add_flag` (`F:19-28`), which creates the knob at mode `0600` and
its `<knob>_consumed` counter at mode `0400` in the same directory. The delay knob
and its counter are registered by hand (`F:46-49`), which is why its counter is
`delay_consumed` and not `delay_task_completion_ms_consumed`. All of them live in
`/sys/kernel/debug/rkvenc-test/` (`F:32`).

| debugfs knob | consumed counter | injected effect + errno | island call site(s) | consumer | targeted? |
|---|---|---|---|---|---|
| `fail_service_attach_once` (`F:36`) | `fail_service_attach_once_consumed` (`F:25-27`) | probe returns `-ENOMEM` right after `platform_set_drvdata`, before any OF match or service attach | `V:3614-3615` (core probe), `V:3689-3690` (single-core probe) | NONE in the matrix; `fault-controls-probe.sh` row `service-attach` (todo 6) | no |
| `fail_ccu_attach_once` (`F:37`) | `fail_ccu_attach_once_consumed` (`F:25-27`) | CCU attach returns `-ENODEV` before the `rockchip,ccu` phandle is parsed | `V:3278-3279` | NONE in the matrix; `fault-controls-probe.sh` row `ccu-attach` (todo 6) | no |
| `fail_irq_request_once` (`F:38`) | `fail_irq_request_once_consumed` (`F:25-27`) | `-EBUSY` substituted **in place of** `devm_request_threaded_irq`, so no handler is ever registered | `V:3644-3649` (core probe, flags `0`), `V:3708-3713` (single-core probe, `IRQF_SHARED`) | NONE in the matrix; `fault-controls-probe.sh` row `irq-request` (todo 6) | no |
| `fail_clock_enable_once` (`F:39`) | `fail_clock_enable_once_consumed` (`F:25-27`) | `rkvenc_clk_on` returns `-EIO` before `mpp_clk_safe_enable` touches any clock | `V:2765-2766` | NONE in the matrix; `fault-controls-probe.sh` row `clock-enable` (todo 6) | no |
| `fail_session_alloc_once` (`F:40`) | `fail_session_alloc_once_consumed` (`F:25-27`) | client-type init returns `-ENOMEM` after the null-session check and before the `kzalloc` of the RKVENC session private | `V:2209-2214` | **NOT-IN-MATRIX** — see T3(i); `fault-controls-probe.sh` row `session-alloc` (todo 6) | no |
| `fail_reset_once` (`F:41`) | `fail_reset_once_consumed` (`F:25-27`) | `reset_ret` forced to `-EIO` **after** the real `hw_ops->reset` has run, so the hardware reset still happens and only its result is falsified | `C:934-937` (generic MPP recovery, not encoder-specific) | matrix row `reset-failure` (`fault-matrix.sh:168-171`) | no |
| `hang_task_once` (`F:42`) | `hang_task_once_consumed` (`F:25-27`) | the START register write is skipped: `mpp_task_run_begin` has already armed the timeout and published the register lease, then the task returns 0 without starting the device | `V:1702` arms the run, `V:1715-1724` consumes and skips START | matrix rows `irq-timeout` and `hardware-hang` (`fault-matrix.sh:162-164`); also armed inside `reset-failure` (`:170`) | **yes** (`F:108-111` → `F:97-106`) |
| `inject_iommu_fault_once` (`F:43`) | `inject_iommu_fault_once_consumed` (`F:25-27`) | calls the device's real `mpp->fault_handler` with a deliberately out-of-range IOVA derived from the task's first mem region (or `io_base + PAGE_SIZE` when there is none) and then raises `reset_request` | `V:1703-1713` | matrix row `iommu-fault` (`fault-matrix.sh:165-167`) | **yes** (`F:113-116` → `F:97-106`) |
| `delay_task_completion_ms` (`F:46-47`) | `delay_consumed` (`F:48-49`) | `msleep(delay_ms)` after `dev_ops->result` and **before** the task is popped from the pending list, widening the teardown race window | `V:2855-2859` | matrix rows `dmabuf-vanishing` (`fault-matrix.sh:151`) and `teardown-active` (`:172`) | no |
| `target_session_pid` (`F:44-45`) | — (selector, no counter) | restricts the two targeted controls to one session PID; `0` means "any session". A successful targeted consume clears it back to `0` | `F:90-106`, read through `mpp_rkvenc_test_target_matches` on the `mpp_task->session->pid` passed at `V:1703` and `V:1715` | written by `targeted_fault` (`fault-matrix.sh:128`) for the `irq-timeout`, `hardware-hang`, `iommu-fault` and `reset-failure` rows | selector |

### Verification of the island call-site column

```
$ grep -n 'mpp_rkvenc_test_' drivers/video/rockchip/mpp/mpp_rkvenc2.c drivers/video/rockchip/mpp/mpp_common.c
drivers/video/rockchip/mpp/mpp_rkvenc2.c:1703:	if (mpp_rkvenc_test_inject_iommu_fault(mpp_task->session->pid)) {
drivers/video/rockchip/mpp/mpp_rkvenc2.c:1715:	if (mpp_rkvenc_test_hang_task(mpp_task->session->pid)) {
drivers/video/rockchip/mpp/mpp_rkvenc2.c:2209:	if (mpp_rkvenc_test_fail_session_alloc())
drivers/video/rockchip/mpp/mpp_rkvenc2.c:2765:	if (mpp_rkvenc_test_fail_clock_enable())
drivers/video/rockchip/mpp/mpp_rkvenc2.c:2857:	delay_ms = mpp_rkvenc_test_completion_delay_ms();
drivers/video/rockchip/mpp/mpp_rkvenc2.c:3278:	if (mpp_rkvenc_test_fail_ccu_attach())
drivers/video/rockchip/mpp/mpp_rkvenc2.c:3614:	if (mpp_rkvenc_test_fail_service_attach())
drivers/video/rockchip/mpp/mpp_rkvenc2.c:3644:	ret = mpp_rkvenc_test_fail_irq_request() ? -EBUSY :
drivers/video/rockchip/mpp/mpp_rkvenc2.c:3689:	if (mpp_rkvenc_test_fail_service_attach())
drivers/video/rockchip/mpp/mpp_rkvenc2.c:3708:	ret = mpp_rkvenc_test_fail_irq_request() ? -EBUSY :
drivers/video/rockchip/mpp/mpp_common.c:936:	if (mpp_rkvenc_test_fail_reset())
```

Eleven call sites for nine controls: `fail_service_attach_once` and
`fail_irq_request_once` each appear twice because RKVENC2 has two probe functions
(the multi-core path and the single-core path), and the delay's consume is a plain
assignment at `V:2857` rather than an `if`. Each cited range in T1 encloses exactly
one of these lines.

### Bind-attribute check (input to `fault-controls-probe.sh`, todo 6)

Three controls — `fail_service_attach_once`, `fail_ccu_attach_once`,
`fail_irq_request_once` — only fire during `probe()`, so proving them on a board
requires unbinding and rebinding the driver.

| fact | value | source |
|---|---|---|
| driver name (`/sys/bus/platform/drivers/<name>`) | `mpp_rkvenc2` | `V:46`, `V:3841` |
| `suppress_bind_attrs` set? | **no** — absent from the `.driver` initializer | `V:3836-3845` |
| `bind-attr` verdict for the three probe-time controls | **yes** — `bind`/`unbind` attributes are present, so the rows are permitted on an `edge-test` kernel | derived from the two rows above |
| device node names to write | the encoder core platform devices, e.g. `fdbd0000.rkvenc-core` and `fdbe0000.rkvenc-core` on RK3588 | `tests/board/README.md` "What the shipped image answered on 2026-09-02" |

The verdict is a host-side source fact, not a board result. `fault-controls-probe.sh`
must still gate each of the three rows on `CONFIG_KASAN=y` and
`CONFIG_PROVE_LOCKING=y` in the live `/proc/config.gz`, and must re-read the actual
device names from the bus at run time rather than hard-coding the two above.

### Session identity

The telemetry session directory is named `<session->pid>-<session->index>`
(`mpp_service.c:376-378`), which is exactly the `sessions/<tid>-*` glob
`targeted_fault` matches on (`fault-matrix.sh:122-123`). The value written to
`target_session_pid` is therefore the same `pid` the targeted controls compare
against at `V:1703` and `V:1715`.

---

## T2 — matrix rows

The 16 MPP rows of `tests/board/fault-matrix.sh` (`:10-13`), in their frozen order.
Their set and order remain frozen. The separately selected RGA extension below
adds no row to this MPP array or its default `--row all` sweep.

Every row is scored by the same `score_row` (`:205-247`), which reads the snapshot
metrics captured by `snapshot()` (`:28-45`): per-core `busy`, `busy_ns`, `tasks`,
`errors`, `resets` (`:33`), plus global `queue_depth` (`:38`), `dmabufs` (`:39`),
`iommu_maps` (`:40`) and every `*consumed` fault counter (`:41-43`). The recovery
assertion (`:213-225`) polls for at most 15 s and then requires, for **every** row:
`queue_depth == 0`, summed `busy == 0`, `dmabufs` back to the idle baseline and
`iommu_maps` back to the idle baseline. The two columns below record only what
differs per row on top of that shared set.

| row | stimulus (`fault-matrix.sh`) | counter asserted (`:230-236`) | reset-delta asserted (`:237-239`) | snapshot metrics the assertions read |
|---|---|---|---|---|
| `invalid-descriptor` | `rkvenc-fault-campaign.sh` against `/dev/mpp_service` (`:138-142`) | none | no | `queue_depth` `:38`, `busy` `:33`, `dmabufs` `:39`, `iommu_maps` `:40` |
| `malformed-ioctls` | `rkvenc-fault-campaign.sh` against `/dev/mpp_service` (`:138-142`) | none | no | `queue_depth` `:38`, `busy` `:33`, `dmabufs` `:39`, `iommu_maps` `:40` |
| `invalid-dimensions` | zero-width NV12 caps into `mpph264enc`, must fail and match `invalid\|not negotiated\|could not link` (`:143-146`) | none | no | `queue_depth` `:38`, `busy` `:33`, `dmabufs` `:39`, `iommu_maps` `:40` |
| `unsupported-format` | `GRAY8` caps into `mpph264enc`, must fail and match `not negotiated\|could not link` (`:147-150`) | none | no | `queue_depth` `:38`, `busy` `:33`, `dmabufs` `:39`, `iommu_maps` `:40` |
| `dmabuf-vanishing` | arm `delay_task_completion_ms=1000`, then SIGKILL the encoder after 100 frames (`:151`) | `delay_consumed` +1 (`:231`) | no | the shared set plus `fault delay_consumed` `:41-43` |
| `sigkill-mid-encode` | SIGKILL the encoder after 100 frames, no knob (`:152`) | none | no | `queue_depth` `:38`, `busy` `:33`, `dmabufs` `:39`, `iommu_maps` `:40` |
| `gstreamer-crash` | SEGV the `cerastream` unit and wait for it to come back; `GATED` if it is not active (`:153-161`) | none | no | `queue_depth` `:38`, `busy` `:33`, `dmabufs` `:39`, `iommu_maps` `:40` |
| `irq-timeout` | `targeted_fault hang_task_once` (`:162-164`) | `hang_task_once_consumed` +1 (`:232`) | **yes**, `resets` delta ≥ 1 (`:238`) | the shared set plus per-core `resets` `:33` and `fault hang_task_once_consumed` `:41-43` |
| `iommu-fault` | `targeted_fault inject_iommu_fault_once` (`:165-167`) | `inject_iommu_fault_once_consumed` +1 (`:233`) | **yes**, `resets` delta ≥ 1 (`:238`) | the shared set plus per-core `resets` `:33` and `fault inject_iommu_fault_once_consumed` `:41-43` |
| `hardware-hang` | `targeted_fault hang_task_once` (`:162-164`) | `hang_task_once_consumed` +1 (`:232`) | **yes**, `resets` delta ≥ 1 (`:238`) | the shared set plus per-core `resets` `:33` and `fault hang_task_once_consumed` `:41-43` |
| `reset-failure` | arm `fail_reset_once=1`, then `targeted_fault hang_task_once` (`:168-171`) | `fail_reset_once_consumed` +1 (`:234`) | **yes**, `resets` delta ≥ 1 (`:238`) | the shared set plus per-core `resets` `:33` and `fault fail_reset_once_consumed` `:41-43`; note `hang_task_once_consumed` also moves but is not asserted for this row |
| `teardown-active` | arm `delay_task_completion_ms=1000`, then SIGTERM the encoder after 100 frames (`:172`) | `delay_consumed` +1 (`:231`) | no | the shared set plus `fault delay_consumed` `:41-43` |
| `concurrent-destruction` | two simultaneous 720p encoders, SIGKILL the pair after 3 s (`:173-180`) | none | no | `queue_depth` `:38`, `busy` `:33`, `dmabufs` `:39`, `iommu_maps` `:40` |
| `rapid-cycles` | 200 sequential one-buffer 320×240 encodes (`:181-183`) | none | no | `queue_depth` `:38`, `busy` `:33`, `dmabufs` `:39`, `iommu_maps` `:40` |
| `concurrent-destroy-loops` | two parallel 50-iteration one-buffer encode loops (`:184-188`) | none | no | `queue_depth` `:38`, `busy` `:33`, `dmabufs` `:39`, `iommu_maps` `:40` |
| `libmpp-4k5994-h265` | five 3840×2160 @ 60000/1001 buffers through `mpph265enc`; classified `accepted-hal-survived` or `typed-einval-hal-survived` (`:189-200`) | none | no | `queue_depth` `:38`, `busy` `:33`, `dmabufs` `:39`, `iommu_maps` `:40` |

Row `--self-test` proof, run inside the island checkout:

```
$ bash -c 'source <(sed -n "10,13p" tests/board/fault-matrix.sh); printf "%s\n" "${ROWS[@]}"'
invalid-descriptor
malformed-ioctls
invalid-dimensions
unsupported-format
dmabuf-vanishing
sigkill-mid-encode
gstreamer-crash
irq-timeout
iommu-fault
hardware-hang
reset-failure
teardown-active
concurrent-destruction
rapid-cycles
concurrent-destroy-loops
libmpp-4k5994-h265
```

Four of the nine controls are consumed by the matrix: `hang_task_once`,
`inject_iommu_fault_once`, `fail_reset_once` and `delay_task_completion_ms`, plus
the `target_session_pid` selector. The other five are not.

---

## T3 — findings

**(i) The matrix never consumes `fail_session_alloc_once`.**
`rkvenc-invalid-ioctl`'s `--all-malformed` sweep walks its expectation table and
fails any row that was never exercised, but it explicitly excludes one name:

```
548:			if (!strcmp(expectations[c].name, "session-allocation-failure"))
549:				continue;	/* has its own invocation */
```

The skip itself is `KP/tests/rkvenc-invalid-ioctl.c:548-549`, inside the
never-exercised sweep at `KP/tests/rkvenc-invalid-ioctl.c:545-552`. The row exists in the expectation table
with errno `ENOMEM` (`tests/expected-errno.tsv:30`) and is reachable only through
`--case session-allocation-failure`. Since the matrix's `invalid-descriptor` and
`malformed-ioctls` rows drive the campaign script rather than that single case, the
knob is never armed on the matrix path. The committed Orange Pi rerun fixture agrees:

```
35: fault fail_session_alloc_once_consumed 0
```

(`tests/fixtures/reliability/orange-pi-5-plus/malformed-ioctls-rerun/malformed-ioctls.after:35`.)

The correct ledger literal for this control's matrix cell is therefore
`NOT-IN-MATRIX`, not `PASS` and not `FAIL`. Its proof belongs to
`fault-controls-probe.sh`'s `session-alloc` row.

**(ii) Five controls have never been board-proven on the island.**
`fail_service_attach_once`, `fail_ccu_attach_once`, `fail_irq_request_once`,
`fail_clock_enable_once` and `fail_session_alloc_once` have no matrix row, so no
board run has ever observed any of them fire on island silicon. The historical
proof for the equivalent knobs was taken on the retired standalone rkvenc driver
via `KP/tests/rkvenc-fault-qa.sh` and its `qa_arm` convention, which the island does
not run. The control-proof drill closes this island coverage gap.

The only automated evidence these five have today is host-side: intent `0013`
(`docs/FAULT-CAMPAIGN.md:21`) exercises the production atomic consume helpers, not
the driver call sites, and `docs/FAULT-CAMPAIGN.md:155` records that the intent
started from a model of the imported read-only flag behaviour. A helper test is not
silicon validation.

**(iii) `fault-matrix.sh --self-test` only counts rows.**
`self_test` (`:259-265`) asserts exactly two things: that `${#ROWS[@]}` is 16, and
that no row name contains `rga`. It scores no fixture, exercises no `score_row`
assertion and reads no snapshot. A green `--self-test` is evidence that the row
registry is intact and nothing more; it is never board evidence.

This is a historical finding, now superseded: the current self-test scores MPP
captures and their mutations, exercises fail-closed journal handling, and checks
the separately registered RGA rows with synthetic scoring and stimulus fixtures.
None of these host checks is board evidence.

---

## T4 — GAP vocabulary

These are the only literals a fault ledger cell may carry. A cell that needs
something else is a cell whose situation has not been classified yet, and the fix is
to classify it, not to invent a new spelling.

| literal | means |
|---|---|
| `SURVIVE` | the actual pass literal emitted by `fault-matrix.sh` and the idle-window probe: the row ran on the named board and every applicable row assertion held; any unavailable metric remains explicitly labelled as a gap |
| `PASS` | the equivalent pass literal emitted by the five-control probe: the row ran on the named board and every applicable row assertion held |
| `PASS(gaps: <metric,…>)` | the row ran and every assertion that could be evaluated held, but the listed metrics were unavailable on this driver profile and were therefore not asserted |
| `FAIL(<reason>)` | the row ran and an assertion did not hold; `<reason>` names the assertion, e.g. `FAIL(reset-delta)` |
| `GATED(<reason>)` | the row could not run because a precondition was unmet; exit `77`, and **never** a pass |
| `INCONCLUSIVE` | terminal state for an attempted row whose stimulus outcome cannot be determined from the available evidence; neither a pass nor proof of a kernel failure |
| `GAP:no-consumer-row` | the control is implemented but no harness row consumes it on this profile |
| `GAP:no-<metric>-counter` | the profile does not expose the counter or metric the assertion needs, e.g. `GAP:no-resets-counter` |
| `GAP:not-implemented` | the control does not exist on this driver profile at all |
| `GAP:lockdep-disabled-at-admission` | lockdep was already disabled when the drill checked admission, so the row could not run with the required locking diagnostics |
| `GAP:uapi-or-userspace` | a UAPI or userspace mismatch prevented the row from exercising the intended stimulus; the available evidence does not distinguish those causes |
| `DID-NOT-BOOT (<journal excerpt>)` | the candidate kernel did not reach a usable state; the excerpt is pasted verbatim from the pre-reboot or recovered journal |
| `NOT-IN-MATRIX` | the control is real and proven elsewhere, but `fault-matrix.sh` structurally never arms it — see T3(i) |
| `SKIPPED(<reason>)` | the work behind the cell was deliberately not undertaken, with the gating condition named |

Two rules ride with the vocabulary. A `77` is never counted as a pass, and a
self-test result is never written into a board cell.

Raw harness output spells `FAIL(<reason>)` and `GATED(<reason>)` as `verdict=FAIL`
or `verdict=GATED` with a separate `reason=<reason>` field. A ledger may preserve
that spelling, with the reason in the same cell or accompanying evidence; it is
the same classified verdict, not a reason-free failure or gate.

The matrix emits one row verdict **after** cleanup and final journal validation.
Its journal reasons use the existing `FAIL(<reason>)` vocabulary:

- `FAIL(journal-capture)` — a journal capture command failed, including partial
  output. The journal window is not proven complete.
- `FAIL(journal-scan)` — the journal scanner errored (grep status other than
  `0`/match or `1`/no-match). Empty output is not evidence of a clean scan.
- `FAIL(journal-fatal)` — the final scan successfully detected a fatal signature.
- `FAIL(journal)` — a bad-journal signature, including a lone warning, failed the
  row without establishing a campaign-fatal report.

Capture and scanner failures set the campaign's `fatal=<row>` marker and gate
later rows with `stopped-after-<row>`, even if the saved text appears clean. This
marker means **stop the campaign**, not proof of a kernel defect. An earlier
capture/scanner failure stays failed even if the final refresh succeeds; its
I/O reason is retained when a later scan finds a fatal report. Only successful
captures and scans with no bad signatures permit `SURVIVE ... journal_bad=0`.
A warning discovered only in the final refresh still fails its row, but does not
by itself set the campaign-fatal marker.

---

## RGA extension — opt-in, not board-qualified

The owner-authorized RGA harness supersedes the former RGA non-goal. It lives in
`drivers/video/rockchip/rga3/rga_test.{c,h}` and is independently controlled by
`CONFIG_ROCKCHIP_RGA_CERALIVE_TEST`, a DEBUG_FS-dependent, default-off boolean
inside the existing MULTI_RGA menu. It selects the debugfs debugger so the reset
writer exists. No production fragment enables it. With the symbol off, all
entry points are inline false/zero/no-op stubs and `rga_test.o` is not linked.

All four flags live under `/sys/kernel/debug/rga-test/`: `0600` to arm/disarm,
`0400` for `<name>_consumed`. Write exactly `1` to arm and `0` to disarm. Other
values never fire. Atomic compare-and-clear selects one consumer and increments
the independent cumulative counter exactly once. Counters last until module
unload; no PID selector or idle work is added. Only one fault should be armed at
a time; if combined, IOMMU takes precedence, then IRQ-timeout, then hang, leaving
the others armed for later jobs. The harness clears all four after each row.

| debugfs knob | consumed counter | injected effect + errno | island call site(s) | consumer | targeted? |
|---|---|---|---|---|---|
| `irq_timeout_once` | `irq_timeout_once_consumed` | skip `set_reg`/START after successful power acquisition; keep timestamps, RUNNING state and recovery epoch so normal timeout/cancel sees missing completion; synchronous timeout is `-EBUSY` | `rga_job.c:rga_job_run`, existing `rga_job_timeout_query_state` / `rga_job_scheduler_timeout_clean` and request cancellation | `fault-matrix.sh --driver island-rga`, `rga-irq-timeout` | no |
| `hang_task_once` | `hang_task_once_consumed` | same no-START mechanism as the MPP hang seam, independently counted; synchronous timeout is `-EBUSY` | `rga_job.c:rga_job_run`, same existing timeout/cancel paths | `rga-hardware-hang` | no |
| `inject_iommu_fault_once` | `inject_iommu_fault_once_consumed` | only a core with an installed IOMMU callback can consume; skip START, publish recovery epoch, call the real fault handler with a synthetic read-fault IOVA, then return its `-EACCES` via pre-run error cleanup | `rga_iommu.c:rga_iommu_test_prepare`, `rga_iommu_test_fault`, `rga_iommu_intr_fault_handler`; `rga_job.c:rga_job_run` / `rga_job_next` | `rga-iommu-fault` | no; private-MMU cores leave it armed |
| `fail_reset_once` | `fail_reset_once_consumed` | **after** `rga_request_scheduler_abort`, return `-EIO` from a valid core's reset write; do not skip recovery or change the void hardware reset API | `rga_debugger.c:rga_reset_write` through `/sys/kernel/debug/rkrga/reset` (also shared with procfs) | `rga-reset-failure` | no; invalid input/unmatched core leaves it armed |

IRQ-timeout and hardware-hang intentionally share the no-START mechanism, just
as the MPP rows do: neither proves a lost interrupt in the IRQ controller or an
actual wedged silicon engine. The IOMMU leg proves direct callback/error cleanup,
not provider IRQ delivery or a real page-table walk. No invalid DMA is launched.
The reset leg tests a debug-write result, not a physical reset-controller failure;
the existing abort routine may skip resetting an already-recovered epoch or when
power acquisition fails. Its counter is therefore **not** proof of a real reset.

| row | stimulus | counter asserted | reset-delta asserted | recovery assertions |
|---|---|---|---|---|
| `rga-irq-timeout` | arm timeout, one synchronous probe blit, expect errno 16 | `irq_timeout_once_consumed` +1 | ≥1 | fresh successful blit, queue depth 0, dma-bufs back to baseline, clean journal |
| `rga-iommu-fault` | arm IOMMU fault, one synchronous probe blit, expect errno 13 | `inject_iommu_fault_once_consumed` +1 | ≥1 | same |
| `rga-hardware-hang` | arm hang, one synchronous probe blit, expect errno 16 | `hang_task_once_consumed` +1 | ≥1 | same |
| `rga-reset-failure` | arm reset failure, write a core parsed from reset help, expect EIO | `fail_reset_once_consumed` +1 | no — result-only seam | same |

`--driver island-rga --probe-rga <binary>` runs only these four rows; MPP remains
`--driver island|auto`. The RGA arm requires root, `CERALIVE_BOARD_TEST=1`, KASAN,
PROVE_LOCKING, the RGA test symbol, exact disarmed seam inventory/permissions,
and no existing RGA session. The caller must hold the external board lock and
keep other RGA users stopped: these controls are global, not session-targeted.
A successful baseline blit is required **before** injection; a raw-probe UAPI
refusal gates the row instead of masquerading as an injected error. The probe's
exit zero alone is not success; its `blit_sync` record is checked explicitly.

RGA exposes no instantaneous busy or IOMMU mapping counter, so those fields carry
`GAP:no-busy-counter` and `GAP:no-iommu_maps-counter`, never invented zeroes.
Unlike the MPP campaign, this isolated RGA sweep makes no competing-session FPS
claim. Its final journal is captured after disarm and recovery; any capture,
scan, stimulus or recovery failure stops the sweep. A `77` remains GATED.

The KUnit suite compiles the real controls and byte-preserved run, timeout,
IOMMU and reset-writer functions with hardware/MMIO, resource release and user
copy fixtures. It checks one-shot/rearm/invalid-value/concurrent consumption,
actual debugfs modes and backing atomics, timeout retirement/PM balance, IOMMU
eligibility/error/reset, reset-write errors and config-off stubs. Hardware reset
and abort side effects are not proven by substituted operations. Host tests and
cross-compilation are the proof boundary; **no RGA board validation is claimed**.

## Future extensions (not in this effort)

**A `session-allocation-failure` matrix row.** T3(i) makes the case that the control
is unconsumed by the matrix. Closing that by adding a seventeenth matrix row is
possible in principle, but the row set, order and count are frozen, so it would be a
deliberate future change with its own justification. The chosen alternative is the
`session-alloc` row in `fault-controls-probe.sh`, which reaches the control through
`rkvenc-invalid-ioctl --case session-allocation-failure` and asserts the same errno
the expectation table already records.
