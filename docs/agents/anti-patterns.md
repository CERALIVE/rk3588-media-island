<!-- Moved verbatim from AGENTS.md on 2026-10-05 by lean-rules-docs-landing-latam -->

## ANTI-PATTERNS

- Don't compile a fourth MPP client. Exactly `RKVENC2`, `RKVDEC2` and `JPGDEC`
  are built; `IEP2`, `VDPP`, `VEPU*`, `JPGENC`, `RKVDEC` v1 and `RKVENC` v1 stay
  `=n`, and no runtime capability table may advertise a client that is not both
  compiled and probed
- Don't add AV1 encode or decode. `av1d` stays driverless from the island's side
  and `ROCKCHIP_MPP_AV1DEC` stays `=n`
- Don't add 10-bit anywhere — P010, NV15 and FBC/AFBC included — even though the
  vendor `multi_rga` supports them
- Don't add a new DTB or overlay FILE. The platform device-tree prune is a
  verified allowlist; the island ships in-tree `rk3588-base.dtsi` and board-DTS
  hunks only
- Don't add a Kconfig mutual exclusion (`depends on !VIDEO_ROCKCHIP_VDEC`,
  `!VIDEO_ROCKCHIP_RGA`). Exclusivity is the one-`compatible` rule plus a CI
  lint; keeping the mainline drivers built is what makes every flip reversible
- Don't give an island-owned node two `compatible` strings. Which driver wins is
  module load order, which is not a design
- Don't hand-edit `patches/` — regenerate from `drivers/` and `integration/`
- Don't make the parity checker import the series generator; it is deliberately
  the second, independent opinion
- Don't hand-edit `kernel-pin.env`'s four mirrored `KERNEL_*` values, and don't
  restate a pinned coordinate in a workflow
- Don't create a root-level `compat/` directory; shims nest under
  `drivers/video/rockchip/mpp/compat/`
- Don't give a `REAL-DEPENDENCY` symbol a stub body in a compat header, and don't
  add a `<soc/rockchip/*.h>` include or a new `rockchip_*` symbol without its
  `docs/COMPAT.md` row
- Don't claim upstream-submission status, assert the MIT branch of the inherited
  licence, relicense a file, rewrite an SPDX identifier, or copy upstream prose
  and evidence — cite it by URL and SHA
- Don't reference a path above this repository's root from any tracked file, and
  don't add a sibling `link:` or `file:` dependency. CI clones the kernel by URL
  and never reads a sibling checkout
- Don't add a `Co-authored-by:` trailer or any AI/tool attribution to any commit.
  This is a **public** repository and the rule is absolute
- Don't ship a separate `.deb` for the island, and don't add this repository to
  the device image `REPOS` array. It rides inside `linux-image` as `=m`
- Don't renumber the consumer's `SERIES_TOTAL`, reuse a retired ordinal, close an
  ordinal gap, or `git rm` one of its source-lane patches. The `island/` lane is a
  member of that series and inherits its numbering discipline
- Don't put compile evidence in `rk3588-kernel-patches`. That repository's scope
  is patch application only; the island's CI and the image dry-runs are where
  build claims live
- Don't deploy to a board without the RAUC precondition and a pre-reboot journal
  capture, and don't tick a qualification leg without a pasted transcript
