# Provenance — where every line of this repository's driver source came from

**Status: import in progress.** The donor snapshot and the complete 97-member
manifest replay are committed. The equality proof below freezes the 6.18
checkpoint before any CeraLive 7.2 adaptation begins; the per-file tables are
filled after that adaptation so they describe the maintained result rather than
an intermediate tree.

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

## 6.18 manifest-replay equality checkpoint

The replay used the 97 commits in
`yisding/linux-rock5b@e7ff978398825b63ddcb13e0572d77564034c1e2` as the
reference tree and selected paths only through
[`IMPORT-MANIFEST.tsv`](IMPORT-MANIFEST.tsv). No patch mailbox was applied in
this repository. `fwport-0001` was materialized as the donor-to-post-0001
delta, and every later member advanced only the `SOURCE` paths named for that
member. The three temporary 6.18-context integration patches accumulated the
`INTEGRATION` paths in the same member order.

The manifest census at the pinned patch-record object was:

```text
$ python3 scripts/import-manifest.py --patch-dir <pinned-forward-port-rk3588>
OK: 81 unique diff path(s) across 97 members; classes=DROP,INTEGRATION,SOURCE; none unclassified.

SOURCE paths:       57
INTEGRATION paths:  10
DROP paths:         14
```

Before starting the 7.2 rebase, the integration patches were applied to a
fresh detached `Linux 6.18@7d0a66e4bb908` worktree and the island `SOURCE`
paths were overlaid. Every manifest-selected `SOURCE` and `INTEGRATION` path
was then byte-compared with the realized tip:

```text
Checking patch drivers/video/Kconfig...
Checking patch drivers/video/Makefile...
Checking patch drivers/video/rockchip/Kconfig...
Checking patch drivers/video/rockchip/Makefile...
Applied patch drivers/video/Kconfig cleanly.
Applied patch drivers/video/Makefile cleanly.
Applied patch drivers/video/rockchip/Kconfig cleanly.
Applied patch drivers/video/rockchip/Makefile cleanly.
Checking patch drivers/iommu/rockchip-iommu.c...
Checking patch include/soc/rockchip/rockchip_iommu.h...
Applied patch drivers/iommu/rockchip-iommu.c cleanly.
Applied patch include/soc/rockchip/rockchip_iommu.h cleanly.
Checking patch drivers/iommu/dma-iommu.c...
Checking patch include/linux/iommu.h...
Applied patch drivers/iommu/dma-iommu.c cleanly.
Applied patch include/linux/iommu.h cleanly.
step2-equality=PASS compared=67 source+integration paths
```

Commit provenance was checked independently across the replay range:

```text
b-series-provenance=PASS commits=97 order=0001..0097 origins=97
b-series-source-parity=PASS manifest_source_paths=57 donor_only_retained=9
```

The complete donor import deliberately retains nine clients that the maintained
series never touched: `mpp_jpgdec.c`, `mpp_jpgenc.c`, `mpp_rkvdec.c`,
`mpp_rkvenc.c`, `mpp_vdpp.c`, `mpp_vdpu1.c`, `mpp_vdpu2.c`, `mpp_vepu1.c`,
and `mpp_vepu2.c`. `mpp_jpgdec.c` is ported for the selected JPGDEC client in
the CeraLive 7.2 commits. The other eight remain source-complete but are made
unselectable with `depends on BROKEN`; retaining them is not a claim that they
compile or own silicon.

The first 7.2 compile corrected one STEP-0 classification before the rebase
continued. `drivers/iommu/iova.c` and `include/linux/iova.h` were initially
marked `DROP:IEP2-only`, but `mpp_iommu_reserve_iova()` is also called by the
selected RKVENC2 and RKVDEC2 RCB-SRAM paths. Without the `0089` exclusive
reservation helper, the MPP core fails to compile and, more importantly, plain
`reserve_iova()` would not prove ownership before teardown. Both paths are now
`INTEGRATION`, `integration/0003` carries the narrow helper, and the equality
check above was rerun over the corrected 67-path set.

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
