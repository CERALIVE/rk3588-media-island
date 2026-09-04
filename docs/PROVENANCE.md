# Provenance — where every line of this repository's driver source came from

**Status: import complete.** The donor snapshot, complete 97-member manifest
replay, 6.18 equality checkpoint, CeraLive 7.2 delta and generated release
series are committed. The ledgers below describe the maintained source now in
the repository.

The import is not complete until every table here is filled. Any future file
landing in `drivers/video/rockchip/` without its row is a review blocker, not a
follow-up.

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
- vendor backlog: `rockchip-linux/kernel@58a65098a6e9b2be6a08bccd45aa861850d7b8c6`
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

## Per-file import ledger

One row per file under `drivers/video/rockchip/mpp/`,
`drivers/video/rockchip/rga3/` and `include/uapi/linux/`.

`donor` and `realized series` below resolve to the full immutable objects in
the pinned-upstreams list above. A file is assigned to the realized series when
one or more of its 97 members changed that path; untouched donor files continue
to name the donor directly.

| File | Origin object | Path at origin | Class | Delta | SPDX carried |
|---|---|---|---|---|---|
| `drivers/video/rockchip/mpp/Kconfig` | realized series | same | ADAPTED | Expose only the supported module/test closure and fail-close every retained client with `BROKEN`. | `GPL-2.0` |
| `drivers/video/rockchip/mpp/Makefile` | realized series | same | ADAPTED | Restore source-complete object mappings; Kconfig remains the sole selectable-client gate. | `GPL-2.0` |
| `drivers/video/rockchip/mpp/compat/linux/rockchip/rockchip_sip.h` | realized series | same | VERBATIM |  | `GPL-2.0` |
| `drivers/video/rockchip/mpp/compat/rockchip_pmu_idle.h` | realized series | same | VERBATIM |  | `GPL-2.0` |
| `drivers/video/rockchip/mpp/compat/rockchip_qos_compat.h` | realized series | same | VERBATIM |  | `GPL-2.0` |
| `drivers/video/rockchip/mpp/compat/soc/rockchip/rockchip_dmc.h` | realized series | same | VERBATIM |  | `GPL-2.0` |
| `drivers/video/rockchip/mpp/compat/soc/rockchip/rockchip_opp_select.h` | realized series | same | VERBATIM |  | `GPL-2.0` |
| `drivers/video/rockchip/mpp/compat/soc/rockchip/rockchip_system_monitor.h` | realized series | same | VERBATIM |  | `GPL-2.0` |
| `drivers/video/rockchip/mpp/compat/soc/rockchip/vsi_iommu.h` | CeraLive | — | FIRST-PARTY | Fail-closed/no-op compatibility surface for the intentionally omitted AV1-only provider. | `GPL-2.0` |
| `drivers/video/rockchip/mpp/hack/mpp_hack_px30.c` | donor | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/hack/mpp_hack_px30.h` | donor | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/hack/mpp_hack_rk3576.c` | donor | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/hack/mpp_hack_rk3576.h` | donor | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/hack/mpp_rkvdec2_hack_rk3568.c` | donor | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/hack/mpp_rkvdec2_link_hack_rk3568.c` | donor | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/mpp_av1dec.c` | realized series | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/mpp_common.c` | realized series | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/mpp_common.h` | realized series | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/mpp_debug.h` | donor | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/mpp_iep2.c` | realized series | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/mpp_iommu.c` | realized series | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/mpp_iommu.h` | realized series | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/mpp_jpgdec.c` | donor | same | ADAPTED | Supply the bounds/count contract required by the hardened shared translator and use the 7.2 remove callback. | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/mpp_jpgenc.c` | donor | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/mpp_rkvdec.c` | donor | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/mpp_rkvdec2.c` | realized series | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/mpp_rkvdec2.h` | realized series | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/mpp_rkvdec2_link.c` | realized series | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/mpp_rkvdec2_link.h` | realized series | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/mpp_rkvenc.c` | donor | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/mpp_rkvenc2.c` | realized series | same | REBASED | Separate internal register messages from `__user` requests; preserve address spaces for sparse. | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/mpp_service.c` | realized series | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/mpp_vdpp.c` | donor | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/mpp_vdpu1.c` | donor | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/mpp_vdpu2.c` | donor | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/mpp_vepu1.c` | donor | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/mpp_vepu2.c` | donor | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/mpp/rockchip_iep2_regs.h` | realized series | same | VERBATIM |  | `(GPL-2.0+ OR MIT)` |
| `drivers/video/rockchip/rga3/Kconfig` | realized series | same | ADAPTED | Build `ROCKCHIP_MULTI_RGA` as a module without excluding mainline RGA. | `GPL-2.0` |
| `drivers/video/rockchip/rga3/Makefile` | realized series | same | VERBATIM |  | `GPL-2.0` |
| `drivers/video/rockchip/rga3/include/rga.h` | realized series | same | VERBATIM |  | `GPL-2.0` |
| `drivers/video/rockchip/rga3/include/rga2_reg_info.h` | realized series | same | VERBATIM |  | `GPL-2.0` |
| `drivers/video/rockchip/rga3/include/rga3_reg_info.h` | realized series | same | VERBATIM |  | `GPL-2.0` |
| `drivers/video/rockchip/rga3/include/rga_common.h` | realized series | same | VERBATIM |  | `GPL-2.0` |
| `drivers/video/rockchip/rga3/include/rga_debugger.h` | donor | same | VERBATIM |  | `GPL-2.0` |
| `drivers/video/rockchip/rga3/include/rga_dma_buf.h` | realized series | same | VERBATIM |  | `GPL-2.0` |
| `drivers/video/rockchip/rga3/include/rga_drv.h` | realized series | same | VERBATIM |  | `GPL-2.0` |
| `drivers/video/rockchip/rga3/include/rga_fence.h` | realized series | same | VERBATIM |  | `GPL-2.0` |
| `drivers/video/rockchip/rga3/include/rga_hw_config.h` | donor | same | VERBATIM |  | `GPL-2.0` |
| `drivers/video/rockchip/rga3/include/rga_iommu.h` | realized series | same | VERBATIM |  | `GPL-2.0` |
| `drivers/video/rockchip/rga3/include/rga_job.h` | realized series | same | VERBATIM |  | `GPL-2.0` |
| `drivers/video/rockchip/rga3/include/rga_mm.h` | realized series | same | VERBATIM |  | `GPL-2.0` |
| `drivers/video/rockchip/rga3/rga2_reg_info.c` | realized series | same | REBASED | Make the file-local immutable ROP table explicit for sparse. | `GPL-2.0` |
| `drivers/video/rockchip/rga3/rga3_reg_info.c` | vendor backlog | same | ADAPTED | Preserve the 7.2/yisding port and enable frame-end auto-reset so one frame cannot leave stale FIFO state for the next. | `GPL-2.0` |
| `drivers/video/rockchip/rga3/rga_common.c` | realized series | same | VERBATIM |  | `GPL-2.0` |
| `drivers/video/rockchip/rga3/rga_debugger.c` | realized series | same | VERBATIM |  | `GPL-2.0` |
| `drivers/video/rockchip/rga3/rga_dma_buf.c` | realized series | same | VERBATIM |  | `GPL-2.0` |
| `drivers/video/rockchip/rga3/rga_drv.c` | realized series | same | REBASED | Replace `strncpy`, annotate ioctl user pointers, and make file-local operations static. | `GPL-2.0` |
| `drivers/video/rockchip/rga3/rga_fence.c` | realized series | same | VERBATIM |  | `GPL-2.0` |
| `drivers/video/rockchip/rga3/rga_hw_config.c` | realized series | same | VERBATIM |  | `GPL-2.0` |
| `drivers/video/rockchip/rga3/rga_iommu.c` | realized series | same | VERBATIM |  | `GPL-2.0` |
| `drivers/video/rockchip/rga3/rga_job.c` | realized series | same | REBASED | Preserve the trusted in-kernel request pointer as a kernel address for sparse. | `GPL-2.0` |
| `drivers/video/rockchip/rga3/rga_mm.c` | realized series | same | REBASED | Preserve the trusted dma-buf object pointer as a kernel address for sparse. | `GPL-2.0` |
| `drivers/video/rockchip/rga3/rga_policy.c` | realized series | same | VERBATIM |  | `GPL-2.0` |
| `include/uapi/linux/rk-mpp.h` | realized series | same | VERBATIM |  | `((GPL-2.0+ WITH Linux-syscall-note) OR MIT)` |

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

