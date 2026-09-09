# Fault-seam contract

The authoritative statement of the island's fault-injection seam: which controls
exist, where each one is injected in the production driver, where its counterpart
belongs in the rewrite comparison snapshot, which harness row consumes it, and the
exact vocabulary a ledger cell may carry.

Every line number in this document is at island commit `66d3f4973a9e4957493fb96af1af73ef38e79e78`.

Path shorthands, all relative to this repository's root:

| shorthand | file |
|---|---|
| `F` | `drivers/video/rockchip/mpp/mpp_rkvenc_test.c` |
| `H` | `drivers/video/rockchip/mpp/mpp_rkvenc_test.h` |
| `V` | `drivers/video/rockchip/mpp/mpp_rkvenc2.c` |
| `C` | `drivers/video/rockchip/mpp/mpp_common.c` |
| `M` | `island/comparison/rewrite/mpp-rewrite/mpp_rewrite.c` (byte-frozen snapshot) |
| `KP` | the sibling `rk3588-kernel-patches` repository |

The whole seam compiles to nothing when `CONFIG_ROCKCHIP_MPP_CERALIVE_TEST=n`:
`H:45-57` supplies a `static inline` false/zero stub for every entry point, so the
call sites listed below become dead branches the compiler removes.

The census, coverage figures and placement reasoning behind this table are not
restated here. They are
`.omo/evidence/media-stack-convergence/task-36-island-t58-build-integration.md:253-368`.

---

## T1 — controls

Nine one-shot controls plus one selector. Every flag knob is registered by
`mpp_rkvenc_test_add_flag` (`F:19-28`), which creates the knob at mode `0600` and
its `<knob>_consumed` counter at mode `0400` in the same directory. The delay knob
and its counter are registered by hand (`F:46-49`), which is why its counter is
`delay_consumed` and not `delay_task_completion_ms_consumed`. All of them live in
`/sys/kernel/debug/rkvenc-test/` (`F:32`).

"Rewrite placement" is the D1' map from the draft
(`.omo/drafts/media-island-fault-injection-parity.md:115`), given against the frozen
snapshot `M`. Where a concurrently-staged base has already applied a hook at a
different staged offset, that offset is named too.

