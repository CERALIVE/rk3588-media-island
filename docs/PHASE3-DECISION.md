# Phase-3 decision — dual-core, fault model, base verdict (reversal gate G1)

Date: 2026-09-03
Scope: plan todo 18, covering Phase 3 (todos 1–18) only
Boards in evidence: Orange Pi 5+ (`192.168.78.151`). Rock 5B+ (`192.168.78.132`) is
BLOCKED-ON-OPERATOR throughout and is not counted as a pass or a failure anywhere below.

This memo decides one question: did the vendor-forward-port ("yisding") base survive
Phase 3's measured proofs, or must the project abandon it for a hardened-core
reimplementation? The gate's own definition is the one applied here: **FLIP requires that
a proof failed and could not be fixed within Phase 3.** A defect found by a Phase-3 drill
and fixed inside Phase 3 is the gate working, not the gate firing.

The three evidence ledgers are read-only inputs to this memo:

| Ledger | Produced by | Covers |
|---|---|---|
| `phase2.md` | todo 14 | MPP board gate: cold boot, UAPI, encode, decode |
| `phase3.md` | todo 16 | dual-RKVENC2 concurrency matrix, DCHS, starvation probe |
| `phase4.md` | todo 17 | reliability and recovery fault matrix under KASAN + lockdep |

Those three ledgers are effort evidence records held outside this repository. They are
cited here by file name and by row, never by a relative path, because nothing tracked in
this repository may reference a path above its own checkout root. The raw board fixtures
they point at ARE tracked here, under `tests/fixtures/reliability/` and
`tests/fixtures/telemetry/`.

---

## 1. Evidence per §31 item

Each row cites the ledger file and the specific row or section it comes from.

### §31.2 — dual RKVENC2 utilization confirmed

**PASS (multi-process), with one recorded single-process limitation.**

`phase3.md` Matrix rows 1–3 and the `## §31.2 dual-core transcript` section. Scenario 1
(2×4K30 H.265, two processes) measured per-core busy shares of 44.03% and 43.09% with
GIC-105/GIC-109 IRQ deltas of 3709 and 3626, and both sessions held 29.98/29.99 fps
against a 30 fps target. Scenario 2 (4×1080p60 H.264) measured 43.24%/43.19% with IRQ
deltas 14359/14305 and all four sessions at 59.97–59.99 fps. Scenario 3 (mixed 4K60 H.265
+ 2×1080p60 H.264) measured 54.56%/76.43%. All three carry the verdict
**DUAL-CORE-CONFIRMED**: both cores above the 30% busy threshold, scenarios 1 and 2 above
95% of every target frame rate, journal errors 0.

The recorded limitation is `phase3.md` Matrix row 4, **FAIL — ONE-PROCESS-UNBALANCED**:
two 4K30 H.265 sessions inside a *single* process measured 29.96 and 16.48 fps with core
shares 46.69%/21.32%. The ledger explicitly refuses to average this into the passing
result, and this memo keeps that separation. §31.2 as written asks for dual-core
utilization, and it is confirmed; the single-process imbalance is a scheduling-quality
finding carried forward, not a failure of the dual-core claim. See Q4 below for why it
does not fire the gate.

### §31.5 — automatic hardware scheduling confirmed

**PASS.**

`phase3.md` `## §31.5 DCHS and starvation transcript`, plus Matrix rows 5 and 6. With one
4K H.265 session, `auto_tile=0` selected core 0 only (5725 tasks, 70.59% busy, IRQ
5725/0); `auto_tile=1` produced exactly paired per-core work (9112/9112 tasks, 56.66% and
59.87% busy, IRQ 9112/9112). Verdict **DCHS-SPLITS-FRAMES yes** — the hardware's own
frame-splitting scheduler is real and is what places work, not a userspace hand-assignment.

Row 6's starvation probe measured the low-rate 1080p30 session's queue-to-core latency at
p50 62 µs and p99 77 µs across 3610 samples, with `over_2_frame_periods=0`, against a
two-frame limit of 66,666.667 µs. Verdict **FAIR**, **G2-NOT-FIRED**.

### §31.11 — concurrent pipelines stable

**PASS.**

