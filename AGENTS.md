# rk3588-media-island

## ROLE IN THE GROUP

Holds the CeraLive **RK3588 multimedia island** as maintained kernel source: the
Rockchip MPP service with exactly three compiled clients (`RKVENC2`, `RKVDEC2`,
`JPGDEC`), the `multi_rga` 2D engine driver, the UAPI headers they publish, and
the `integration/` build-hook and IOMMU-provider patches they need. Device-tree
ownership hunks arrive in the later ownership wave, not this source import.

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

## STRUCTURE

```
rk3588-media-island/
├── kernel-pin.env               # MIRROR of rk3588-kernel-patches' kernel coordinate
├── drivers/video/rockchip/
│   ├── mpp/                     # MPP service + RKVENC2/RKVDEC2/JPGDEC
│   │   └── compat/              # compat shims NEST HERE — there is no root-level compat/
│   └── rga3/                    # multi_rga
├── include/uapi/linux/          # UAPI headers the drivers publish
├── integration/                 # patches to MAINLINE files: build hooks, provider exports
├── patches/                     # GENERATED series — never hand-edited
├── scripts/                     # series generation, provenance, lint tooling
│   ├── build-series.py          # drivers/ + integration/ -> patches/ ; --check byte-compares
│   ├── verify-series-parity.py  # the SECOND, independent opinion — never imports the generator
│   ├── check-compat-shims.py    # shim-lint: the docs/COMPAT.md 5-step specification
│   ├── check-dt-ownership.py    # dt-ownership-lint: the one-compatible rule
│   ├── check-upstream-freshness.py  # the issue-only watch's comparison
│   └── check-action-pins.sh     # every `uses:` against gh api releases/latest
├── tests/
│   ├── board/                   # hardware-gated drills, probes and fixtures
│   ├── kunit/                   # in-kernel unit tests
│   └── fuzz/                    # UAPI fuzz targets
└── docs/
    ├── COMPAT.md                # shim + external-symbol inventory; ALSO the shim-lint input
    ├── OWNERSHIP.md             # silicon ownership table; ALSO the dt-ownership-lint input
    ├── REFERENCES.md            # every pinned coordinate
    ├── PROVENANCE.md            # per-file import ledger
    ├── UPSTREAM-STATUS.md       # mainline movement; the issue-only watch
    └── BOARD-QUALIFICATION.md   # what real hardware must demonstrate
```

## WHERE TO LOOK

