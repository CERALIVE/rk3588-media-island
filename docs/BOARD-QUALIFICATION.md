# Board qualification — what real hardware must demonstrate

**Status: one leg attempted on both boards, none ticked.** B8 (IOMMU fault
recovery) has now RUN — on the Rock 5B+ and on the Orange Pi 5+, both at island
`v2026.9.2` on the edge-test kernel — and its transcripts are in the Run log
below. It is recorded, not qualified: neither board earned a tick. Every other
leg (B1–B7, B9, B10) is still unrun, and this document keeps its original
purpose, which is to be a gate written before the evidence rather than a
description of whatever happened.

## The proof boundary

CI proves the island **compiles, lints and passes its unit tests** against the
pinned kernel. That is a real gate and it catches a great deal. It proves nothing
about silicon.

Everything in the list below needs a Rock 5B+ or an Orange Pi 5+ with the island
actually loaded, and each leg is scored from a pasted transcript. Nothing is
ticked from reasoning, from a passing build, or from a command merely completing
without error.

## Standing rules

These are copied in spirit from the sibling kernel repository's qualification
discipline, because the same traps apply:

- **A tick needs a transcript.** No transcript, no tick. A leg with a plausible
  narrative and no pasted output is untested.
- **`N/A` legs are never deleted.** A leg that does not apply to a board records
  why. A silently removed leg is indistinguishable from a forgotten one.
- **An unreachable board is `SKIPPED-unreachable` with its attempt transcript.**
  It is never a PASS, and never an absence.
- **Every run names its package, its kernel build and its board.** A result that
  cannot say which bytes it exercised cannot be reproduced or trusted.
- **A failure is recorded, not retried into silence.** Failed and inconclusive
  outcomes stay in the log with the run that produced them.

## The RAUC precondition — read before any deploy

The island rides inside `linux-image`. A broken island kernel therefore takes the
whole boot with it, and the device's A/B update system will **auto-roll-back** —
carrying the evidence away with it.

So, before any board deploy of an island kernel:

1. The other slot must be confirmed good, with an attempt budget of at least one.
2. The candidate slot's journal must be captured **before any reboot**.

Skipping either turns a diagnosable failure into an unexplained rollback. This is
not a suggestion; it is the difference between a finding and a lost afternoon.

## Qualification legs — B8 attempted on both boards, nothing ticked