`phase3.md` Matrix rows 1–3: two, four, and three concurrent sessions respectively, each
sustaining target fps with single-digit total drops (2/0; 3/2/0/1; 2/2/1), `queue_depth
max = 1`, and `Journal errors = 0` on every row. Reinforced by `phase4.md` Matrix rows 13
(`concurrent-destruction`) and 15 (`concurrent-destroy-loops`, 2 × 50 loops), both
**PASS — SURVIVE** with the healthy session's throughput intact.

### §31.12 — graceful process death

**PASS.**

`phase4.md` Matrix row 6 (`sigkill-mid-encode`, **PASS — SURVIVE**, 30.2 → 30.4 fps) and
row 7 (`gstreamer-crash`, **PASS — SURVIVE**, service recovered, 30.2 → 30.2 fps). Row 13
(`concurrent-destruction`) covers two processes destroying sessions concurrently. Per the
ledger's closing paragraph in `## Matrix`, every final row ended with `busy=0`,
`queue_depth=0`, and dma-buf and IOMMU-map counts restored to idle baseline — so a killed
process leaves no residue behind on the shared service.

### §31.13 — graceful pipeline restart

**PASS.**

`phase4.md` Matrix row 12 (`teardown-active` — teardown during an active encode,
**PASS — SURVIVE**, delay consumed, 30.2 → 30.0 fps), row 14 (`rapid-cycles`, 200
open/encode/close cycles, **PASS — SURVIVE**, 30.2 → 30.2 fps), and row 15
(`concurrent-destroy-loops`). Restart after each row is proved by the same
counters-return-to-baseline assertion the ledger applies to every row.

### §31.14 — encoder error recovery

**PASS.**

`phase4.md` Matrix rows 8–11 are the recovery core: `irq-timeout` (reset delta 3),
`iommu-fault` (reset delta 1), `hardware-hang` (reset delta 2), `reset-failure` (reset
delta 1) — each **PASS — SURVIVE** at 30.2 → 30.2 fps for the concurrent healthy session.
The non-zero reset deltas matter: they prove the injected fault actually fired and the
driver actually reset the core, rather than the row passing because nothing happened.
Rows 1–5 cover the input-validation half (`invalid-descriptor`, `malformed-ioctls`,
`invalid-dimensions`, `unsupported-format`, `dmabuf-vanishing`), all **PASS — SURVIVE**.
Row 16 (`libmpp-4k5994-h265`) is the known libmpp SEGV case and is **PASS — SURVIVE**:
the HAL accepted five frames rather than crashing.

### §31.16 — no KASAN findings

**PASS for the matrix that ran.**

`phase4.md` header: the debug kernel carries `CONFIG_KASAN=y`, `CONFIG_PROVE_LOCKING=y`
and `CONFIG_ROCKCHIP_MPP_CERALIVE_TEST=y`, and all 16 registered MPP rows passed their
own journal criteria with `journal_bad=0`. `phase2.md` `### Initial module activation and
probe result — SUPERSEDED` records that the *fixed* cold boot journal contains the full
successful MPP probe sequence and no `WARNING:`, `__setup_irq`, or `cut here` entry.

Honest scope: this covers the fault matrix and the boot path on Orange Pi 5+. Long-run
soaks (§31.19) are a later wave and are not claimed here.

### §31.17 — no serious lockdep findings

**PASS for the matrix that ran.**

`phase4.md` header (`CONFIG_PROVE_LOCKING=y`) and the closing assertion of `## Matrix`:
every final row ended with `journal_bad=0` and **lockdep still enabled**. That last clause
is the load-bearing one — lockdep disables itself on its first report, so "still enabled
at the end" is the assertion that no report was emitted during any row.

### §31.18 — no persistent IOMMU mappings

**PASS.**

`phase4.md` `## Matrix` closing paragraph: every final row ended with dma-buf and
IOMMU-map counts restored to its idle baseline. Row 9 (`iommu-fault`) is the pointed case
— a deliberately out-of-window IOVA with the guardrail disabled, which reset the core
(delta 1) and still returned the mapping count to baseline.

---

## 2. §33 questions Q2 through Q7

### Q2 — do we use the candidate's scheduler?