| debugfs knob | consumed counter | injected effect + errno | island call site(s) | rewrite placement (D1') | consumer | targeted? |
|---|---|---|---|---|---|---|
| `fail_service_attach_once` (`F:36`) | `fail_service_attach_once_consumed` (`F:25-27`) | probe returns `-ENOMEM` right after `platform_set_drvdata`, before any OF match or service attach | `V:3614-3615` (core probe), `V:3689-3690` (single-core probe) | `M:24822-24828` after the hardware allocation / static-service assignment; one common probe, not two branches (staged anchor `24848-24854`) | NONE in the matrix; `fault-controls-probe.sh` row `service-attach` (todo 6) | no |
| `fail_ccu_attach_once` (`F:37`) | `fail_ccu_attach_once_consumed` (`F:25-27`) | CCU attach returns `-ENODEV` before the `rockchip,ccu` phandle is parsed | `V:3278-3279` | `M:25026-25028` before successful cluster registration, unwinding through the existing identity-unlock label; topology at `M:3088-3121`; encoder cores with a CCU only (staged anchor `25052`, label `25079`) | NONE in the matrix; `fault-controls-probe.sh` row `ccu-attach` (todo 6) | no |
| `fail_irq_request_once` (`F:38`) | `fail_irq_request_once_consumed` (`F:25-27`) | `-EBUSY` substituted **in place of** `devm_request_threaded_irq`, so no handler is ever registered | `V:3644-3649` (core probe, flags `0`), `V:3708-3713` (single-core probe, `IRQF_SHARED`) | `M:24975-24980`, in place of the request and never after a successful registration (staged anchor `25001-25006`) | NONE in the matrix; `fault-controls-probe.sh` row `irq-request` (todo 6) | no |
| `fail_clock_enable_once` (`F:39`) | `fail_clock_enable_once_consumed` (`F:25-27`) | `rkvenc_clk_on` returns `-EIO` before `mpp_clk_safe_enable` touches any clock | `V:2765-2766` | `M:17575-17587` before the bulk enable, exiting through the PM-put label so the PM unwind is preserved (staged anchor `17582-17594`) | NONE in the matrix; `fault-controls-probe.sh` row `clock-enable` (todo 6) | no |
| `fail_session_alloc_once` (`F:40`) | `fail_session_alloc_once_consumed` (`F:25-27`) | client-type init returns `-ENOMEM` after the null-session check and before the `kzalloc` of the RKVENC session private | `V:2209-2214` | `M:24267-24269`, at the validated initial `MPP_CMD_INIT_CLIENT_TYPE` handling and never at `open()` (staged anchor `23975-23988`) | **NOT-IN-MATRIX** — see T3(i); `fault-controls-probe.sh` row `session-alloc` (todo 6) | no |
| `fail_reset_once` (`F:41`) | `fail_reset_once_consumed` (`F:25-27`) | `reset_ret` forced to `-EIO` **after** the real `hw_ops->reset` has run, so the hardware reset still happens and only its result is falsified | `C:934-937` (generic MPP recovery, not encoder-specific) | `M:17459-17462` after the real deassert and before domain finish (staged anchor `17465`, RKVENC2 cores only — a documented DIFFERENCE from the island's generic placement) | matrix row `reset-failure` (`fault-matrix.sh:168-171`) | no |
| `hang_task_once` (`F:42`) | `hang_task_once_consumed` (`F:25-27`) | the START register write is skipped: `mpp_task_run_begin` has already armed the timeout and published the register lease, then the task returns 0 without starting the device | `V:1702` arms the run, `V:1715-1724` consumes and skips START | `M:21372-21380`, pre-START, keeping the timeout arm and the register lease (staged anchor `21385-21393`) | matrix rows `irq-timeout` and `hardware-hang` (`fault-matrix.sh:162-164`); also armed inside `reset-failure` (`:170`) | **yes** (`F:108-111` → `F:97-106`) |
| `inject_iommu_fault_once` (`F:43`) | `inject_iommu_fault_once_consumed` (`F:25-27`) | calls the device's real `mpp->fault_handler` with a deliberately out-of-range IOVA derived from the task's first mem region (or `io_base + PAGE_SIZE` when there is none) and then raises `reset_request` | `V:1703-1713` | same pre-START region `M:21372-21380`, delivering into the real handler at `M:20859-20907` with the hardware's registered domain and identity — never a NULL domain (staged anchor `21385-21393`) | matrix row `iommu-fault` (`fault-matrix.sh:165-167`) | **yes** (`F:113-116` → `F:97-106`) |
| `delay_task_completion_ms` (`F:46-47`) | `delay_consumed` (`F:48-49`) | `msleep(delay_ms)` after `dev_ops->result` and **before** the task is popped from the pending list, widening the teardown race window | `V:2855-2859` | `M:23485-23494`, outside the session and spin locks, with a retained job reference (staged anchor `23514`) | matrix rows `dmabuf-vanishing` (`fault-matrix.sh:151`) and `teardown-active` (`:172`) | no |
| `target_session_pid` (`F:44-45`) | — (selector, no counter) | restricts the two targeted controls to one session PID; `0` means "any session". A successful targeted consume clears it back to `0` | `F:90-106`, read through `mpp_rkvenc_test_target_matches` on the `mpp_task->session->pid` passed at `V:1703` and `V:1715` | per-service `struct rk_mpp_fault_controls` at `M:1103`, session fields at `M:1210` and `M:24295-24297`, registered at `M:25456`; the base clears the selector with `cmpxchg` rather than `atomic_set` | written by `targeted_fault` (`fault-matrix.sh:128`) for the `irq-timeout`, `hardware-hang`, `iommu-fault` and `reset-failure` rows | selector |

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
against at `V:1703` and `V:1715`. Any rewrite seam must reproduce that identity or
the selector silently never matches.

---

## T2 — matrix rows

The 16 rows of `tests/board/fault-matrix.sh` (`:10-13`), in their frozen order. The
set, the order and the `--self-test` count are all frozen; no row may be added,
removed or reordered.

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
not run. This is symmetric: the gap belongs to the island as much as to the rewrite,
which is why the control-proof drill is worth building for both profiles rather than
only for the comparison.

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

---

## Future extensions (not in this effort)

**An RGA fault seam.** `multi_rga` has no fault controls and gains none here. If one
is ever built, the placements identified during the census are
`island/comparison/rewrite/rga-rewrite/rga_rewrite.c:7353-7439` and `:7278-7319`
for the job submission and scheduling boundaries, and `:25119-25201` and
`:25110-25116` for the probe and initialisation boundaries. No RGA row may be added
to `fault-matrix.sh`; its `--self-test` asserts that no row name contains `rga`
(`fault-matrix.sh:263`) precisely so that this stays true by accident-proof
construction.

**A `session-allocation-failure` matrix row.** T3(i) makes the case that the control
is unconsumed by the matrix. Closing that by adding a seventeenth matrix row is
possible in principle, but the row set, order and count are frozen, so it would be a
deliberate future change with its own justification. The chosen alternative is the
`session-alloc` row in `fault-controls-probe.sh`, which reaches the control through
`rkvenc-invalid-ioctl --case session-allocation-failure` and asserts the same errno
the expectation table already records.