| Task | Location |
|------|----------|
| Find out what a CI job asserts, or why one is currently vacuous | [`docs/CI.md`](docs/CI.md) |
| Regenerate the series after changing `drivers/` or `integration/` | `scripts/build-series.py` — then `--check` and `scripts/verify-series-parity.py` |
| Change the target kernel | **Not here.** Bump [`rk3588-kernel-patches/kernel-pin.env`](https://github.com/CERALIVE/rk3588-kernel-patches/blob/main/kernel-pin.env) first, then mirror it into [`kernel-pin.env`](kernel-pin.env) |
| Decide which driver owns a silicon block | [`docs/OWNERSHIP.md`](docs/OWNERSHIP.md) |
| Classify an external symbol the drivers call | [`docs/COMPAT.md`](docs/COMPAT.md) |
| Find where a source file came from | [`docs/PROVENANCE.md`](docs/PROVENANCE.md) |
| Look up a pinned upstream SHA | [`docs/REFERENCES.md`](docs/REFERENCES.md) |
| See whether mainline has caught up on a block | [`docs/UPSTREAM-STATUS.md`](docs/UPSTREAM-STATUS.md) |
| Know what a board must demonstrate before a tick | [`docs/BOARD-QUALIFICATION.md`](docs/BOARD-QUALIFICATION.md) |
| Understand which licence branch applies to a file | [`LICENSE.md`](LICENSE.md) |
| Build the modules | [`README.md`](README.md) → "Building the modules" |
| Add a compat shim | `drivers/video/rockchip/mpp/compat/` — and add its row to `docs/COMPAT.md`, or the lint refuses the build |
| Change a device-tree node's owner | `integration/` — and update the `docs/OWNERSHIP.md` row in the same change |

## KEY FACTS

**`kernel-pin.env` is a MIRROR, not a decision.** Its four `KERNEL_*` values are
byte-identical to `rk3588-kernel-patches/kernel-pin.env`, and a `pin-equality` CI
job proves it against the consumer at its pinned commit. Bumping the kernel is a
change to the consumer repository first; this file follows. A hand-edit here is a
red build, and that is the whole point — a modules-only cross-compile proves
nothing if it ran against a kernel the device never boots.

**`patches/` is generated. Editing it by hand is a bug, and CI catches it.**
The series generator regenerates from `drivers/` plus `integration/` into a temp
directory and byte-compares. Change the source, then regenerate — never the other
way round. An independent parity checker exists as a second opinion and must not
import the generator: a checker sharing the producer's code proves only that the
producer agrees with itself.

**Ownership is a device-tree `compatible` string, and never a Kconfig
dependency.** Every island-owned node carries exactly ONE `compatible`, matched
by exactly ONE driver. Mainline `rkvdec` and `rockchip-rga` stay BUILT alongside
the island so each silicon handover is reversible by a device-tree change and
A/B-able with `driver_override`. `CONFIG_VIDEO_ROCKCHIP_RGA` joins the image's
forbidden list only at the RGA flip, once no node is left for it to bind. The
mechanism, and why load order makes the alternative non-deterministic, is
[`docs/OWNERSHIP.md`](docs/OWNERSHIP.md).

**`docs/COMPAT.md` and `docs/OWNERSHIP.md` are machine inputs, not just prose.**
`shim-lint` parses COMPAT's table for every symbol classed `REAL-DEPENDENCY` and
fails if a compat header gives one a body — a stub returning `0`, `false`, `NULL`,
`ERR_PTR(...)`, `-ENODEV`, or an empty `void` body all fail. It also rejects any
`<soc/rockchip/*.h>` include and any new `rockchip_*` symbol absent from the
table, so source growth fails closed until its semantics are classified.
`dt-ownership-lint` reads OWNERSHIP the same way. Editing either table changes
what compiles; treat them as code.

**A compile can never succeed by silently replacing a REAL-DEPENDENCY with a
stub.** That invariant is the reason both halves of the shim gate exist: the lint
catches a stub with a body, and the link catches a declaration with no provider.
Neither alone is sufficient.

**Compat shims nest at `drivers/video/rockchip/mpp/compat/`.** That is where the
upstream Makefile consumes them. There is **no** root-level `compat/` directory,
and creating one moves the headers out from under both the build and the lint.

**Every board result names its board, kernel build and island tag.** A result
that cannot say which bytes it exercised is not a result. The RAUC precondition
(other slot confirmed good, attempt budget at least one, candidate-slot journal
captured **before** any reboot) is mandatory before any board deploy: the island
rides inside `linux-image`, so a broken kernel auto-rolls-back and takes its
evidence with it.

## PR TARGETING

**This repository is NOT a fork.** It has no upstream parent on GitHub, so
`gh pr create` defaults its base correctly — unlike the sibling
`rk3588-kernel-patches`, which is a fork and has historically defaulted to the
wrong repository. That difference is a reason to be careful rather than relaxed:
the habit that protects the sibling is the habit that keeps this one right too.

Always be explicit anyway:

```bash
gh pr create --repo CERALIVE/rk3588-media-island --base main
gh pr view <n> --json url -q .url   # MUST be https://github.com/CERALIVE/rk3588-media-island/...
```

Keep **only** `origin` (CERALIVE) attached at rest. The vendor and forward-port
trees this repository imports from are cited by URL and SHA in
[`docs/REFERENCES.md`](docs/REFERENCES.md); if one ever needs fetching, add it
transiently under a descriptive name — **never** as `upstream` — fetch with an
explicit refspec, pin-verify the SHA, and remove it before any push or PR.

One integration branch per release, one PR from it. Commits on that branch stay
individually meaningful, because provenance and review history are the reason this
is a source repository instead of a patch file.

## CI

All workflows follow the CeraLive CI/CD canon: a `concurrency` block on every
workflow (`cancel-in-progress: true` for PR gates, `false` for release);
`push` constrained to `branches:` and `tags:` because a `pull_request` trigger
exists; top-level `permissions: contents: read`; every `uses:` pinned to the
latest stable major; the kernel clone and `ccache` cached; nothing published
without the gates having run first.

Three workflows: `ci.yml` (the PR gate), `release.yml` (`workflow_dispatch`, with
`publish` defaulting to **false**), and `upstream-watch.yml` (scheduled,
issue-only). Per-job detail, the mutation transcripts, and the honest list of
remaining deferred inputs live in [`docs/CI.md`](docs/CI.md).

| Job | Asserts |
|-----|---------|
| `shellcheck` | Every tracked shell script lints clean at `-S style` (only `SC1091` excluded) |
| `self-tests` | Every board harness and every CI tool passes its own scored fixtures |
| `series-integrity` | `patches/` regenerates byte-identically from `drivers/` + `integration/`, verified again by an independent parity checker |
| `shim-lint` | No compat header gives a `REAL-DEPENDENCY` symbol a body; no unclassified `<soc/rockchip/*.h>` include or `rockchip_*` symbol exists |
| `dt-ownership-lint` | The pinned-tree collision arm runs now; the one-compatible arm reports `NO-DT-YET` until the ownership wave lands |
| `uapi-parity` | Every `MPP_CMD_*` / `MPP_IOC_*` value and the `mpp_request` layout match the pinned vendor header and the userspace that consumes them |
| `board-probes` | The three C probes cross-build for aarch64 with `-Werror`, and their host build passes its own self-tests |
| `action-pins` | Every `uses:` is at the current latest major. **Non-blocking** — an action's release cadence must not redden an unrelated PR |
| `pin` | Nothing — it *reads* the coordinates out of `kernel-pin.env` and emits them as job outputs |
| `pin-equality` | The four mirrored `KERNEL_*` values equal the consumer's |
| `cross-compile-modules` | Both pinned kernel objects resolve; the tree configures the way the device is configured; a configured `vmlinux` supplies the real provider symbol table; the two arm64 modules link with `-Werror` and the exact `.ko` set; no island `compatible` collides with a mainline `of_match_table` |
| `kunit` | Reports `NO-KUNIT-CASES-YET` until todo 9 lands the first suite, then builds it against the pinned tree |
| `static-analysis` | sparse with findings promoted to errors plus coccinelle over every selected island object; smatch remains conditional on a suitable runner package |
| `upstream-watch` | Nothing — it opens or updates ONE issue and never edits a pin or dispatches a build |

**`shellcheck` and `self-tests` are two jobs because they answer two questions.**
Shellcheck cannot see an ERE bracket expression containing a literal `\t` — valid
shell, valid regex, and it matches a backslash and a `t` rather than a tab. That
defect shipped once here. Reintroducing it leaves shellcheck green and turns the
harness self-test red; the transcript is [`docs/CI.md`](docs/CI.md) §3.

**The source-dependent gates are live.** Series integrity reconstructs 66 source
files and three integration payloads, shim/UAPI checks inspect the imported
surface, sparse checks every selected object, and cross-compile asserts exactly
`rk_vcodec.ko` plus `rga3.ko`. Only the future DT ownership hunks and KUnit cases
remain explicit zero-input states; neither is silently reported as a pass.

**No workflow restates a pinned coordinate.** The kernel tag is read from
`kernel-pin.env`; a literal tag anywhere in `.github/` is a regression, because a
pin bump would otherwise leave CI proving the series against a kernel nobody ships
— green, which is the worst kind of failure.

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