Yes, and it is measured rather than assumed. `phase3.md` Matrix rows 1–3 show the island's
own core-selection path distributing work across both RKVENC2 cores without any userspace
placement: the `selected_core=0 tasks=3709 / selected_core=1 tasks=3626` lines in the
`§31.2 dual-core transcript` are the driver's selection counters, and they agree with the
independent GIC-105/GIC-109 interrupt deltas measured on the same window. Two independent
counters agreeing is what makes this an answer rather than a self-report. The verdict is
keep the candidate's scheduler.

### Q3 — is it genuinely dual-core?

Yes for separate processes, with a named single-process exception. The evidence is the
same `phase3.md` rows 1–3, and its strength is that per-core busy shares (44.03%/43.09%),
per-core IRQ deltas (3709/3626) and driver selection counts are three views of one run
that agree. The exception is `phase3.md` Matrix row 4, where two sessions inside one
process split 46.69%/21.32% and 29.96/16.48 fps. So "genuinely dual-core" is true of the
silicon and of the scheduler; what row 4 shows is that a single process does not
*saturate* both cores fairly. CeraLive's shipping shape is one encode session per stream
process, so row 4 is off the production path today — but it is recorded as an open
scheduling-quality item rather than closed.

### Q4 — is there unnecessary serialization?

None found at the queue seam, and the one asymmetry found is measured rather than
inferred. `phase3.md` Matrix rows 1–3 and 5–6 all report `queue_depth max` of 1 (2 in the
tiled `auto_tile=1` leg, which is expected: a tiled frame is two hardware tasks), so work
is not piling up behind a lock. `phase3.md` row 6's starvation probe puts the p99
queue-to-core latency at 77 µs against a 66,666.667 µs two-frame budget — three orders of
magnitude of headroom, `over_2_frame_periods=0` and `idle_wait_over_2_frame_periods=0`.
`phase4.md` adds the lockdep half: `CONFIG_PROVE_LOCKING=y` across all 16 rows with
lockdep still enabled at the end, so no lock-order or held-lock defect was reported under
fault injection.

**This answer is partial by design.** The §33 table answers Q4 from todos 16 **and 39**,
and todo 39 has not run. Row 4's one-process imbalance is exactly the kind of finding
todo 39's deeper lockdep and starvation probes exist to explain. Phase 3 proves there is
no serialization defect at the concurrency levels and shapes measured; it does not close
Q4.

### Q5 — is load accounting correct?

There is no load accounting to be correct — in either driver. The scheduler picks the
first idle core, and the §33 table records that as a known property rather than a defect
to find. Todo 16's job was to measure whether that design starves a low-rate session
sharing the hardware with a saturating one, and `phase3.md` Matrix row 6 answers it: with
a 4K60 H.265 session holding core 0 at 87.79% busy, the 1080p30 H.264 session held 29.99
fps with a p99 queue-to-core latency of 77 µs. Verdict **FAIR**, gate **G2-NOT-FIRED**, so
no owner question is raised. The honest counterweight is again row 4: first-idle-core is
fair *across processes* and demonstrably uneven *within* one. Accepted for v1 on the
strength of row 6 and the one-session-per-process shipping shape.

### Q6 — is the CCU correct on 7.2?

Yes. `phase3.md` Matrix row 5 and the `§31.5 DCHS and starvation transcript` are the A/B
that proves it: the same single 4K H.265 session run with `auto_tile=0` and `auto_tile=1`.
Off, the CCU handed the whole frame to one core — 5725 tasks, 70.59%/0% busy, IRQ 5725/0.
On, it split every frame and produced *exactly* paired counts on both cores — 9112/9112
tasks, 56.66%/59.87% busy, IRQ 9112/9112. Exact pairing, not approximate, is the signature
of a working compute-cluster unit: each frame becomes one hardware task per core. The
ledger also notes the honest consequence — reported frame rate is task count divided by
two in tiled mode — rather than reading the doubled task count as doubled throughput. No
journal errors on either leg.

### Q7 — is error recovery sufficient?

Sufficient for everything Phase 3 registered, and the drill earned that answer by finding
real defects first. `phase4.md` records all 16 registered MPP rows **PASS — SURVIVE** under
KASAN + lockdep + fault injection, each ending with `busy=0`, `queue_depth=0`, dma-buf and
IOMMU counts at idle baseline, and `journal_bad=0`. The recovery-specific rows (8–11) show
non-zero reset deltas, so the driver's reset path is exercised rather than bypassed.

