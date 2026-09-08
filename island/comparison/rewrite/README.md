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

The [fault-injection overlay](fault-injection/README.md) is applied only **after**
that snapshot check and `port-arm64-dma.patch`. Its nine controls share the
production debugfs names plus a comparison-only `sessions` directory. Three
SHA-256 pins protect the hooks patch and two headers. `--no-fault-seam` omits
the overlay entirely; neither mode edits the frozen snapshot directories.
The required arm64-QEMU fault-suite job is separate from the module build and
does not claim the ten pre-existing upstream full-suite failures are fixed.

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

The intended measurement is OPi TEST-slot-only, with a protected production
slot, pre-reboot journals, and restoration to the island afterwards. Until that
has actually happened, neither `DID-NOT-BOOT` nor a defect reproduction verdict
may be recorded.

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
