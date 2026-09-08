# Rewrite comparison candidate [PARTIAL]

**measurement candidate — never shipped, never in `patches/`**

The `mpp-rewrite/` and `rga-rewrite/` directories are byte-identical snapshots of
`drivers/video/rockchip/{mpp-rewrite,rga-rewrite}/` from
[`yisding/linux-rock5b@b6335efd8f98bedabf426a80d224f85a266c8ea4`](https://github.com/yisding/linux-rock5b/commit/b6335efd8f98bedabf426a80d224f85a266c8ea4).
The source coordinate is recorded by
[`yisding/rock-5b-ysp@ca3da04280c48c004e522c15f31862bf88a2d1b9`](https://github.com/yisding/rock-5b-ysp/blob/ca3da04280c48c004e522c15f31862bf88a2d1b9/kernel-drivers/docs/rewrite-drivers.md#L1307-L1309).
Its kernel base is `v7.2-rc6`; CeraLive's target remains the independently pinned
final kernel in `kernel-pin.env`.

This import is not a working kernel port or a board result. The rewrite needs
its upstream Rockchip/VSI IOMMU provider APIs and MPP UAPI header, which are not
supplied merely by staging these two directories. Those dependencies must be
resolved in the separate comparison-only port before compilation or deployment.
Do not replace a missing provider with a successful no-op.

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
