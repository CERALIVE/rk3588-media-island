# rk3588-media-island

The CeraLive **RK3588 multimedia island**: the Rockchip MPP service and the
`multi_rga` 2D engine driver, carried as maintained kernel **source** and
released as a `git am` mailbox series.

| | |
|---|---|
| **What it holds** | `drivers/video/rockchip/mpp/` and `drivers/video/rockchip/rga3/`, the UAPI headers they publish, and the `integration/` patches to mainline files they need |
| **MPP clients compiled** | `RKVENC2`, `RKVDEC2`, `JPGDEC` — those three and no others |
| **Target kernel** | `v7.2` (`8d3ae59288f1e7d58d76558a6ee96d533bc5019f`), mirrored from [`kernel-pin.env`](kernel-pin.env) |
| **Boards** | Radxa Rock 5B+, Orange Pi 5+ |
| **Release artifact** | a generated `git am` series, plus its `.sha256` — no `.deb`, no kernel, no image |
| **Versioning** | CalVer, `YYYY.MINOR.PATCH` |
| **Status** | **GREENFIELD.** Repository scaffolding only. No driver source is imported yet, no series has been generated, and no image or board carries the island. |

## Why this is a source repository and not a patch repository

CeraLive already has a patch repository for the RK3588 kernel:
[`rk3588-kernel-patches`](https://github.com/CERALIVE/rk3588-kernel-patches). It
carries patch text, and it is very good at it — provenance lanes, byte-parity
proofs, a retirement registry, an ordinal discipline that never reuses a slot.

That model works because those patches are small, externally authored, and mostly
awaiting upstream. The MPP and RGA drivers are none of those things. They are
tens of thousands of lines of vendor code that CeraLive maintains, rebases,
fixes, sanitizes and tests over a long horizon. Code of that size needs what code
gets: review history per change, unit tests, KUnit and fuzz targets, static
analysis, and a release train. A giant opaque `.patch` file gets none of it.

So the island is source, and the **series is generated from it**. That inverts
the usual relationship: the mailbox series is an output artifact, like a compiled
binary, and hand-editing it is a defect rather than a shortcut.

## How a release becomes a kernel change

Three merges, not one. Nothing about this stack may be planned as though a driver
fix were a single pull request:

```
island tag  ──▶  rk3588-kernel-patches `island/` lane bump
                   ──▶  image `patches_commit` bump
                          ──▶  image build  ──▶  device
```

1. **Island release.** A tag triggers the release workflow, which regenerates the
   series from source, byte-compares it against the checked-in `patches/`, and
   publishes it as an immutable release asset with its checksum.
2. **Consumer lane bump.** `rk3588-kernel-patches` consumes that asset
   **byte-preserved** into its `island/` lane. Provenance on an `island/` member
   is its own variant naming the island tag, commit and asset digest — never an
   upstream cherry-pick stamp, because there is no upstream commit to name.
3. **Image bump.** The image's single `kernel_source.patches_commit` pin moves to
   the consumer repository's new commit. That mechanism is unchanged by the
   island's existence; the image still sees one patch repository and one pin.

The island produces **no `.deb`**, is absent from the device image `REPOS` array
and from `fetch-debs.sh`, and rides inside `linux-image` like every other kernel
change.

## Ownership: one driver per node

The Linux driver core binds one driver per platform device, and when two drivers
match one node the winner is module load order — non-deterministic, and therefore
not a design. Every island-owned node therefore carries **exactly one**
`compatible` string, matched by exactly one driver.

Mainline `rkvdec` and `rockchip-rga` stay **built** alongside the island. They are
not excluded by Kconfig, deliberately: keeping them built is what makes each
silicon handover reversible by a device-tree change rather than a kernel rebuild,
and it keeps the upstream-migration target alive in the same image.

The per-block table, and the CI lint that enforces it, are in
[`docs/OWNERSHIP.md`](docs/OWNERSHIP.md).

## Repository layout

```
rk3588-media-island/
├── kernel-pin.env          # MIRROR of rk3588-kernel-patches' kernel coordinate — never edited here
├── drivers/video/rockchip/
│   ├── mpp/                # MPP service + the three compiled clients; compat shims nest at mpp/compat/
│   └── rga3/               # multi_rga
├── include/uapi/linux/     # the UAPI headers the drivers publish
├── integration/            # patches to MAINLINE files: DT hunks, provider exports
├── scripts/                # series generation, provenance and lint tooling
├── tests/
│   ├── board/              # hardware-gated drills and probes
│   ├── kunit/              # in-kernel unit tests
│   └── fuzz/               # UAPI fuzz targets
└── docs/
    ├── COMPAT.md           # shim + external-symbol inventory; ALSO the shim-lint input
    ├── OWNERSHIP.md        # silicon ownership table + the one-compatible rule
    ├── REFERENCES.md       # every pinned coordinate
    ├── PROVENANCE.md       # per-file import ledger
    ├── UPSTREAM-STATUS.md  # what mainline is doing; the issue-only watch
    └── BOARD-QUALIFICATION.md  # what real hardware must demonstrate
```

## Building the modules

The island builds **out of tree, modules only**, against the pinned kernel. It
never builds a whole kernel, and CI never clones a sibling checkout — the kernel
comes from the URL in `kernel-pin.env`.

```bash
# 1. Source the pin.
set -a && . ./kernel-pin.env && set +a

# 2. Clone the pinned kernel and verify BOTH the tag object and the peeled commit.
git clone --depth 1 --branch "$KERNEL_TAG" "$KERNEL_MIRROR" .work/linux

# 3. Apply the integration patches (mainline-file changes) and stage the island
#    directories into the tree.
#    -> scripts/ carries this; see docs/CI.md once the tooling lands.

# 4. Modules-only cross-build.
make -C .work/linux ARCH="$ISLAND_ARCH" CROSS_COMPILE="$ISLAND_CROSS_COMPILE" \
     M=drivers/video/rockchip/mpp  modules
make -C .work/linux ARCH="$ISLAND_ARCH" CROSS_COMPILE="$ISLAND_CROSS_COMPILE" \
     M=drivers/video/rockchip/rga3 modules
```

The build config is arm64 `defconfig` plus the device image's own kernel fragment
plus the island's `Kconfig` symbols — not a bare `defconfig`. Building against a
configuration the device does not run proves the wrong thing.

## Testing

| Tier | Runs where | Proves |
|---|---|---|
| `tests/kunit/` | CI, no hardware | in-kernel logic units |
| `tests/fuzz/` | CI, no hardware | the UAPI surface survives hostile input |
| static analysis | CI, no hardware | sparse, smatch and coccinelle findings stay at zero |
| `tests/board/` | a real Rock 5B+ or Orange Pi 5+ | everything about silicon |

The board suite is deliberately outside the kernel build. Every script is gated,
takes board identity only through environment variables, and never locates
credentials or references a path above this repository's root. What each drill
must demonstrate before it may be ticked is
[`docs/BOARD-QUALIFICATION.md`](docs/BOARD-QUALIFICATION.md).

## Versioning

CalVer, `YYYY.MINOR.PATCH`, matching the rest of the CeraLive stack. The tag is
what the consumer repository's `island/` lane names, so a tag is immutable once
published: the release workflow claims it atomically and byte-compares the
uploaded asset before publishing.

## Licence

GPL-2.0. The inherited MPP source carries Rockchip's dual
`(GPL-2.0+ OR MIT)` expression and the inherited RGA source carries `GPL-2.0`;
CeraLive uses the GPL-2.0 branch of both and **never independently claims MIT**.
CeraLive's own contributions are `GPL-2.0-only`. The full per-file census, and
the two upstream SHAs it was taken against, are in [`LICENSE.md`](LICENSE.md).

## Contributing

Read [`CONTRIBUTING.md`](CONTRIBUTING.md) for the commit trailers, the branch and
PR shape, and the testing gate. [`AGENTS.md`](AGENTS.md) is the routing layer for
AI build agents and the canonical statement of this repository's anti-patterns.
