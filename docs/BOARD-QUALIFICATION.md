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

## Qualification legs — none run

| # | Leg | What it must demonstrate | Board scope | Status |
|---|---|---|---|---|
| B1 | Module load | Both island modules load, probe, and bind exactly the nodes [`OWNERSHIP.md`](OWNERSHIP.md) assigns them; no `-EBUSY`, no unbound island node | both | not run |
| B2 | Coexistence | Mainline `rkvdec` and `rockchip-rga` remain loaded and bind nothing the island owns; hantro keeps `vpu121`, `vepu121_0` and `av1d`; `snps_hdmirx` unaffected | both | not run |
| B3 | Encode | H.264 and H.265 hardware encode through RKVENC2, scored against the checked-in PSNR oracle fixture in `tests/board/` | both | not run |
| B4 | Decode | H.264, H.265 and VP9 decode through RKVDEC2, with the decode-truth harness confirming hardware and not a software fallback | both | not run |
| B5 | MJPEG decode | JPGDEC binds `jpegd` and decodes, with autoplug landing on the hardware element | both | not run |
| B6 | RGA blit | `multi_rga` binds RGA3 core0, RGA3 **core1** and RGA2E, and blits on each; core1 is the one mainline currently declines | both | not run |
| B7 | Zero-copy | dma-buf import/export across the capture, convert and encode legs stays zero-copy, verified by the fd-trace and gstmemory harnesses | both | not run |
| B8 | IOMMU fault recovery | An injected fault is masked, recovered and the device reused, rather than wedging or storming the log | both | not run |
| B9 | Soak | A sustained encode run with no leak in the fd census, no interrupt-rate collapse and no journal errors | both | not run |
| B10 | Rollback | Flipping an island-owned node's `compatible` back returns the block to its mainline driver, proving the one-line reversion | one board | not run |

The harness scripts these legs drive already live in `tests/board/` — they were
written and self-tested against the pre-island baseline, so a post-island run is
directly comparable to a recorded baseline rather than to nothing.

## Run log

Empty. Each completed run appends: date, board, kernel build, island release
tag, per-leg verdict, and a link to the retained raw transcript.
