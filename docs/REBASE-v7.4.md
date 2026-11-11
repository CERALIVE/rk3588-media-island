# Rebase ledger: island `v7.2` to `v7.4-rc2`

This is the island's first kernel-bump ledger. It records what moving the
nine-member series from Linux `v7.2` to the `v7.4-rc2` candidate changed, why,
and what is still unproven. The work lives on `release/linux-7.4`. Island
`main` stays on `v7.2` and keeps releasing for production until cutover.

Recorded 2026-11-11. **No board validation is claimed.** Nothing in this file is
a compile, CI or hardware result unless it names the receipt that proves it, and
the full-series compile, the green gate run and the 7.4-line release are still
pending (see [Proof boundary](#proof-boundary)).

## Base coordinates

The four `KERNEL_*` values are mirrored from the consumer, never decided here.
`pin-equality` compares them with
[`rk3588-kernel-patches` `rebase/v7.4`](https://github.com/CERALIVE/rk3588-kernel-patches/blob/rebase/v7.4/kernel-pin.env),
selected by `CONSUMER_PIN_REF` in [`../kernel-pin.env`](../kernel-pin.env).

| Field | Previous base (`main`) | This base (`release/linux-7.4`) |
|---|---|---|
| `KERNEL_TAG` | `v7.2` | `v7.4-rc2` |
| `KERNEL_TAG_OBJECT` | `237a1c39e8dfd3e1c6f1f023eea37a48ec04cc63` | `fd9230005e85472b81c1c7c16afe93dd878996b1` (tagged 2026-11-08) |
| `KERNEL_COMMIT` | `8d3ae59288f1e7d58d76558a6ee96d533bc5019f` | `7475ea8b58616b33c04afb976cf0fbaad9dd63fb` |
| `KERNEL_MIRROR` | `https://github.com/gregkh/linux.git` | `https://github.com/torvalds/linux.git` |
| Consumer pin source | `main` | `rebase/v7.4` |
| Island base | `63609f578ea1c1b7c10e2ae39664ca2f639a94b3` (latest release `v2026.9.5`) | branched from that commit |

`$K` is frozen at `v7.4-rc2` for this branch. A newer rc or `v7.4` final is a
deliberate refresh through the consumer's rc-to-final procedure, never a quiet
bump here.

## Member table

Each member was applied with plain `git am`, in series order, to a pristine
`v7.4-rc2` tree (`HEAD` asserted equal to `7475ea8b5861`). **Pre** is the
series generated on island `main` (the `v2026.9.5` tree). A failing pre member
was skipped and the probe continued, so later members were still tried on top
of the ones that applied. **Post** is the series generated on this branch.

| Member | Pre (`main` series) | Post (this branch) | Change |
|---|---|---|---|
| `0001-rk3588-media-island-drivers.patch` | applies | applies | none |
| `0002-video-rockchip-kconfig-makefile-hooks.patch` | applies | applies | none |
| `0003-iommu-rockchip-export-for-mpp.patch` | **fails** at `drivers/iommu/rockchip-iommu.c:129` | applies | context re-anchor of `integration/0002` |
| `0004-iommu-dma-expose-iova-domain.patch` | applies | applies | none |
| `0005-arm64-dts-rk3588-mpp-encoder-nodes.patch` | applies | applies | none |
| `0006-arm64-dts-rk3588-mpp-decoder-nodes.patch` | applies | applies | none |
| `0007-arm64-dts-rk3588-mpp-jpegd-node.patch` | applies | applies | none |
| `0008-arm64-dts-rk3588-rga3-vendor-compat.patch` | applies | applies | none |
| `0009-arm64-dts-rk3588-rga2-vendor-compat.patch` | applies | applies | none |

Pre 0004 to 0009 were probed without 0003 underneath them. That is enough to
show that only 0003 needed work, and not a claim that the old series builds.

On this branch `python3 scripts/build-series.py --check` and
`python3 scripts/verify-series-parity.py` pass: nine mailboxes reconstruct 87
island source files and carry eight integration payloads verbatim. `drivers/`
and `include/uapi/` are unchanged from `main`, so `rk-mpp.h`, the device nodes,
the heap name and every ioctl value are the ones userspace already uses.

## `integration/0002` re-anchor

`integration/0002-iommu-rockchip-export-for-mpp.patch` was rebuilt from a
`git apply --3way` merge on top of generated 0001 and 0002, diffed against
pristine `v7.4-rc2` over the same two files. All 23 hunks keep their order and
every added and removed line byte for byte. Only context moved.

Why it moved: the v7.3 Rockchip IOMMU rework made the operations table
per instance (`414cb6f3ac6217d67963d53866e0fc2288dd3556`), took all DT clocks
for the MMU (`841363ebb5082a06c69ac34719e26659fe63dbd6`), acknowledges stale
faults before stalling (`b10d5920cafa292ee3cab9c20f813da4fe4f00b8`) and fails
probe when no MMU resource maps (`ea0a9d453f60d5d065c377bbd20ab8a78b8620b7`).
v7.4 then converted allocations to `devm_kzalloc_obj()`
(`4dd10fbbeb9c33709edc89916e19c03c780a0751`). A single patch that applies to
both bases is impossible: the `rk_iommu_map` change sits next to upstream's
rewritten `pte_dma = ...rk_ops->pt_address(...)` line.

| Hunk | `v7.2` range | `v7.4-rc2` range | Context change |
|---|---|---|---|
| 1 | `-27,6 +27,8` | `-27,6 +27,8` | none |
| 2 | `-116,6 +118,10` | `-112,6 +114,10` | offsets only |
| 3 | `-129,6 +135,9` | `-125,6 +131,9` | upstream removed the global `rk_ops` declaration; its old context line is now blank |
| 4 to 10 | | | offsets only (IRQ loop, fault dispatch, zap, flush, map and unmap bounds, mapped-byte count) |
| 11 | `-805,13 +875,13` | `-814,13 +884,13` | `rk_ops->pt_address(...)` becomes `rk_domain->rk_ops->pt_address(...)` |
| 12 | `-828,6 +898,7` | `-837,6 +907,7` | offsets only |
| 13 | `-853,11 +924,10` | `-862,11 +933,10` | `pte_dma = rk_ops->...` gains `rk_domain->` |
| 14 | `-868,6 +938,7` | `-877,6 +947,7` | offsets only |
| 15 | `-892,7 +963,8` | `-901,7 +972,8` | `pt_phys = rk_ops->pt_address(dte)` becomes `rk_domain->rk_ops->...` |
| 16 to 21 | | | offsets only (provider callback, disable/enable state, device link and segment limit, release, operations table and exports) |
| 22 | `-1218,6 +1622,7` | `-1231,6 +1635,7` | `ops = of_device_get_match_data(dev)` becomes `iommu->rk_ops = ...`; `if (!rk_ops)` becomes `if (!iommu->rk_ops)` |
| 23 | `-0,0 +1,87` | `-0,0 +1,87` | added `include/soc/rockchip/rockchip_iommu.h`, unchanged |

Prose and metadata, not payload:

- The header sentence now reads "re-anchored to the v7.4-rc2 candidate tree"
  instead of "the pinned v7.2 tree".
- The provider file index moved from `87ae036d6414..3b920aeb17f8` to
  `1fa3110b142a..f204a7e422ac`. The new header's index and contents are unchanged.

Upstream behaviour the re-anchor keeps: per-instance and per-domain operations
pointers with no global `rk_ops`; `rk_iommu_attach_device()` still rejects a
domain whose operations differ from the device's with `-EINVAL`; probe still
uses `devm_clk_bulk_get_all()` and still returns `-ENODEV` when no MMU resource
maps; the `devm_kzalloc_obj()` allocations stay as upstream wrote them.

The other integration patches (`0001`, `0003`, `0010` to `0012`, `0020`,
`0021`) apply to `v7.4-rc2` unchanged.

## Behaviour audit of the 7.3/7.4 upstream changes

Compile-green is not behaviour-green, so every upstream change on a path the
island consumes was read at `v7.4-rc2` against the island call sites. This is a
source audit. It ran no build, no KUnit and no board command.

| Row | Upstream change | Island exposure | Finding at `v7.4-rc2` | Disposition |
|---|---|---|---|---|
| a | `b10d5920cafa292ee3cab9c20f813da4fe4f00b8`, acknowledge `PAGE_FAULT_ACTIVE` before enabling stall | `rockchip_iommu_enable` and the force-reset helpers (`mpp/mpp_iommu.c`, `mpp/mpp_rkvdec2.c`), the fault path in `integration/0002` | The ACK checks `PAGE_FAULT_ACTIVE` alone, not `INT_MASK`, `IDLE` or a task token. No source path was found where it eats a new owner's fault on the normal RK3588 admission path, but MMIO latching, bank races and failed-reset timing can't be settled from source. | **needs-board-proof** |
| b | `1c8f6308e557f32412e9d4678b3f029f47f6d9aa`, scatterlist length overflow | single-span MPP imports, RGA addressability checks | Impossible padded mappings now fail cleanly as `-EINVAL` instead of wrapping. Valid frame imports keep their contract and the importers already unwind on error. | neutral |
| c | `1acce29926d93f3eba427696fe3da6451504dae2`, `641a9b9cc697eb6ea375a25aafc6884d1b485612`, `95d2fec40c483d8a63e5ffa0fa88faeb2e0ed462`, `1ae140d0f27248fc588f2f3baa9940512ee078f1` | IOVA and coherent allocation in MPP and RGA | The island calls none of the changed helpers. Its coherent owners free the same page-aligned size they allocate. `iommu_dma_get_iova_domain` stays distinct from `iommu_get_dma_domain`. | neutral |
| d | v7.3/v7.4 workqueue rework | ordered and single-thread queues in MPP and RGA | Ordered queues keep `max_active` 1 and the rescuer. The two explicitly allocated queues belong to clients disabled by `BROKEN`. No private workqueue state is read. | neutral |
| e | `4c66c423593e26273ea0d644906ed007630c6f6d`, power-domain attach fails on non-`ENOENT` clock errors | clocks on island DT nodes from `integration/0010` to `0012`, `0020`, `0021` | Both board DTBs, built standalone from `v7.4-rc2` plus the five island DT patches, resolve all 42 clock specifiers per board to real CRU clocks. | neutral |
| f | dma-buf rc2 fixes `6ce0c151d52f6741b6c04569e1886bc7837faa5d`, `e87fd0513792a5cf90f502399faa9e19439747e6`, `052947a3b5e7402eaad53379dfec2ecab27a2d80`, `d57e3a7d880d783c64aa29457d78b0e3c5a40e3c` | MPP and RGA dma-buf import | These are exporter MMIO/P2P helpers with no island caller. Normal system-heap imports are unchanged. | neutral |
| g | `841363ebb5082a06c69ac34719e26659fe63dbd6`, MMU takes all DT clocks | the seven MMUs the island consumes | Every one still lists exactly `aclk` and `iface`, so all-clocks acquisition picks the same two clocks. | neutral |
| h | `414cb6f3ac6217d67963d53866e0fc2288dd3556`, per-instance `rk_ops` | provider map/unmap, reset/enable and shared-domain attach | All seven MMUs select the same rk3568-compatible v2 operations, so homogeneous shared-domain binds keep one page format, and the mismatch guard stays. Handled by the re-anchor above. | neutral |
| i | `ea0a9d453f60d5d065c377bbd20ab8a78b8620b7`, probe fails with no MMU resource | provider registration that MPP and RGA attach to | An unusable provider is no longer published. Both board DTBs give all seven MMUs nonzero register windows. | neutral |

### Row a: the stale-fault acknowledgement stays open

The island reports a fault and then deliberately keeps it latched while masked:
`integration/0002` sends `PAGE_FAULT_DONE` only when the callback left
`INT_MASK` nonzero, and `rockchip_iommu_unmask_irq` acknowledges later. The new
upstream ACK in `rk_iommu_enable_stall()` doesn't look at any of that. On the
normal RK3588 path the reset runs before the IOMMU refresh, and the direct
force-reset callers in `mpp_rkvdec2.c` belong to other SoCs' reset operations,
so no concrete loss of attribution was found. That isn't proof that real bank
latching or a failed reset is safe, and no driver change is proposed.

Board rows that must pass on both the ROCK 5B+ and the Orange Pi 5 Plus at
cutover:

- `tests/board/fault-matrix.sh`, island driver, rows `iommu-fault`,
  `irq-timeout`, `hardware-hang`, `reset-failure`, `teardown-active`;
- `tests/board/fault-controls-probe.sh --row idle-iommu-fault`;
- consumer
  [`docs/BOARD-QUALIFICATION.md`](https://github.com/CERALIVE/rk3588-kernel-patches/blob/rebase/v7.4/docs/BOARD-QUALIFICATION.md)
  section 7 (especially 7a and 7b) and section 10a (especially 10a-2).

Those rows call the fault callback directly, so they can't show
`PAGE_FAULT_ACTIVE`/`INT_RAWSTAT`/`INT_CLEAR` causality in hardware. A real
provider fault and ACK trace (stale before prepare, fault after START and
before commit, mask-to-timeout recovery, failed reset) has no harness row yet.
That gap is recorded here, not papered over with a new row.

### Host tests

None were added. The island's host seams cover request shapes, policy
arithmetic, mapping wrappers, lifetime state and synthetic provider operations.
None of them executes `iommu_dma_map_sg`, the MMIO bank ACK sequence, clock
lookup, the phys-vector exporter helpers or workqueue internals, so a new test
for rows b, c or f would test a model, not the changed kernel code.

## Linux 7.5 watch list

Not tasks, just things to look at on the next bump:

- `devm_kzalloc` call sites, as the treewide `devm_kmalloc_obj` conversion
  spreads. Don't rewrite island code just for the spelling.
- `SET_RUNTIME_PM_OPS` / `SET_SYSTEM_SLEEP_PM_OPS` migration in the MPP and RGA
  PM tables. Keep the callbacks, PM balancing and fixed-clock contracts.
- Removal of `create_singlethread_workqueue`. Its one island user is the
  `BROKEN`-disabled legacy `mpp_rkvenc` client. If it goes, keep ordering and
  reclaim progress on purpose.

## Compile and CI receipts

This ledger records no compile result and no green CI run yet.

- The full kernel compile with this branch's series substituted into the
  consumer series is pending.
- The island gate run (every `ci.yml` job locally, then a green GitHub `ci` run
  at the pushed head) is pending. Its run URL is added here when it lands.
- Earlier pushes to this branch, kept for traceability: `ci` run
  [42971229300](https://github.com/CERALIVE/rk3588-media-island/actions/runs/42971229300)
  at `b4d430db10a1` and
  [42974784069](https://github.com/CERALIVE/rk3588-media-island/actions/runs/42974784069)
  at `8e8fe11f4206` both concluded **failure**. In the second, `shellcheck`
  reported SC2329 at `tests/board/fault-matrix.sh:715`, a file this branch
  doesn't touch, and `static analysis` failed while installing its
  dependencies. Neither is a pass.

## Release flow on this branch

On this branch only, `release.yml` releases from `refs/heads/release/linux-7.4`
and nothing else. This is a dated owner exception (2026-11-10). The ref decision
lives in `scripts/check-release-ref.sh`, with a self-test. Both the draft
creation and the publication carry `--latest=false`, so a 7.4-line release can
never become "Latest" over the 7.2 line. A main-merge guard in
`.github/workflows/release-ref.yml` fails a push to `main` or a PR targeting
`main` unless the script accepts exactly `refs/heads/main`.

At cutover, revert to main-only or keep the flow deliberately. The reverting PR
must either keep `scripts/check-release-ref.sh` accepting exactly
`refs/heads/main` (updating its self-test expectations), or remove the guard
together with the script and its CI and release self-test calls. Removing the
script alone breaks the guard. The same PR restores `CONSUMER_PIN_REF="main"`,
which `scripts/check-pin-source-ref.sh` requires on `main`.

The 7.4-line island release itself is not published. It needs the owner's
explicit go-ahead.

## Cutover and the 7.2 policy

The cutover runbook, the rc-to-final refresh, the deferred 7.2 policy and the
downstream inventory live in the consumer's ledger,
[`docs/REBASE-v7.4-rc2.md` on `rebase/v7.4`](https://github.com/CERALIVE/rk3588-kernel-patches/blob/rebase/v7.4/docs/REBASE-v7.4-rc2.md).
That file is keyed to the kernel tag, so an rc refresh renames it (to
`docs/REBASE-v7.4.md` at `v7.4` final). Until cutover, island `main` stays
releasable for emergency 7.2 fixes.

## Proof boundary

Done and evidenced: the re-anchor, the member probe above, the pin mirror and
consumer-ref selector, the branch-scoped release flow, the source audit.

Pending:

- the full-series kernel compile on `v7.4-rc2`;
- the island gate run, local and on GitHub, at a green head;
- the 7.4-line island release (owner-gated);
- two-board qualification at cutover, including row a above.

No board validation is claimed. The row a acknowledgement stays
needs-board-proof.