## Adaptation and first-party rationale

Every `ADAPTED` row above gets a numbered entry here explaining the behavioural
change, what evidence justified it, and what would have to be true to revert it.
The one first-party compatibility header is included because its deliberately
negative behaviour is also part of the maintained contract.

| # | File | What changed behaviourally | Evidence | Reversion condition |
|---|---|---|---|---|
| A1 | `mpp/Kconfig`, `mpp/Makefile`, `rga3/Kconfig` | Select exactly RKVENC2, RKVDEC2, JPGDEC and multi_rga as modules; retain every other client as unselectable source. | MNH-23, the exact-selectable-symbol assertion and `configs/rk3588-media-island.fragment`. | A later ownership wave supplies explicit scope, userspace capability gating and board evidence for another client. |
| A2 | `mpp/compat/soc/rockchip/vsi_iommu.h` | Return `-ENODEV` or no-op for an AV1-only provider that this release intentionally omits. | AV1 is `BROKEN`; the manifest drops `drivers/iommu/vsi-iommu.c`; `docs/COMPAT.md` classes this surface STUB-SAFE only for the unselectable client. | AV1 becomes a supported client and the real provider is imported and linked. |
| A3 | `mpp/mpp_jpgdec.c` | Bound register translation, publish the translation-table count and propagate offset-validation errors. | JPGDEC is selected, while the replayed shared MPP translator requires explicit array/count bounds after the hardening series. | The shared translator changes contract while retaining equivalent bounds and error propagation. |
| A4 | `rga3/rga3_reg_info.c` | Enable RGA3 frame-end auto-reset in every submitted job while retaining yisding's deliberate logic-clock setting. | Rockchip commit `58a65098a6e9b2be6a08bccd45aa861850d7b8c6` documents a read-FIFO exception when an upscale frame is followed by a downscale frame at affected resolutions. | A later measured fix prevents cross-frame FIFO state without frame-end auto-reset. |

