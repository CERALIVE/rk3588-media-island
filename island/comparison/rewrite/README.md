# Rewrite comparison candidate [PARTIAL]

**measurement candidate — never shipped, never in `patches/`**

The `mpp-rewrite/` and `rga-rewrite/` directories are byte-identical snapshots of
`drivers/video/rockchip/{mpp-rewrite,rga-rewrite}/` from
[`yisding/linux-rock5b@b6335efd8f98bedabf426a80d224f85a266c8ea4`](https://github.com/yisding/linux-rock5b/commit/b6335efd8f98bedabf426a80d224f85a266c8ea4).
The source coordinate is recorded by
[`yisding/rock-5b-ysp@ca3da04280c48c004e522c15f31862bf88a2d1b9`](https://github.com/yisding/rock-5b-ysp/blob/ca3da04280c48c004e522c15f31862bf88a2d1b9/kernel-drivers/docs/rewrite-drivers.md#L1307-L1309).
Its kernel base is `v7.2-rc6`; CeraLive's target remains the independently pinned
final kernel in `kernel-pin.env`.

`scripts/port-rewrite.py` stages the comparison into a pristine, pinned final
kernel under this repository's `.work/` directory. It checks the imported file
set and bytes against the pinned upstream object, then applies the upstream
rc6-to-rewrite delta for the Rockchip/VSI IOMMU providers, DMA IOVA export and
MPP UAPI header. Those are real provider implementations, not successful
no-op stubs. The provider delta applies to final v7.2 without modifying either
imported driver. `pins.env` identifies every comparison input.

### The `fault-injection/` overlay

`fault-injection/` is the third staged input, alongside the two frozen snapshot
directories and the provider delta. It holds `hooks.patch` plus two headers —
`mpp_rewrite_fault.h` (the seam) and `mpp_rewrite_fault_test.h` (its KUnit
fixture) — and `port-rewrite.py::stage_fault_overlay()` is what applies them,
only **after** the snapshot set/byte check and `port-arm64-dma.patch`, at fuzz 0.
`run-kunit.sh` in the same directory drives the arm64-QEMU suite.

What it adds: the nine vendor fault controls, the `target_session_pid` selector
and nine `*_consumed` counters, published under the **same** debugfs names the
production seam uses, plus one comparison-only `sessions/` directory. Session
allocation fails at a validated initial `INIT_CLIENT_TYPE`, never at `open()`.

Three `pins.env` lines digest-pin the overlay and are checked before it is
staged: `FAULT_HOOKS_PATCH_SHA256` for `hooks.patch`, `FAULT_HEADER_SHA256` for
`mpp_rewrite_fault.h`, and `FAULT_TEST_HEADER_SHA256` for
`mpp_rewrite_fault_test.h`. They are live pins, not a historical record — the
value a past campaign measured against is the one written into that campaign's
own ledger tuple, and a later overlay change moves the pin without rewriting
history.

The parity gate is `scripts/check-fault-seam-parity.sh`: it compares the
overlay's debugfs and harness name sets against the production seam's, and with
`--ktap-log` additionally requires every arm64-QEMU seam case and its
production case-name counterpart. Its own `--self-test` rejects renamed knobs,
unknown consumers and incomplete, failing or skipped KTAP fixtures, and needs no
QEMU. `--no-fault-seam` omits the overlay entirely; neither mode edits the frozen
snapshot directories. The QEMU fault-suite job is separate from the module build
and does not claim the ten pre-existing upstream full-suite failures are fixed —
they stay recorded as NOT-OURS baseline debt in the
[overlay README](fault-injection/README.md).

The first strict builds exposed two linkage prerequisites: the upstream
`include/linux/iommu.h` declaration must accompany the DMA IOVA implementation,
and RGA's direct ARM64 cache-maintenance calls need module exports.
`port-arm64-dma.patch` adds only the export header and two GPL exports for the
existing implementations. It is applied solely to the disposable comparison
kernel, never to the production series. Neither missing-prototype warnings nor
unresolved modpost symbols are suppressed.

The staging tool is deliberately not a production-series generator or a board
installer. It refuses the repository root, escaping symlinks, a dirty kernel
checkout and a kernel HEAD other than the pinned final commit. It stages no
new device tree and never modifies `integration/` or `patches/` in this repo.

The comparison must select the rewrite **instead of** the island in an
`edge-test` kernel, not load competing drivers into a production kernel. The
inherited Kconfig exclusions remain byte-identical. No production client,
device-tree file, integration patch, generated series or image pin is changed
by this snapshot. JPEG decode is outside the rewrite's feature set; source
presence of other upstream execution paths is not a claim that CeraLive enables
or qualifies them.

`scripts/check-rewrite-exclusion.sh` independently rejects comparison targets
in the generated mailbox. Its self-test runs the real generator before and
after adding comparison source and requires byte-identical production output;
injected rewrite paths must be rejected. The `series-integrity` CI job runs
both checks, alongside regeneration and the existing independent parity check.

## The measurement — it RAN, on 2026-09-09

The comparison was OPi TEST-slot-only, with production slot B protected
throughout, pre-reboot journals captured, and restoration to the island verified
afterwards. That is what happened, and these are the coordinates it happened on:

```text
board                    Xunlong Orange Pi 5 Plus, test slot A (production slot B untouched)
kernel                   7.2.0-ceralive-rk3588-test #ceralive1+test1
bundle                   20260909T011811Z.raucb
ISLAND_FIX               6e0ce7f79f95eb62acab2542e6f699632750dd03
PATCHES_TEST             09eca4bdb9a846d2ee8fa1be938dbe681fd44e1e
BENCH_SHA                6f94b9c64e89d052e1dc4d36bebdf625d85b6aa2
REWRITE_COMMIT           b6335efd8f98bedabf426a80d224f85a266c8ea4
FAULT_HOOKS_PATCH_SHA256 d1f47bec849e5de0e5e69e50a729a0fc1c65b21ea0710d3036a8d95acec5b726
island tag (comparison)  v2026.9.2 (1fd357d8a8b83b6f4ed7f7692d761f7b653d44f5)
```

The candidate BOOTED, so `DID-NOT-BOOT` was never recorded: `rockchip_mpp_rewrite`
bound with `rk_vcodec` absent, `/sys/kernel/debug/rk_mpp_rewrite` was present, and
`/sys/kernel/debug/rkvenc-test` published exactly the nineteen contract entries
plus the rewrite-only `sessions/` directory. Row 0's smoke encode PASSED on both
passes, so no cell is `GAP:uapi-or-userspace`.

Sixteen matrix cells and five control cells were measured and are recorded with
their causes in the root ledger's
[phase-3 comparison](https://github.com/CERALIVE/ceralive/blob/docs/media-island-ledger-evidence/docs/media-island/ledger/phase3-comparison.md).
**A rewrite FAIL there is a comparison datum only** — not a defect claim about the
island, not an upstream report, not a design conclusion. The one unambiguous
parity result is that the four matrix-armed controls fire on the rewrite exactly
as they do on the island, on the same rows, by exactly +1, with identical
end-of-campaign totals. The remaining five controls are unproven on the rewrite;
that is what their `GAP` cells say, and no defect-reproduction verdict is
recorded for any of them.

## Compile-only gate

`cross-compile-rewrite` shares the pristine pinned-kernel cache, uses ccache,
and works in a separate disposable checkout. `scripts/build-rewrite.sh` merges
the device's edge and edge-test fragments at one pinned image commit, then
selects rewrite MPP/RGA instead of the three competing production drivers. It
requires KASAN and lockdep, links the real built-in and modular IOMMU providers,
and builds both modules with `-Werror` and pinned sparse `-Wsparse-error`.
The checker-valid probe fails closed if sparse cannot parse this kernel.

The gate's artifacts are `rockchip-mpp-rewrite.ko` and
`rockchip-rga-rewrite.ko`. A successful compile is not a bootable device image:
the comparison candidate still needs the non-media platform patches, the
existing board DT ownership hunks, a sealed slot payload and its RAUC safety
receipts before any board result may be claimed.
