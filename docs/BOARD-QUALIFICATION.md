# Board qualification — what real hardware must demonstrate

**Status: scaffold.** The checklist legs below are named; none has been run.
There is no Run log yet because there has been nothing to run — the driver source
is not imported and no series has been generated. This document is written first
on purpose: a checklist authored after the evidence exists is a description of
whatever happened, not a gate.

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

## Qualification legs

| # | Leg | What it must demonstrate | Board scope | Status |
|---|---|---|---|---|
| B1 | Module load | Both island modules load, probe, and bind exactly the nodes [`OWNERSHIP.md`](OWNERSHIP.md) assigns them; no `-EBUSY`, no unbound island node | both | not run |
| B2 | Coexistence | Mainline `rkvdec` and `rockchip-rga` remain loaded and bind nothing the island owns; hantro keeps `vpu121`, `vepu121_0` and `av1d`; `snps_hdmirx` unaffected | both | not run |
| B3 | Encode | H.264 and H.265 hardware encode through RKVENC2, scored against the checked-in PSNR oracle fixture in `tests/board/` | both | not run |
| B4 | Decode | H.264, H.265 and VP9 decode through RKVDEC2, with the decode-truth harness confirming hardware and not a software fallback | both | not run |
| B5 | MJPEG decode | JPGDEC binds `jpegd` and decodes, with autoplug landing on the hardware element | both | not run |
| B6 | RGA blit | `multi_rga` binds RGA3 core0, RGA3 **core1** and RGA2E, and blits on each; core1 is the one mainline currently declines | both | Orange Pi 5+ PASS; Rock 5B+ blocked |
| B7 | Zero-copy | dma-buf import/export across the capture, convert and encode legs stays zero-copy, verified by the fd-trace and gstmemory harnesses | both | not run |
| B8 | IOMMU fault recovery | An injected fault is masked, recovered and the device reused, rather than wedging or storming the log | both | not run |
| B9 | Soak | A sustained encode run with no leak in the fd census, no interrupt-rate collapse and no journal errors | both | not run |
| B10 | Rollback | Flipping an island-owned node's `compatible` back returns the block to its mainline driver, proving the one-line reversion | one board | not run |

The harness scripts these legs drive already live in `tests/board/` — they were
written and self-tested against the pre-island baseline, so a post-island run is
directly comparable to a recorded baseline rather than to nothing.

## Run log

Each completed run appends: date, board, kernel build, island release tag,
per-leg verdict, and a link to the retained raw transcript.

### 2026-09-04 — B6, Orange Pi 5+

`7.2.0-ceralive-rk3588`, island `v2026.9.2`: all three schedulers probed and
completed 1,000 explicitly targeted scale jobs. The first real 90-degree d5
requests exposed a validation regression: librga represents the destination's
active rectangle in pre-rotation axes while its virtual dimensions describe the
post-rotation buffer. Validation now swaps only a proven quarter-turn
(`rotate_mode=1`, `cosa=0`, `sina=±65536`); the scale marker uses the same low
nibble with different sine/cosine values and must not swap. KUnit passed 56/56,
including both distinctions. After the fix, NV12→NV16 and NV16→NV12 90-degree
cells ran with fallback/dropped/layout-rejection counters at zero and scored
40.80 dB and 45.24 dB respectively. Rock 5B+ remained network-unreachable and
is not inferred from this result.

### Phase-7 encoder hygiene prerequisites

`tests/board/idr-latency.sh` provides a twenty-request engine IPC driver and an
offline MPEG-TS NAL/PTS scorer. Follow the input-pad clock and complete-capture
contract in [`the harness guide`](../tests/board/README.md#forced-idr-measurement).
Run `--self-test` before a board drill; its software recordings are not board
evidence. Python 3.11+ must be available on the engine host for the requester.

Composition requires two selectable video inputs, not merely a registered
`rgacompositor` factory or the `composition` feature token. If UVC is absent,
the synthetic-secondary fallback must actually be accepted by the engine;
an IPC refusal is BLOCKED, not a ten-minute composition result. A hand-built
GStreamer graph does not qualify the engine's session path. The restart leg
requires a kernel built with `CONFIG_ROCKCHIP_MPP_CERALIVE_TEST` and accessible
`/sys/kernel/debug/rkvenc-test` controls. No knob means no injected-fault result;
never substitute a service restart or mock counter for that evidence.

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