`phase4.md` `## Findings and recovery` is the part that matters most for this gate: the
first complete run passed 13 rows and exposed three real integration gaps — task
construction failures discarded after the final message and collapsed to `ENOMEM`, the
resulting errno miscategorization where an `EINVAL`/`EFAULT` should have surfaced, and an
IOMMU test callback that ran before hardware start and so completed without requesting the
reset a physical translation fault would force. All three were fixed in island commit
`38f5a4c` and all three rows were rerun individually and passed with healthy-session
throughput intact and counters restored.

**This answer is partial by design.** The §33 table answers Q7 from todos 17 **and 38**,
and todo 38 has not run. RGA rows are also correctly absent — the island does not own the
RGA nodes until the todo-19 flip, and `phase4.md` states the script registers no RGA row.
So Q7 is closed for MPP at the Phase-3 fault matrix and remains open for RGA and for
todo 38's deeper campaign.

---

## 3. VERDICT

# KEEP

The yisding forward-port base survives Phase 3. Every §31 item this gate covers has a
passing measured row on a real board: dual-core confirmed on three independent counters
(§31.2), hardware scheduling proved by an exact-pairing DCHS A/B (§31.5), concurrent
pipelines stable with zero journal errors (§31.11), process death, restart and encoder
error recovery all surviving with counters returning to baseline (§31.12/13/14), and no
KASAN, no lockdep and no leaked IOMMU mapping across a 16-row fault matrix run on a debug
kernel built for exactly those three checks (§31.16/17/18).

**Why the three defects do not fire the gate.** The reversal condition is a proof that
failed *and could not be fixed within Phase 3*. Todo 17's first pass found three real
integration defects. All three were fixed in `38f5a4c` and individually re-verified
passing inside Phase 3, on the same board, under the same sanitizers. That is a drill
doing its job. A gate that fired on "a test found a bug" would be a gate that punishes
testing.

**Why row 4 does not fire the gate either.** `phase3.md` Matrix row 4 is a genuine
recorded FAIL — one-process throughput imbalance — and this memo does not soften it. It
does not meet the reversal condition for three reasons, each checkable: §31.2 asks for
dual-core utilization and rows 1–3 confirm it on a stricter reading than row 4 tests; the
fairness gate that *would* have escalated it (G2, starvation) was measured explicitly and
came back FAIR with three orders of magnitude of headroom; and the behaviour is a property
of the first-idle-core policy that §33 Q5 already records as a known, accepted v1
property, not a discovery that invalidates the base. A reimplementation would inherit the
same policy question, so flipping would not fix it.

**What this verdict does NOT claim.** It is scoped to what Phase 3 (todos 1–18) actually
proves, on one board:

- **Rock 5B+ is unproven, not passing.** Every Rock 5B+ row in `phase3.md` is
  **BLOCKED-ON-OPERATOR**; `phase4.md` re-confirms 100% ICMP loss and SSH `No route to
  host`. The board was correctly left untouched.
- **Q4 and Q7 are partial.** Both are answered jointly by later-wave todos 39 and 38
  respectively, which have not run. Phase 3 closes the MPP fault matrix and the
  concurrency seam; it does not close the deeper serialization and recovery campaigns.
- **RGA is entirely out of scope.** The island does not own the RGA nodes until todo 19.
  `phase2.md` records `rga3` correctly unloaded and mainline `rockchip-rga` still owning
  RGA3 core 0 and RGA2; `phase3.md` records `/proc/rkrga/load` as absent rather than
  fabricating it; `phase4.md` registers no RGA row. §31.3, §31.4 and §31.15 are therefore
  untouched by this verdict.
- **Soaks, thermals and regression-versus-current are later.** §31.19, §31.20 and §31.21
  are not claimed.

**Consequences.** Gate **G1 is NOT-FIRED** (recorded in the effort's `G1.md` ledger).
No re-expression of the base as a hardened-core reimplementation is undertaken. Wave 4
(todos 19–27, the RGA flip) is unblocked. Island release 2 — `v2026.9.1`, carrying the
instrumentation from todo 15 and the fault fixes from todo 17 — is authorized to be cut on
the same mechanics as release 1.
