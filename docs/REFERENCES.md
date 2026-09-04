# References — every pinned coordinate this repository depends on

One table row per external object the island is anchored to. Everything here is
pinned by an immutable identifier: a full 40-character SHA or an exact tag with
its resolved commit. **No row may ever name a branch.** A branch is a moving
target, and a moving target makes every claim in this repository unfalsifiable.

## Upstream source objects

| Role | Repository | Pinned object |
|---|---|---|
| Vendor donor — where the MPP and RGA driver source originates | `rockchip-linux/kernel` (`develop-6.1`) | `b4ef083dc0c3608e744deabb43dc6b781aadbe6e` |
| Forward-port patch record — the 6.18 series, its README, its licence policy | `yisding/rock-5b-ysp` | `ca3da04280c48c004e522c15f31862bf88a2d1b9` |
| Realized maintained series — the branch tip the patch record exports from | `yisding/linux-rock5b` | `e7ff978398825b63ddcb13e0572d77564034c1e2` |
| Historical comparison only — NOT an import source | `armbian/linux-rockchip` (`rk-6.1-rkr5.1`) | `fd9f82366e235b8afbdf516765210e97d24dce93` |
| Mainline replacement baseline | Linux `v7.2` | `8d3ae59288f1e7d58d76558a6ee96d533bc5019f` |

## Vendor media-watch baselines

These are review cursors, not source pins. The weekly issue-only watch compares
each branch after this object and reports only commits touching the three media
paths recorded in [`VENDOR-BACKLOG.md`](VENDOR-BACKLOG.md). A branch moving
elsewhere is deliberately silent.

| Role | Repository | Pinned object |
|---|---|---|
| Vendor backlog review baseline | `rockchip-linux/kernel` (`develop-6.1`) | `77168c8d5ab82399f65a80e9f807b50ba37cf483` |
| Armbian rkr6.1 media-watch baseline — comparison only | `armbian/linux-rockchip` (`rk-6.1-rkr6.1`) | `82c6b3ef1c935064d4aa87f698412fdc37a4435f` |
| Armbian rkr7.2 media-watch baseline — comparison only | `armbian/linux-rockchip` (`rk-6.1-rkr7.2`) | `057c0edb6f11e42690f5af80e4f10e674c621b2e` |

## CI tool objects

Linux 7.2 uses syntax that the Ubuntu runner's packaged sparse cannot parse, so
the static-analysis job builds sparse from one immutable upstream object rather
than silently skipping the checker.

| Role | Repository | Pinned object |
|---|---|---|
| sparse semantic checker | `kernel.org/pub/scm/devel/sparse/sparse.git` | `37156835e3d725b6d750f000be33ba3814bb2310` |

Two of those five deserve a sentence, because getting them the wrong way round
is the easiest mistake available here:

- **The donor is Rockchip's, not Armbian's.** The Armbian object reports RGA
  header version 1.3.7; the donor reports 1.3.11. Armbian is therefore
  comparison material for reading how a hunk used to look, never the source the
  island imports from.
- **The forward-port record and the realized series are two different objects.**
  `rock-5b-ysp` holds the patch files, the README and the licence policy;
  `linux-rock5b` holds the tree those patches produce. A citation to a driver
  source line resolves against the realized series; a citation to a patch line or
  to licence policy resolves against the patch record.

## Kernel pin

The kernel coordinate is **mirrored, not decided here** — see
[`../kernel-pin.env`](../kernel-pin.env) for the mechanism and the reason the
four values are byte-identical to the consumer repository's.

| Field | Value |
|---|---|
| `KERNEL_TAG` | `v7.2` |
| `KERNEL_TAG_OBJECT` | `237a1c39e8dfd3e1c6f1f023eea37a48ec04cc63` (annotated tag object, tagged 2026-08-16) |
| `KERNEL_COMMIT` | `8d3ae59288f1e7d58d76558a6ee96d533bc5019f` (`v7.2^{commit}`) |
| `KERNEL_MIRROR` | `https://github.com/gregkh/linux.git` |

Both the tag object and the peeled commit are pinned, and both are asserted. A
peeled commit alone cannot detect a tag object that was re-created — re-signed,
re-dated, re-worded — while still pointing at the same commit, and the tag object
is what a signature verifies against. Bump the two together or not at all.

## Consumer pin

`rk3588-kernel-patches` is the island's **sole** consumer. Its `island/` lane
carries this repository's generated series asset, and its own `kernel-pin.env` is
the upstream of the mirrored block above.

| Field | Value |
|---|---|
| Repository | `CERALIVE/rk3588-kernel-patches` |
| Pinned commit | *not yet pinned — the `island/` lane is created in a later step of this effort* |
| Kernel coordinate agreement | asserted by the `pin-equality` CI job |

