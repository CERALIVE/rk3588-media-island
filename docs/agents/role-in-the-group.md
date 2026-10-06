<!-- Moved verbatim from AGENTS.md on 2026-10-05 by lean-rules-docs-landing-latam -->

## ROLE IN THE GROUP

Holds the CeraLive **RK3588 multimedia island** as maintained kernel source: the
Rockchip MPP service with exactly three compiled clients (`RKVENC2`, `RKVDEC2`,
`JPGDEC`), the `multi_rga` 2D engine driver, the UAPI headers they publish, and
the `integration/` build-hook, IOMMU-provider and MPP device-tree patches they
need. The applied RGA3-pair and RGA2 ownership hunks form one reversible
device-tree flip; all three nodes now carry sole `multi_rga` compatibles.

It is **not a patch repository**. Its release artifact is a **generated** `git am`
mailbox series; the source is the truth and the series is an output.

Produces **no `.deb`**, no kernel and no image artifact. It is therefore **NOT in
the device image `REPOS` array** and not in `fetch-debs.sh`. It does carry a root
`versions.yaml` entry — unlike the two RK3588 patch repositories — because it cuts
releases whose tag the consumer's lane names.

Relates to:

- **`rk3588-kernel-patches/` — the SOLE consumer.** It ingests this repository's
  release asset byte-preserved into an `island/` lane. Nothing else consumes the
  island directly.
- **`image-building-pipeline/` — the INDIRECT consumer.** It never sees this
  repository. It pins the consumer's commit through a single
  `kernel_source.patches_commit`, exactly as it did before the island existed.
- `cerastream/` — the streaming engine that ends up driving this silicon through
  GStreamer and librga. It consumes the island's behaviour, never its source.

A kernel change therefore costs **three merges**: island tag → consumer
`island/` lane bump → image `patches_commit` bump. Never plan a driver fix as a
single pull request.

