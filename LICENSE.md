# Licensing

This repository carries Rockchip kernel driver source that CeraLive did not
write, alongside integration work that CeraLive did. Those two bodies of code
have different licence expressions, and the split is per file. `LICENSE` holds
the GPL-2.0 text; this document explains which notice applies where and why.

The short version, and the only rule that never bends:

> **CeraLive uses the GPL-2.0 branch of every inherited expression, and never
> independently asserts the MIT branch.**

## Where the source comes from

Two upstream objects are named throughout this repository. Both are pinned by
full 40-character SHA, never by branch:

| Role | Object |
|---|---|
| Vendor donor — the Rockchip BSP tree the driver source originates in | `rockchip-linux/kernel@b4ef083dc0c3608e744deabb43dc6b781aadbe6e` (`develop-6.1`) |
| Forward-port record — the maintained 6.18 patch series and its licence policy | `yisding/rock-5b-ysp@ca3da04280c48c004e522c15f31862bf88a2d1b9` |

The realized form of that series is `yisding/linux-rock5b@e7ff978398825b63ddcb13e0572d77564034c1e2`;
`armbian/linux-rockchip@fd9f82366e235b8afbdf516765210e97d24dce93` is retained as
historical comparison material only. Full provenance detail, including how each
object was verified, is in [`docs/PROVENANCE.md`](docs/PROVENANCE.md) and
[`docs/REFERENCES.md`](docs/REFERENCES.md).

## The per-file SPDX census

The census below was performed over every `.c` and `.h` file in the pinned donor
paths. It is quoted here because it is the factual basis for the rule at the top
of this file, and a rule with no census behind it is an assertion.

| Path | Files | SPDX identifier carried |
|---|---|---|
| donor `drivers/video/rockchip/mpp/` | **29 / 29** | `SPDX-License-Identifier: (GPL-2.0+ OR MIT)` |
| donor `drivers/video/rockchip/rga3/` | **24 / 24** | `SPDX-License-Identifier: GPL-2.0` |
| forward-ported MPP directory — carried vendor files | **20** | `(GPL-2.0+ OR MIT)`, unchanged from the donor |
| forward-ported MPP directory — yisding-authored compat headers | **7** | `GPL-2.0` |
| forward-ported RGA3 directory | **24 / 24** | `GPL-2.0`, unchanged from the donor |

No file in either directory, in either tree, lacks an SPDX identifier. The
representative donor files checked line-by-line are `mpp_common.c:1`,
`mpp_iommu.c:1`, `mpp_rkvenc2.c:1`, `mpp_rkvdec2.c:1` and `mpp_jpgdec.c:1` for
MPP, and `rga_drv.c:1`, `rga_job.c:1`, `rga_iommu.c:1`, `rga_dma_buf.c:1` and
`include/rga_fence.h:1` for RGA3 — all at
`b4ef083dc0c3608e744deabb43dc6b781aadbe6e`.

## What that means for this repository

Three categories, three answers:

1. **Inherited MPP source** keeps its `(GPL-2.0+ OR MIT)` identifier verbatim.
   That is a dual expression offered by Rockchip; a downstream may pick either
   branch. CeraLive picks GPL-2.0. The identifier line stays exactly as written
   because rewriting it would misrepresent what the copyright holder offered.
2. **Inherited RGA source** keeps its `GPL-2.0` identifier verbatim. There is no
   second branch to pick.
3. **CeraLive's own contributions** — the `integration/` mainline-file patches,
   the provider adapters, the build and test tooling, the KUnit and fuzz
   harnesses, and every documentation file here — are **`GPL-2.0-only`**. New
   first-party files carry `SPDX-License-Identifier: GPL-2.0-only`.

## MIT is never independently claimed

This is a hard constraint, and it is worth stating as a mechanism rather than a
preference. The MIT branch appears in the inherited MPP files only because
Rockchip wrote a dual expression. CeraLive has performed no independent MIT
audit, holds no MIT grant of its own, and has no basis on which to represent that
the MPP driver as shipped here is usable under MIT terms — the RGA half is
`GPL-2.0` alone, the combined work is therefore GPL-2.0, and an MIT claim over
any part of it would be a licence assertion unsupported by the census above.

Concretely, all of the following are forbidden:

- adding an MIT `LICENSE` file, an MIT badge, or an MIT claim in packaging metadata;
- rewriting an inherited `(GPL-2.0+ OR MIT)` identifier to `MIT` or to `GPL-2.0`;
- relicensing any inherited file, in either direction;
- copying Yi Ding's prose or evidence text into this repository. That material is
  cited by URL plus SHA, never reproduced.

The upstream forward-port repository states its own additions are
`GPL-2.0-or-later` while explicitly warning that imported files and patch context
retain their own notices. That warning is correct and it is why the census above
exists: a collection-level policy does not relicense the payload it collects.

## Attribution

Copyright in the inherited driver source is Rockchip Electronics Co., Ltd.'s and
that of the other contributors named in the individual file headers. Those
headers are authoritative and are never edited. Yi Ding is credited for the
6.18 forward-port series this repository's import descends from; that credit is a
provenance record, not a transfer of anything.
