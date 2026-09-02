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
| `multi_rga` `DRIVER_VERSION` | **not yet determined** | Read out of the imported RGA source at import time and recorded here then. The donor object reports RGA header version 1.3.11; the driver's own `DRIVER_VERSION` string is a separate value and is not assumed from it. |
| MPP service version | **not yet determined** | Same: recorded at import, never inferred. |

Both rows are filled by the source-import step. Leaving a guess here would be
worse than leaving the row empty, because a guessed version is indistinguishable
from a measured one once it is written down.

## Image-pipeline coordinate

The modules-only cross-compile builds against the device's real kernel
configuration rather than a bare `defconfig`, so it needs the image repository's
Kconfig fragment at a pinned revision.

| Field | Value |
|---|---|
| Repository | `CERALIVE/image-building-pipeline` |
| Fragment | `manifests/kernel/rk3588-edge.fragment` |
| Pinned commit | *not yet pinned — recorded when the cross-compile job is added* |

## How to add a row

Resolve the object live, never from a cache or a previous note; record the full
40-character SHA; and state what the pin is FOR, so a later reader can tell
whether a bump is safe. A row that records a SHA but not its purpose cannot be
re-verified by anyone but its author.