## Integration patches

Files in `integration/` patch **mainline** files rather than island-owned ones,
so they carry a different obligation: each must name the mainline file it touches
and the reason the change cannot live inside the island's own directories.

| Patch | Mainline file touched | Why it cannot be island-local |
|---|---|---|
| `0001-video-rockchip-kconfig-makefile-hooks.patch` | `drivers/video/{Kconfig,Makefile}`, `drivers/video/rockchip/{Kconfig,Makefile}` | The parent build menus live in the pinned mainline tree and must descend into the island-owned directories. |
| `0002-iommu-rockchip-export-for-mpp.patch` | `drivers/iommu/rockchip-iommu.c`, `include/soc/rockchip/rockchip_iommu.h` | Enable/reset/fault ownership is state of the real Rockchip IOMMU provider; an island-local stub would make a broken provider link look successful. |
| `0003-iommu-dma-expose-iova-domain.patch` | `drivers/iommu/dma-iommu.c`, `drivers/iommu/iova.c`, `include/linux/iommu.h`, `include/linux/iova.h` | Selected RKVENC2/RKVDEC2 reserve RCB IOVA ranges in the DMA-API allocator; only the allocator can expose and exclusively own those nodes. |

## CeraLive 7.2 delta

The replay checkpoint above is immutable. Every change after it is isolated in
the commit named here; there is no unlabelled post-replay source drift.

| Commit | Maintained delta |
|---|---|
| `50af309` | Re-anchor the real Rockchip IOMMU provider exports to Linux 7.2. |
| `ae79f74` | Re-anchor the parent video Kconfig/Makefile hooks to Linux 7.2. |
| `8d1fe43` | Re-anchor the DMA-IOMMU IOVA accessor to Linux 7.2. |
| `bec901b` | Replace the removed/unsafe string-copy shape with `strscpy()`. |
| `9d5aac0` | Add the explicit STUB-SAFE VSI surface for the omitted AV1-only provider. |
| `418de4e` | Add exclusive IOVA reservation so selected MPP clients free only allocator nodes they own. |
| `d10aa39` | Port donor-only JPGDEC to the hardened shared MPP translation contract. |
| `eaaf024` | Use Linux 7.2's `void` platform-driver remove callback. |
| `f1a0a4d` | Constrain the selectable/compiled client closure without Kconfig mutual exclusion. |
| `a615b53` | Preserve user/kernel address spaces and file-local immutable objects so sparse is clean. |

## 7.2 compile and module identity

The pinned Linux 7.2 tree was configured with arm64 `defconfig`, the pinned
device fragment and `configs/rk3588-media-island.fragment`. After generating
the provider symbol table, both selected directories built with
`KCFLAGS=-Werror` and sparse `C=2` without a finding:

```text
drivers/video/rockchip/mpp/rk_vcodec.ko
drivers/video/rockchip/rga3/rga_multicore.ko
```

The module filenames are inherited vendor names, rather than the planning
examples. Their embedded licence fields are likewise inherited and unchanged:

```text
rk_vcodec.ko: Dual MIT/GPL
rga_multicore.ko: GPL
```

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