That placeholder is deliberate and is not a licence to leave it. It becomes a
40-character SHA at the same change that creates the `island/` lane, and the
`pin-equality` job resolves the consumer's file at that SHA rather than at its
branch head.

## Driver versions

| Component | Version | Status |
|---|---|---|
| `multi_rga` `DRIVER_VERSION` | `1.3.11` | Read directly from `drivers/video/rockchip/rga3/include/rga_drv.h` (`1`, `3`, `11`). |
| MPP service `MPP_VERSION` | `6.18-rkvenc-fwport` | Read directly from the imported MPP Makefile. This identifies the inherited forward-port source line; the kernel target remains the independently pinned Linux 7.2 object above. |

Both values are measured from maintained source, not inferred from a repository
tag or from the target kernel version.

## Image-pipeline coordinate

The modules-only cross-compile builds against the device's real kernel
configuration rather than a bare `defconfig`, so it needs the image repository's
Kconfig fragment at a pinned revision.

| Field | Value |
|---|---|
| Repository | `CERALIVE/image-building-pipeline` |
| Fragment | `manifests/kernel/rk3588-edge.fragment` |
| Pinned commit | `e6b70f0da06a3ee82c9e0790225c80597ed05ab7` |

`cross-compile-modules` fetches that one file at that one commit and merges it
over the in-tree arm64 `defconfig` with the kernel's own
`scripts/kconfig/merge_config.sh` — the same mechanism the image build uses, so
the modules are compiled against the configuration the device actually boots.
Fetching the fragment from the repository's branch head instead would mean a
green build proving the island against a configuration nobody ships, which is the
failure this whole file exists to prevent.

The island's own Kconfig symbols are the third input the README names. They are
enabled through `configs/rk3588-media-island.fragment`; CI asserts both the
resulting module values and the exact set of selectable MPP clients.

## Release 1

| Tag | Commit | Asset | Asset SHA-256 |
|---|---|---|---|
| `v2026.9.0` | `dcda1a2218d9e52db2db2a0a809263d7d7e8831f` | `rk3588-media-island-v2026.9.0.mbox.tar` | `bea66ab56a71e5869d5e9ac6d66bb5f4e5151190dd387abe345fc88dc9f5eec2` |

Published 2026-09-03T15:20:20Z at https://github.com/CERALIVE/rk3588-media-island/releases/tag/v2026.9.0.
The accompanying checksum asset is `rk3588-media-island-v2026.9.0.mbox.tar.sha256` with SHA-256
`ee3d23621c5615dfef0b618dc11d514f38ff9e88bd73c93d49a92dea099dcdea`.

## Release 2

| Tag | Commit | Asset | Asset SHA-256 |
|---|---|---|---|
| `v2026.9.1` | `b825aaedd538a97d83ba1c0ae08bc9a2b04e7b6c` | `rk3588-media-island-v2026.9.1.mbox.tar` | `a1992957b0e3b409cea7c570e2fedd64ebd29e95f0ea39635dc4f336325b6fbd` |

Published 2026-09-04T05:16:43Z at https://github.com/CERALIVE/rk3588-media-island/releases/tag/v2026.9.1.
The accompanying checksum asset is `rk3588-media-island-v2026.9.1.mbox.tar.sha256` with SHA-256
`e139112ba01a3754256bf8717df7898abc0ad50da83d51cc2184d4930f0b6578`.

This release carries the tracepoint/debugfs/procfs instrumentation, the recovery-state and
request-validation work, and the three fault fixes the reliability drill found. The base
verdict it ships under is `docs/PHASE3-DECISION.md`: reversal gate G1 **NOT-FIRED**.

## Release 3

| Tag | Commit | Asset | Asset SHA-256 |
|---|---|---|---|
| `v2026.9.2` | `1fd357d8a8b83b6f4ed7f7692d761f7b653d44f5` | `rk3588-media-island-v2026.9.2.mbox.tar` | `393b50a26117b95659f35a603abb9939f767e397f71e85fb180dda107e2df616` |

Published 2026-09-04T09:59:22Z at https://github.com/CERALIVE/rk3588-media-island/releases/tag/v2026.9.2.
The accompanying checksum asset is `rk3588-media-island-v2026.9.2.mbox.tar.sha256` with SHA-256
`bc05624e91b05e82638fbd190a35c8eac1b12b77ff967f8627f7aae1241b572e`.

This release carries the multi_rga mainline API port, fail-closed request validation, and the
atomic RGA3/RGA2 device-tree ownership flip.

## How to add a row

Resolve the object live, never from a cache or a previous note; record the full
40-character SHA; and state what the pin is FOR, so a later reader can tell
whether a bump is safe. A row that records a SHA but not its purpose cannot be
re-verified by anyone but its author.
