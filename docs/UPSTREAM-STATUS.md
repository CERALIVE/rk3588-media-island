# Upstream status — what mainline is doing to the ground under this island

**Status: scaffold.** The tracking tables are empty until the source import
lands. The policy below is not a scaffold and applies from today.

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

An `upstream-watch` workflow runs weekly against the upstream objects and the
relevant `linux-media` patchwork queries, and opens or updates **one** GitHub
issue when something moves. It closes that issue when everything is current
again.

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

## Per-subsystem status — TO BE FILLED

| Subsystem | Island driver | Mainline counterpart | Mainline status | Precondition for handing it back | Last checked |
|---|---|---|---|---|---|
| RKVENC2 encode | `mpp` (`ROCKCHIP_MPP_RKVENC2`) | none | — | | |
| RKVDEC2 decode | `mpp` (`ROCKCHIP_MPP_RKVDEC2`) | `rkvdec` (`CONFIG_VIDEO_ROCKCHIP_VDEC`) | | | |
| JPEG decode | `mpp` (`ROCKCHIP_MPP_JPGDEC`) | none | — | | |
| RGA3 #0/#1 | `multi_rga` | `rockchip-rga` (`CONFIG_VIDEO_ROCKCHIP_RGA`) | | | |
| RGA2E | `multi_rga` | `rockchip-rga` | | | |

The two RGA rows and the RKVDEC2 row are the ones with a real counterpart, and
therefore the ones the watch actually has something to report on. The two rows
with no mainline counterpart still exist, because "there is nothing upstream" is
a finding with a date on it, and an absent row reads as an oversight.

## Upstream objects watched — TO BE FILLED

| Object | What a change there would mean | Last checked |
|---|---|---|
| `yisding/rock-5b-ysp` `main` HEAD | The forward-port series moved; a rebase or a fix may be available | |
| `armbian/linux-rockchip` `rk-6.1-rkr5.1` HEAD | The vendor BSP moved; comparison material only, never an import trigger | |
| `linux-media` — RGA3 multicore postings | The reason `multi_rga` exists may be dissolving | |
| `linux-media` — `rkvdec` codec coverage | The RKVDEC2 hand-back precondition may be approaching | |

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