| # | Leg | What it must demonstrate | Board scope | Status |
|---|---|---|---|---|
| B1 | Module load | Both island modules load, probe, and bind exactly the nodes [`OWNERSHIP.md`](OWNERSHIP.md) assigns them; no `-EBUSY`, no unbound island node | both | not run |
| B2 | Coexistence | Mainline `rkvdec` and `rockchip-rga` remain loaded and bind nothing the island owns; hantro keeps `vpu121`, `vepu121_0` and `av1d`; `snps_hdmirx` unaffected | both | not run |
| B3 | Encode | H.264 and H.265 hardware encode through RKVENC2, scored against the checked-in PSNR oracle fixture in `tests/board/` | both | not run |
| B4 | Decode | H.264, H.265 and VP9 decode through RKVDEC2, with the decode-truth harness confirming hardware and not a software fallback | both | not run |
| B5 | MJPEG decode | JPGDEC binds `jpegd` and decodes, with autoplug landing on the hardware element | both | not run |
| B6 | RGA blit | `multi_rga` binds RGA3 core0, RGA3 **core1** and RGA2E, and blits on each; core1 is the one mainline currently declines | both | not run |
| B7 | Zero-copy | dma-buf import/export across the capture, convert and encode legs stays zero-copy, verified by the fd-trace and gstmemory harnesses | both | not run |
| B8 | IOMMU fault recovery | An injected fault is masked, recovered and the device reused, rather than wedging or storming the log | both | **RECORDED — not ticked, both boards.** Rock 5B+ ran 16/16 matrix + 5/5 control rows ([RUN-4](#run-4--b8-rock-5b-executed-island-campaign-2026-09-09-utc)); Orange Pi 5+ ran the same 21 rows ([OPi RUN-2](#opi-run-2--b8-orange-pi-5-executed-island-baseline-2026-09-09-utc)). The dedicated idle-window row was attempted on Rock and is INCONCLUSIVE ([RUN-5 → RUN-7](#run-5-to-run-7--b8-rock-5b-idle-window-row-attempted-inconclusive-2026-09-09-utc)). Neither board masked-and-reused across every row, so no tick |
| B9 | Soak | A sustained encode run with no leak in the fd census, no interrupt-rate collapse and no journal errors | both | not run |
| B10 | Rollback | Flipping an island-owned node's `compatible` back returns the block to its mainline driver, proving the one-line reversion | one board | not run |

The harness scripts these legs drive already live in `tests/board/` — they were
written and self-tested against the pre-island baseline, so a post-island run is
directly comparable to a recorded baseline rather than to nothing.

## Run log

Seven entries, all B8. Each appends: date, board, kernel build, island release
tag, per-leg verdict, and a link to the retained raw transcript. RUN-1 through
RUN-3 are Rock admission blockers that never reached silicon; RUN-4 is the Rock
campaign that did; the OPi entry is that board's own executed baseline; RUN-5 to
RUN-7 are the idle-window attempt and its close-out. Nothing here is a tick.

### RUN-1 — B8 Rock 5B+ admission stopped (2026-09-09 UTC)

| Board | Observed kernel / intended candidate | Island release intended | Leg | Verdict | Ledger |
|---|---|---|---|---|---|
| Rock 5B+ | `7.2.0-ceralive-rk3588` / unbooted `linux-image-7.2.0-ceralive-rk3588-test`, image `3333237dbd769401b90d483adf51707831c42c97` | `v2026.9.2` (candidate not installed) | B8 | `SKIPPED(host-harness-admission)` — 0/16 matrix rows and 0/5 control rows executed | [Rock phase-4 admission receipt](https://github.com/CERALIVE/ceralive/blob/docs/media-island-ledger-evidence/docs/media-island/ledger/rock-5b-plus/phase4.md) |

This is an attempted admission, not a completed silicon run. Both drill host
self-tests exited 0, but the prescribed invalid-ioctl builder refused the
retained kernel tree with `tree has fewer than 31 commits above its base`
(exit 2). No historical binary was silently substituted and no validation was
bypassed. The board remained on protected production A, good/2, with B good/3;
final bundle identity, package set and service states matched preflight, and the
final board-wrapper check reported idle (exit 0). No install, reboot, fault,
unit-control or config change occurred. No B8 tick or recovery PASS is earned.

### RUN-2 — B8 Rock 5B+ staging capacity blocked (2026-09-09 UTC)

| Board | Observed kernel / intended candidate | Island release intended | Leg | Verdict | Ledger |
|---|---|---|---|---|---|
| Rock 5B+ | `7.2.0-ceralive-rk3588` / unbooted `linux-image-7.2.0-ceralive-rk3588-test`, image `3333237dbd769401b90d483adf51707831c42c97` | `v2026.9.2` (candidate not installed) | B8 | `SKIPPED(staging-capacity)` — 0/16 matrix rows and 0/5 control rows executed | [Rock phase-4 RUN-2](https://github.com/CERALIVE/ceralive/blob/docs/media-island-ledger-evidence/docs/media-island/ledger/rock-5b-plus/phase4.md#run-2--healthy-board-admission-staging-capacity-blocked-2026-09-09-utc) |

The approved binaries were reused without rebuilding and both host self-tests
printed PASS. Fresh locked preflight confirmed protected production A booted,
activated and good, B inactive/good, and budgets A=3/B=3. The bundle requires
1,240,414,328 bytes; prescribed `/tmp` staging has only 1,073,737,728 available.
No Rock-specific authorization for persistent staging or tmpfs resizing was
present, so nothing was transferred or installed. Final production identity,
six-package set and service states matched preflight; the lock was released and
the final wrapper check was idle, exit 0. No reboot, configuration write, unit
control or fault stimulus occurred. No board-drill exit code, counter delta,
candidate tuple, restoration-drill PASS or B8 tick is claimed.

### RUN-3 — B8 Rock 5B+ RAUC signature refusal (2026-09-09 UTC)

| Board | Observed kernel / intended candidate | Island release intended | Leg | Verdict | Ledger |
|---|---|---|---|---|---|
| Rock 5B+ | `7.2.0-ceralive-rk3588` / unbooted `linux-image-7.2.0-ceralive-rk3588-test`, image `3333237dbd769401b90d483adf51707831c42c97` | `v2026.9.2` (candidate installation rejected) | B8 | `SKIPPED(rauc-signature-verification)` — 0/16 matrix rows and 0/5 control rows executed | [Rock phase-4 RUN-3](https://github.com/CERALIVE/ceralive/blob/docs/media-island-ledger-evidence/docs/media-island/ledger/rock-5b-plus/phase4.md#run-3--authorized-staging-rauc-signature-refusal-2026-09-09-utc) |

Owner-authorized persistent staging resolved RUN-2's capacity blocker. The board
bundle SHA-256 matched `7efb464df727f0b9bc1b718ab9b177049c698f667ce1e4674098e7d4714aff4a`,
but the real updater exited 1: `signature verification failed: Verify error:
unable to get local issuer certificate`. No trust change or reboot followed.
The mandatory failure path restored and compared `update.conf`, removed the
staged bundle and empty directory, and restarted the stopped cerastream unit.
Final locked assertions proved production A booted/activated/good, B good,
budgets 3/3, byte-identical detailed RAUC status, exact receipt packages and
original service states. The final wrapper check returned idle, exit 0; the
lock-holder then exited normally. Both host self-tests exited 0, but no candidate
tuple, fault stimulus, counter delta, recovery-boot proof or B8 tick was earned.

**RUN-3 diagnosis addendum — BLOCKED-EXTERNAL, no campaign retry:** the owner
live-verified that the installed keyring trusts
`CN=CeraLive CI Test Root CA (NON-PRODUCTION)` (SHA-256 prefix
`37:B3:46:08:83:BB:30:CF:...`), while the offered `CN=CeraLive RAUC Signing Leaf`
chains through `CN=CeraLive RAUC Intermediate CA` to `CN=CeraLive RAUC Root CA`
(prefix `B7:FF:3C:7B:...`). These are different trust anchors. Rock's current
RAUC is 1.13; unset `check-purpose=` retains `smime_sign`, which the leaf's
E-mail Protection + Code Signing EKUs already satisfy. The older 1.8 note is
stale, not the cause. Full diagnosis and historical-document distinction are
in the linked RUN-3 ledger. Only authorized image/provisioning owners may choose
between provisioning the production root and re-signing for the currently
trusted CI root (new artifact receipt, still NON-PRODUCTION trust). Neither is
authorized here. Read-only re-confirmation at 05:03:04Z found production A safe,
budgets 3/3, unchanged packages/services, and final idle exit 0. No retry or B8
qualification followed.

### RUN-4 — B8 Rock 5B+ executed island campaign (2026-09-09 UTC)

| Board | Kernel build | Island release | Leg | Verdict | Ledger |
|---|---|---|---|---|---|
| Rock 5B+ | `7.2.0-ceralive-rk3588-test` `#ceralive1+test1`, image `3333237dbd769401b90d483adf51707831c42c97`, `patches_commit 365b2463294019e3d4e2d5718a787c2055f4ab59` | `v2026.9.2` (`1fd357d8a8b83b6f4ed7f7692d761f7b653d44f5`) | B8 | `RECORDED — not qualified`: 16/16 matrix rows and 5/5 control rows executed; matrix 14 SURVIVE / 2 FAIL / 0 GATED, controls 0 PASS / 3 FAIL / 2 GATED | [Rock phase-4 RUN-4](https://github.com/CERALIVE/ceralive/blob/docs/media-island-ledger-evidence/docs/media-island/ledger/rock-5b-plus/phase4.md) |

The first Rock campaign in this series to reach silicon. RUN-3's RAUC
trust-anchor blocker was resolved by a full SD-card re-flash and re-verified here
rather than assumed: the live keyring reads DER SHA-256 `bb0bd0b2…ecb2a6c4`, the
updater reported `Verified detached signature by 'CN = CeraLive CI Test Leaf
Signing (NON-PRODUCTION)'`, and the install into slot B completed. Trust remains
NON-PRODUCTION.

Because the re-flash overwrote the card, the protected receipt recorded in
RUN-1's ledger block no longer describes any bytes on it. PROTECTED-SLOT
PREFLIGHT was re-derived live: `PROD_SLOT` A booted/activated/primary/good
budget 3, install target B good budget 3 and not the protected slot, production
GPT PARTLABELs, the six-package receipt, service states active/inactive/inactive
and `sha256(update.conf)=8dd7382b…1017`. Both slots carry the edge-test kernel
after the re-flash, so every boot assertion keys on the SLOT rather than on
`uname -r`. The `rauc install` step was still run as prescribed, because it is
what produces the bundle-identity receipt a `dd` flash does not create.

Fault-seam behaviour matched the OPi island baseline exactly: every executed
arming row moved its counter by exactly +1, `journal_bad=0` held on all 16 matrix
rows, and the end-of-campaign consumed totals (`delay_consumed 2`,
`hang_task_once_consumed 3`, `inject_iommu_fault_once_consumed 1`,
`fail_reset_once_consumed 1`) are identical to that baseline's, with no `*_once`
knob left armed. `libmpp-4k5994-h265` is SURVIVE here where the OPi baseline
recorded FAIL `reason=stimulus`; both are recorded with their own tuples and no
reconciliation is offered.

**B8 is NOT ticked.** The single kernel report of the whole boot — `BUG: KASAN:
slab-use-after-free in debugfs_atomic_t_get+0x20/0x98`, freed via `unbind_store`
→ `devres_release_all` against the context `rkvenc_probe` allocated with
`devm_kmalloc` — landed inside the `service-attach` control row's own journal
window and armed the harness's fatal stop, gating `ccu-attach` and `irq-request`.
That is the identical signature the OPi island baseline recorded, so Rock is a
second-board reproduction of an already-filed candidate defect rather than a new
finding, and no fix was attempted here.

The board was restored to protected slot A and verified: booted/activated A,
primary A, `good` with budget, the exact six-package receipt, original service
states, `update.conf` byte-identical by `cmp`, the 19-entry seam inventory, all
eight `*_once` knobs at 0 and no persistent staging. No `mark-good` and no
`set-state` was issued. The final wrapper check returned idle, exit 0.

### OPi RUN-2 — B8 Orange Pi 5+ executed island baseline (2026-09-09 UTC)

| Board | Kernel build | Island release | Leg | Verdict | Ledger |
|---|---|---|---|---|---|
| Orange Pi 5+ | `7.2.0-ceralive-rk3588-test` `#ceralive1+test1`, image `5a7748d95d567683e9317bc270ef2683018f81f4`, `patches_commit 365b2463294019e3d4e2d5718a787c2055f4ab59` | `v2026.9.2` (`1fd357d8a8b83b6f4ed7f7692d761f7b653d44f5`) | B8 | `RECORDED — not qualified`: 16/16 matrix rows and 5/5 control rows executed; matrix 13 SURVIVE / 3 FAIL / 0 GATED, controls 0 PASS / 3 FAIL / 2 GATED | [OPi phase-4 RUN-2](https://github.com/CERALIVE/ceralive/blob/docs/media-island-ledger-evidence/docs/media-island/ledger/phase4.md) |

Ran 05:54–06:07 UTC on test slot A, with production slot B protected throughout.
No install was needed: slot A already carried the island `v2026.9.2` edge-test
bundle, so the candidate was activated with a boot-order write plus a reboot, and
the whole sequence ran inside one non-interactive board lock. Summary lines as
emitted: `matrix failures=3 gated=0 baseline_fps=30.400` and
`executor-controls failures=3 gated=2 fatal=service-attach`, both exit 1.

This is the run that FOUND the seam's KASAN slab-use-after-free — `BUG: KASAN:
slab-use-after-free in debugfs_atomic_t_get`, at 06:03:22 UTC, inside the
`service-attach` control row's own journal window, with the pre-activation
journal on protected B clean. Rock's RUN-4 is the cross-board reproduction of
this finding, not a second one. Every executed arming row moved its counter by
exactly +1 and no `*_once` knob was left armed. The board was restored to
protected B and verified; `update.conf` was never modified and `cmp` proved it.

### RUN-5 to RUN-7 — B8 Rock 5B+ idle-window row attempted, INCONCLUSIVE (2026-09-09 UTC)

| Board | Kernel build | Island source | Leg | Verdict | Ledger |
|---|---|---|---|---|---|
| Rock 5B+ | `7.2.0-ceralive-rk3588-test` `#ceralive1+test1`, throwaway candidate image `d3a0e090ba6ce19805c4e2c63e5124486d1549cf`, bundle `20260909T172134Z.raucb` | `d935a810ac2ec225fe48fd9ba42250fe9ba16066` (local candidate, no tag) | B8 idle-window row | `INCONCLUSIVE` — the `idle-iommu-fault` row emitted no verdict; the 16-row matrix regression did NOT run | [Rock phase-4 RUN-5…RUN-7](https://github.com/CERALIVE/ceralive/blob/docs/media-island-ledger-evidence/docs/media-island/ledger/rock-5b-plus/phase4.md) |

RUN-5's first attempt reached the board but its encode stimulus stalled: the
explicit `fault-controls-probe.sh --row idle-iommu-fault` invocation hit its
180-second limit and exited 124 with no row verdict, and all sixteen matrix rows
were recorded `GATED(stopped-after-idle-iommu-fault)`. The board restored to
protected A with `PROTECTED_RECEIPT_CMP=PASS`.

The host diagnosis that followed found a **separate, pre-existing** defect: the
driver rejected the legacy zero-size discovery queries (`HW_SUPPORT`,
`CMD_SUPPORT`) that the shipped `librockchip-mpp1 1.5.0-1` userspace actually
sends, which left the hardware IDs zero and selected a VEPU541 fallback. It was
introduced well before this work and fixed on its own by
`d935a810ac2ec225fe48fd9ba42250fe9ba16066`, with hosted CI run
[34375742881](https://github.com/CERALIVE/rk3588-media-island/actions/runs/34375742881)
green on all 17 jobs. **That fix is confirmed on silicon**: RUN-6's trace reached
`idle_wait`, which proves the `mpph264enc` stimulus launched — precisely what
RUN-5's stall prevented.

RUN-6 then lost contact with the board during the armed six-second idle window at
17:50:01 UTC. The idle SSH invocation returned 255, the campaign's own
restoration could not reach the board, and the scheduled recovery check after the
full 900-second window returned `board 'rock' is unreachable`.

RUN-7 closed it out. The board stayed completely silent — ICMP and ARP — for
approximately 17.5 minutes and **did not recover on its own**; the board owner
physically power-cycled it at the orchestrator's request, which the UART console
confirmed as a genuine cold boot from the full DDR-training sequence. RUN-6's
`protect-next-boot` write held, so the board came back on protected A, and the
full restoration receipt then measured PASS on booted slot, boot order, attempt
budgets, `update.conf` bytes, protected-receipt bytes and staging absence.

**The cause of the unreachability is UNRESOLVED, and this row is therefore
INCONCLUSIVE rather than a failure.** Two candidate explanations survive the
evidence. The candidate boot's kernel journal was retrieved in full and ends
cleanly on routine HDMI-RX polling with zero `KASAN:`/`BUG:`/`Oops`/panic/call-trace
matches, and this image carries no pstore or ramoops backend, so nothing could
have been captured across the reset either. A genuine kernel hang triggered by
the injected idle-window fault would look exactly like this from outside — and so
would the loose ethernet cable the board owner directly reported, which is the
more mundane and more likely explanation. The collected evidence cannot
distinguish them, so neither a hardware defect nor a clean survival may be
claimed. Do not infer an MMIO access, callback path, PM transition or lock
failure from the transport loss.

The next step for this row is a re-run with the wired connection positively
verified and secured, and monitored independently of the SSH path under test.
RUN-4 remains the last executed matrix on this board. The lack of a crash-dump
backend on the edge-test image is a diagnostic-capability gap worth its own
follow-up; it is not evidence that a crash occurred.
