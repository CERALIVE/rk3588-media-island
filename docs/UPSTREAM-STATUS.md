# Upstream status — what mainline is doing to the ground under this island

**Status: vendor backlog current through 2026-09-02; the pinned Linux 7.2
hand-back baseline was checked on 2026-09-03.** The vendor media-path watch is
live. Hardware acceptance remains a later board-gate concern; the table below
records the source-level migration baseline, not a claim that any island release
has run on a board.

## What this document is for

The island exists because mainline does not yet drive this silicon the way
CeraLive needs it driven. That is a statement about a moving target. Mainline
gains RGA3 multicore support, or `rkvdec` grows the codecs the island's decoder
covers, and a driver here stops earning its keep — but nobody notices unless
somebody is watching and writing it down.

So this file holds one row per island-owned subsystem, recording what mainline
currently offers, what would have to be true before the island could hand that
silicon back, and **the date that was last verified**. A status with a stale date
is not a check; it is a memory.

## The watch is issue-only

An `upstream-watch` workflow runs weekly against Rockchip `develop-6.1` and the
two current Armbian vendor mirrors. It reports a branch only when a commit after
the reviewed cursor touches one of the exact MPP, RGA3, or rk-mpp UAPI paths,
and opens or updates **one** GitHub issue. It closes that issue when those paths
are current again.

It never edits a pin. It never edits this file. It never dispatches a build. A
human reads the issue and decides. That restriction is deliberate: an
auto-bumping watch would silently move the ground the whole series is anchored
to, which is precisely the failure this repository's pinning discipline exists to
prevent.

## Handing silicon back is a device-tree change, not a deletion

This is the part that surprises people, so it is stated before the tables.

Mainline `rkvdec` and `rockchip-rga` stay **BUILT** in the image alongside the
island. They match no node, because every island-owned node carries exactly one
`compatible` string and it is the island's. Migrating a block back to mainline is
therefore a one-line `compatible` flip in an `integration/` device-tree hunk — no
kernel reconfiguration, no rebuild of the module set, and a rollback that is the
same one line in reverse. See [`OWNERSHIP.md`](OWNERSHIP.md) for the mechanism.

That is why the migration targets below are live options rather than aspirations.

## Per-subsystem status

| Subsystem | Island driver | Mainline counterpart | Mainline status | Precondition for handing it back | Last checked |
|---|---|---|---|---|---|
| RKVENC2 encode | `mpp` (`ROCKCHIP_MPP_RKVENC2`) | none | Linux 7.2 has no in-tree RK3588 VEPU580 encoder counterpart; the existing board encoder path is the prior Rockchip-ported service, not a mainline driver. | A maintained in-tree RK3588 encoder must bind the VEPU580 nodes and pass the island's H.265-first H.264/H.265 control, recovery and board qualification matrix. | 2026-09-03 |
| RKVDEC2 decode | `mpp` (`ROCKCHIP_MPP_RKVDEC2`) | `rkvdec` (`CONFIG_VIDEO_ROCKCHIP_VDEC`) | Linux 7.2 contains an in-tree driver matching `rockchip,rk3588-vdec`; it stays built as the migration target, but the release-1 DT hunk gives `vdec0/1` the sole island compatible. | The mainline path must meet the RKVDEC2 H.264/H.265/VP9 capability and recovery evidence, then pass the same board decode and zero-copy matrix before a compatible flip. | 2026-09-03 |
| JPEG decode | `mpp` (`ROCKCHIP_MPP_JPGDEC`) | none | Linux 7.2 has no in-tree RK3588 `jpegd` counterpart. | A maintained mainline JPEG-decoder driver must bind `jpegd` and pass the MJPEG decode, DMA-BUF and recovery qualification rows. | 2026-09-03 |
| RGA3 #0/#1 | `multi_rga` | `rockchip-rga` (`CONFIG_VIDEO_ROCKCHIP_RGA`) | Linux 7.2's `rockchip-rga` matches `rockchip,rk3588-rga3`; the Phase-0 board probe found core0 bound while core1 was skipped for missing multi-core support. The island's RGA handover is still pending. | Mainline must bind both RGA3 cores and demonstrate scheduling, operation coverage and the required userspace/DMA-BUF interface on the board matrix. | 2026-09-03 |
| RGA2E | `multi_rga` | `rockchip-rga` | Linux 7.2's `rockchip-rga` owns the mainline RGA2 node today; no island RGA compatible is applied in release 1. | Mainline must meet the combined RGA2/RGA3 scheduler, fail-closed validation and `/dev/rga` userspace-interface requirements before the pending island handover could be reversed. | 2026-09-03 |

The two RGA rows and the RKVDEC2 row are the ones with a real counterpart, and
therefore the ones the watch actually has something to report on. The two rows
with no mainline counterpart still exist, because "there is nothing upstream" is
a finding with a date on it, and an absent row reads as an oversight.

The source checks above are deliberately narrower than the later hardware gates:
they establish that the in-tree Kconfig entries and compatible matches exist (or
do not), while the qualification matrix decides whether a compatible flip is
safe. No row here claims an island tag, image, or board deployment.

## Vendor objects watched

| Object | What a change there would mean | Last checked |
|---|---|---|
| `rockchip-linux/kernel` `develop-6.1` after `77168c8d5ab8` | A new vendor media commit needs the same PICK/SKIP classification as `VENDOR-BACKLOG.md` | 2026-09-02 |
| `armbian/linux-rockchip` `rk-6.1-rkr6.1` after `82c6b3ef1c93` | Comparison mirror only; may expose a vendor fix or a downstream revert | 2026-09-02 |
| `armbian/linux-rockchip` `rk-6.1-rkr7.2` after `057c0edb6f11` | Comparison mirror only; currently carries the `logic_clk_on` revert cited by the backlog | 2026-09-02 |

All three rows use exactly `drivers/video/rockchip/mpp/`,
`drivers/video/rockchip/rga3/`, and `include/uapi/linux/rk-mpp.h`. The yisding
97-member series is immutable import provenance, not a moving watch target.

## Rules for editing this file

- Never change a status without also changing its **Last checked** date. The two
  move together or the row is worse than useless.
- Record lore references as `https://lore.kernel.org/r/<message-id>`, which
  resolves regardless of which list carried the posting. Never a list-scoped URL.
- "A patch still applies" proves nothing about whether it is still needed.
  Mainline may have fixed the same defect by a different mechanism; only a content
  check answers that.
- A precondition is a precondition, not a licence to delete. When one fires, the
  hand-back still goes through a device-tree change, a board drill and a release.
