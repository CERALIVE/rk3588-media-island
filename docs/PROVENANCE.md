# Provenance — where every line of this repository's driver source came from

**Status: scaffold.** The audit tables below are empty because no driver source
has been imported yet. This document is written now, ahead of the import, so the
import has a shape to fill rather than a blank page to invent — and so nobody can
later argue about what provenance was supposed to be recorded.

The source import fills every table here in the same change that adds the code.
A file landing in `drivers/video/rockchip/` without its row is a review blocker,
not a follow-up.

## Why this document exists

This repository's core claim is that its driver source is a **traceable
derivative** of two named upstream objects, not an unattributable dump. That
claim is only worth something if a reviewer can take any file here, follow it back
to a specific line of a specific pinned object, and see what changed on the way.
This document is that map. `docs/COMPAT.md` covers the *external symbol* surface;
this covers the *files*.

Both are needed and neither substitutes for the other: a symbol table tells you
what the code calls, and a provenance table tells you where the code came from.

## Pinned upstreams

Named in full, with the reason each is pinned, in
[`REFERENCES.md`](REFERENCES.md). Repeated here only as identifiers:

- donor: `rockchip-linux/kernel@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`
- forward-port record: `yisding/rock-5b-ysp@ca3da04280c48c004e522c15f31862bf88a2d1b9`
- realized series: `yisding/linux-rock5b@e7ff978398825b63ddcb13e0572d77564034c1e2`
- historical comparison only: `armbian/linux-rockchip@fd9f82366e235b8afbdf516765210e97d24dce93`
- mainline baseline: Linux `v7.2@8d3ae59288f1e7d58d76558a6ee96d533bc5019f`

## Per-file import ledger — TO BE FILLED AT IMPORT

One row per file under `drivers/video/rockchip/mpp/`,
`drivers/video/rockchip/rga3/` and `include/uapi/linux/`.

| File | Origin object | Path at origin | Class | Delta | SPDX carried |
|---|---|---|---|---|---|
| *(empty — filled by the source import)* | | | | | |

Column meanings, fixed now so the import cannot quietly redefine them:

- **Origin object** — which pinned SHA above the file came from.
- **Path at origin** — the file's path in that tree, so the copy is checkable.
- **Class** — one of `VERBATIM` (byte-identical to origin), `REBASED` (changed
  only to compile against the mainline baseline), `FIRST-PARTY` (written by
  CeraLive; no origin path), or `ADAPTED` (a behavioural change; requires a
  rationale row below).
- **Delta** — for `REBASED` and `ADAPTED`, a one-line summary of what changed and
  why. `VERBATIM` rows leave this empty; a `VERBATIM` row with a delta is a
  contradiction and fails review.
- **SPDX carried** — the identifier as it appears in the file. Never rewritten;
  see [`../LICENSE.md`](../LICENSE.md).

## Adaptation rationale — TO BE FILLED AT IMPORT

Every `ADAPTED` row above gets a numbered entry here explaining the behavioural
change, what evidence justified it, and what would have to be true to revert it.

| # | File | What changed behaviourally | Evidence | Reversion condition |
|---|---|---|---|---|
| *(empty — filled by the source import)* | | | | |

## Integration patches — TO BE FILLED AT IMPORT

Files in `integration/` patch **mainline** files rather than island-owned ones,
so they carry a different obligation: each must name the mainline file it touches
and the reason the change cannot live inside the island's own directories.

| Patch | Mainline file touched | Why it cannot be island-local |
|---|---|---|
| *(empty — filled by the source import)* | | |

## What this document does NOT claim

Worth stating plainly, because provenance documents attract over-reading:

- It does not claim upstream-mergeability. Nothing here is submitted anywhere, and
  no row should be read as an upstream-submission plan.
- It does not relicense anything. See [`../LICENSE.md`](../LICENSE.md); the MIT
  branch of the inherited MPP expression is never independently asserted.
- It does not reproduce upstream prose or evidence. Yi Ding's analysis is cited by
  URL plus SHA and never copied into this tree.
- It does not certify that a `VERBATIM` file is *correct* on the mainline
  baseline. Correctness is the compile gate's job and the board drills'; this
  document only certifies where the bytes came from.
