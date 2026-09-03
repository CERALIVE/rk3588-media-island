# Vendor backlog — `develop-6.1` after the imported donor

**Status: audited through `rockchip-linux/kernel@77168c8d5ab82399f65a80e9f807b50ba37cf483`.**

The imported source starts at
`b4ef083dc0c3608e744deabb43dc6b781aadbe6e`. This ledger classifies every later
commit on Rockchip's `develop-6.1` branch that touches exactly:

- `drivers/video/rockchip/mpp/`
- `drivers/video/rockchip/rga3/`
- `include/uapi/linux/rk-mpp.h`

`scripts/vendor-backlog.sh --check` repeats that path query, computes stable
patch IDs for all candidates and all 97 yisding members, and fails if this table
omits, duplicates, reorders, or leaves a candidate without a decision. Dates are
author dates, matching the required `git log` output; merge order, not date sort,
defines the table order.

## Complete classification

| SHA | Date | Subject | Class | RK3588-relevant | Already in yisding series | ABI impact | Decision |
|---|---|---|---|---|---|---|---|
| `e6c60675cbda8fac0329011cef209169a7d764e7` | 2025-12-31 | Merge tag `v6.1.157` | CLEANUP | n — branch-wide merge, not an isolated media fix | — | merge contains the existing UAPI baseline only | SKIP:COSMETIC/UNRELATED — merge container, never a selectable fix |
| `b397ef1eb49088f190b3fb39fc0447cc0140dace` | 2026-01-05 | video: rockchip: mpp: vdpp: Fix zme reg offset for rk3538 | BUGFIX | n — RK3538 VDPP, which is uncompiled | — | none | SKIP:NOT-RK3588-RELEVANT — different SoC and disabled client |
| `916e3ff57cdc34635e6e476883964360f0d53b76` | 2025-12-30 | video: rockchip: rga3: Fix page fault caused by IOMMU prefetch | BUGFIX | y — RGA2 IOMMU programming | fwport-0022 (`57bd73b9`), equivalent fix | none | SKIP:ALREADY-COVERED-BY-YISDING — imported by fwport-0022 |
| `0fd948591961a2ac3b889aafab17a1efc6ea178e` | 2025-12-30 | video: rockchip: rga3: Avoid lockdep warning using unlocked map helpers | HARDENING | y — RGA DMA-BUF/debug mappings | fwport-0014 (`48434c72`), equivalent unlocked vmap/vunmap calls | none | SKIP:ALREADY-COVERED-BY-YISDING — imported by fwport-0014 |
| `abb155f597c5e261f048b56b6ffea94cb0390ef0` | 2025-10-23 | video: rockchip: rga3: fix out-of-tree module build | BUGFIX | n — obsolete Kbuild spelling, not silicon behavior | — | none | SKIP:COSMETIC/UNRELATED — pinned 7.2 already requires and uses `-I$(src)/include` |
| `5fd8e4bcfdedf363a2104de99f3a91868d18ac9b` | 2026-01-12 | video: rockchip: rga3: adapt to `$(src)` semantics change | BUGFIX | n — compatibility for kernels before 6.10 | — | none | SKIP:COSMETIC/UNRELATED — the island targets only 7.2 and carries the native 7.2 form |
| `374aa7ef9ac6ea80443cf24e367b7204be4c3467` | 2026-01-26 | video: rockchip: rga3: Fix bi-linear scale-down coefficient check error | BUGFIX | y — RGA2 scaling validation | fwport-0027 (`b52dfe45`), patch-ID match | none | SKIP:ALREADY-COVERED-BY-YISDING — imported by fwport-0027 |
| `d40d554273657603915b59e7e580a2234d7264c3` | 2026-01-21 | video: rockchip: rga3: Add protection when scale up | HARDENING | y — RGA request validation | fwport-0028 (`40480670`), patch-ID match | none | SKIP:ALREADY-COVERED-BY-YISDING — imported by fwport-0028 |
| `7a5c44fd100d47d6e6dbee6d6b755acead2b7958` | 2026-01-30 | video: rockchip: mpp: Remove unused log | CLEANUP | n — uncompiled JPGENC | — | none | SKIP:COSMETIC/UNRELATED — diagnostic cleanup in a disabled client |
| `db74ba36500bf2863fb3f821d169b8546f75a0f7` | 2026-04-02 | video: rockchip: mpp: vdpu384b: use MMU v2.0 only on RK3538 | BUGFIX | n — RK3538 VDPU384B | — | none | SKIP:NOT-RK3588-RELEVANT — RK3588 uses VDPU381 |
| `90eefde08d7db6c3906f6b490148b794fa6385bd` | 2026-05-29 | video: rockchip: mpp: fix vepu510 spurious wdg timeout after page fault | BUGFIX | n — VEPU510 | — | none | SKIP:NOT-RK3588-RELEVANT — RK3588 encode is VEPU580 |
| `67621e9347544a621d02f23cfefcfff80431f724` | 2025-08-18 | video: rockchip: rga3: src1 support AFBC32x8 | FEATURE | n — forbidden AFBC format | — | none | SKIP:FEATURE-USERSPACE-NEVER-SENDS — CeraLive forbids AFBC/10-bit |
| `af2d9ce950d0a3656f7e378b9bf99dfda44f45b8` | 2025-08-21 | video: rockchip: rga3: Support non-block alignment overlay for FBC | FEATURE | n — forbidden FBC/AFBC format | — | none | SKIP:FEATURE-USERSPACE-NEVER-SENDS — unsupported format family |
| `15d2b838eed290dcf4b1d707d27e948548018a81` | 2025-10-10 | video: rockchip: rga3: enable config_intr and get parse error status | HARDENING | y — RGA interrupt/error reporting | fwport-0029 (`ba1c60c3`), equivalent fix | none | SKIP:ALREADY-COVERED-BY-YISDING — imported by fwport-0029 |
| `391d769fb33612fac3a84aae9a12ed1f79219628` | 2025-09-04 | video: rockchip: rga3: add RGA_FORMAT_Y1 support | FEATURE | n — unused format | — | internal format enum only | SKIP:FEATURE-USERSPACE-NEVER-SENDS — pinned userspace does not request Y1 |
| `475afd9e8f046bb88f472981721c4577b6ea820f` | 2025-10-13 | video: rockchip: rga3: Fix incorrect check in update_LUT mode | BUGFIX | y — RGA2 validation | fwport-0030 (`0b6cec4c`), patch-ID match | none | SKIP:ALREADY-COVERED-BY-YISDING — imported by fwport-0030 |
| `ed85f62567293c1eaa50f9d8f729f400df749037` | 2025-09-04 | video: rockchip: rga3: Support RKCFA | FEATURE | n — unused CFA path | — | internal feature/request expansion | SKIP:FEATURE-USERSPACE-NEVER-SENDS — pinned userspace does not request RKCFA |
| `340d56559e501b8e5f6372233f13259bda571bd0` | 2025-11-25 | video: rockchip: rga3: Support RK3572 | FEATURE | n — RK3572 | — | internal hardware table expansion | SKIP:NOT-RK3588-RELEVANT — different SoC |
| `62c229ffea79a5024cdf2ad6840a8d82b2a2dc1b` | 2026-01-29 | video: rockchip: rga3: Fix global variable missing static modification | CLEANUP | y — shared hardware tables, no behavior change | fwport-0031 (`ad396ad8`), equivalent fix | none | SKIP:ALREADY-COVERED-BY-YISDING — imported by fwport-0031 |
| `ca9719017f4f931371a37746f5ee3b4020dfa931` | 2026-02-10 | video: rockchip: rga3: fix out-of-bounds access in slave mode register config | HARDENING | y — RGA2/RGA3 command writes | fwport-0018 (`ca65e4dd`), semantic match; patch IDs differ | none | SKIP:ALREADY-COVERED-BY-YISDING — fwport-0018 introduced strict `i < cmd_reg_size` bounds; remaining donor changes name debug-dump sizes |
| `08764fe77bd738441991899fc2ccfef0c3e23074` | 2026-03-03 | video: rockchip: rga3: fix incorrect output when only src1 AFBC32x8 enable | BUGFIX | n — forbidden AFBC format | — | none | SKIP:FEATURE-USERSPACE-NEVER-SENDS — unreachable in the supported format set |
| `0e59668fa8a9a2014a8c7d02aef4c47bd9e5bd32` | 2026-03-03 | video: rockchip: rga3: set tile4x4 input base1 to 0 | BUGFIX | y — RGA2 tile register programming | fwport-0032 (`da3b5d42`), equivalent fix | none | SKIP:ALREADY-COVERED-BY-YISDING — imported by fwport-0032 |
| `964583e4b38bb0d0ab8ccb0068133ff06b471890` | 2026-03-16 | video: rockchip: rga3: fix typo in rga_alloc_virt_addr() | CLEANUP | n — message text only | — | none | SKIP:COSMETIC/UNRELATED — diagnostic typo |
| `54d2caaae7ae90b8a77c19041203165adf19a4f4` | 2026-03-16 | video: rockchip: rga3: fix return value of rga_mm_lookup_iova() when error | BUGFIX | y — RGA IOMMU error propagation | fwport-0026 (`61719882`), patch-ID match | none | SKIP:ALREADY-COVERED-BY-YISDING — imported by fwport-0026 |
| `aacc133b3c3983f1e28402e15118cac774c106af` | 2026-03-12 | video: rockchip: rga3: check nents return by dma_map_sg | HARDENING | y — RGA DMA mapping | fwport-0080 (`e3e17b55`), stronger mapped-SG contract | none | SKIP:ALREADY-COVERED-BY-YISDING — fwport-0080 validates mapped adjacency and lengths using DMA nents |
| `bf1160ba6a9a529bc7bda75da2e768efa91368de` | 2026-03-13 | video: rockchip: rga3: add shadow_page for cacheline unaligned virt addr | HARDENING | y — RGA USERPTR mapping | fwport-0023 (`610c5852`), equivalent fix | internal structure only | SKIP:ALREADY-COVERED-BY-YISDING — imported by fwport-0023 |
| `d86f268890855965d77fdf0ad69f0bc3034ca41f` | 2026-03-17 | video: rockchip: rga3: fix cacheline unaligned virtual address access fault | BUGFIX | y — RGA USERPTR mapping | fwport-0024 (`9b6e3ad8`), patch-ID match | none | SKIP:ALREADY-COVERED-BY-YISDING — imported by fwport-0024 |
| `e839f5d7782601419de7a93a7abed99bcde5a677` | 2026-04-02 | video: rockchip: rga3: fix request leak when multi task submit failed | BUGFIX | y — RGA scheduler lifetime | fwport-0020 (`954ef17e`), patch-ID match | none | SKIP:ALREADY-COVERED-BY-YISDING — imported by fwport-0020 |
| `79b708060e89faf15f0356cb0844d13852cbc4ce` | 2026-04-08 | video: rockchip: rga3: support hardware batching | FEATURE | y — compiled RGA path | fwport-0018 (`ca65e4dd`), forward-ported batching | request/control expansion | SKIP:ALREADY-COVERED-BY-YISDING — imported and adapted by fwport-0018 |
| `fb7e267a6da1131cf0658395f8f39345f400ee28` | 2026-04-09 | video: rockchip: rga3: fix RGA2/RGA3 slave_mode execution failure after master_mode | BUGFIX | y — RGA mode transition | fwport-0019 (`43b0e515`), equivalent fix | none | SKIP:ALREADY-COVERED-BY-YISDING — imported by fwport-0019 |
| `483de83e7fdcaacefae01ed357d137cc61721b34` | 2026-03-20 | video: rockchip: rga3: fix submit failed when acquire fence is signaled | BUGFIX | y — RGA fence lifetime | fwport-0021 (`2fe97b54`), patch-ID match | none | SKIP:ALREADY-COVERED-BY-YISDING — imported by fwport-0021 |
| `08f3f5e09df691f3a4b3c6d82d41309f8f5bb45b` | 2026-03-09 | video: rockchip: rga3: fix the output_params should be reverted when rotate 90 or 270 | BUGFIX | y — RGA rotation | fwport-0033 (`f05d25e1`), patch-ID match | none | SKIP:ALREADY-COVERED-BY-YISDING — imported by fwport-0033 |
| `b0c04bd74b5853fff62b03caa2deb25bd8fa2ba2` | 2026-04-17 | video: rockchip: rga3: fix to use `||` instead of `|` | BUGFIX | y — RGA rotation validation | fwport-0034 (`c84b4ee6`), patch-ID match | none | SKIP:ALREADY-COVERED-BY-YISDING — imported by fwport-0034 |
| `488af9c8a1951a475feb9d204f44363beb045f72` | 2026-04-16 | video: rockchip: rga3: support full csc 10bit pixel | FEATURE | n — forbidden 10-bit | — | internal feature expansion | SKIP:FEATURE-USERSPACE-NEVER-SENDS — 10-bit is out of scope |
| `29075a4ec006b51d33c05a3ac66d3449a3d9a842` | 2026-04-28 | video: rockchip: rga3: fix full csc 10bit offset mask | BUGFIX | n — forbidden 10-bit | — | none | SKIP:FEATURE-USERSPACE-NEVER-SENDS — only the unsupported 10-bit path |
| `ab78d9e676319d550510393c014bc7704fb9bfb4` | 2026-04-30 | video: rockchip: rga3: fix virtual address map size calculation | BUGFIX | y — RGA USERPTR mapping | fwport-0025 (`b21a715b`), patch-ID match | none | SKIP:ALREADY-COVERED-BY-YISDING — imported by fwport-0025 |
| `ba2cf11a88e6ac3c49239f8fb7234e93888b1b67` | 2026-04-29 | video: rockchip: rga3: disable RGA2 auto_rst on RK3588 | HARDENING | y — RK3588 RGA2E low-voltage workaround | fwport-0017 (`de2a9c7f`), equivalent issue mask | none | SKIP:ALREADY-COVERED-BY-YISDING — version `3.2.63318` already gets `RGA_HW_ISSUE_DIS_AUTO_RST` |
| `6cddb8da052cd9b943e823159894f64c5f342ca8` | 2026-04-30 | video: rockchip: rga3: enable RGA3 logic_clk_on on RK3588 | HARDENING | y — RGA3 clock control | fwport-0019 retains logic-clock-on in its rebuilt per-mode control word | none | SKIP:NET-ZERO-PAIR — Armbian `6886240fe8444c0cdcbcf4d933ec9b611d4d29c4` reverts it after visible upscale flicker |
| `cbdc58350c8d0a0a1931144122460190fccb3141` | 2026-05-11 | video: rockchip: rga3: fix R2Y csc mode bit shift define error | BUGFIX | y — RGA CSC programming | fwport-0035 (`c24ff126`), equivalent fix | none | SKIP:ALREADY-COVERED-BY-YISDING — imported by fwport-0035 |
| `94b2a6e4ac68d94938068fcda3d24fa3cfd57c5f` | 2026-05-11 | video: rockchip: rga3: skip full csc check when r2y csc mode is 709L | BUGFIX | y — RGA CSC policy | fwport-0036 (`86e23f04`), equivalent fix | none | SKIP:ALREADY-COVERED-BY-YISDING — imported by fwport-0036 |
| `5d6ef118e0f7fb179f4276a3141753aa15ca208d` | 2026-05-14 | video: rockchip: rga3: add some debug log when check csc | CLEANUP | n — diagnostics only | — | none | SKIP:COSMETIC/UNRELATED — log-only change |
| `9bf9dbb3e6146f43ae38432861d5de9dabeab180` | 2026-05-14 | video: rockchip: rga3: fix version macro error | CLEANUP | n — version text only | — | none | SKIP:COSMETIC/UNRELATED — no media behavior change |
| `3e11b74cf816cc58e6db2592e150cb03bf557576` | 2026-06-02 | video: rockchip: rga3: add color fill when AFBC32x8 | FEATURE | n — forbidden AFBC format | — | none | SKIP:FEATURE-USERSPACE-NEVER-SENDS — unsupported format family |
| `58a65098a6e9b2be6a08bccd45aa861850d7b8c6` | 2026-06-09 | video: rockchip: rga3: enable RGA3 auto_reset to avoid read FIFO errors | HARDENING | y — RK3588 RGA3 frame sequencing | no | none | PICK — ported as `de1fad1`; todo 26 must prove timeout recovery emits `rga_reset(reason=auto)` |

The range contains **44 commits**. Only the merge container touches
`include/uapi/linux/rk-mpp.h`; no selectable backlog commit changes the UAPI,
adds an `MPP_CMD_*` value, or changes `rga_req` layout.

## Explicit SKIP list

- **Already covered by yisding:** `916e3ff57cdc`, `0fd948591961`,
  `374aa7ef9ac6`, `d40d55427365`, `15d2b838eed2`, `475afd9e8f04`,
  `62c229ffea79`, `ca9719017f4f`, `0e59668fa8a9`, `54d2caaae7ae`,
  `aacc133b3c39`, `bf1160ba6a9a`, `d86f26889085`, `e839f5d77826`,
  `79b708060e89`, `fb7e267a6da1`, `483de83e7fdc`, `08f3f5e09df6`,
  `b0c04bd74b58`, `ab78d9e67631`, `ba2cf11a88e6`, `cbdc58350c8d`, and
  `94b2a6e4ac68`.
- **Different SoC or disabled client:** `b397ef1eb490`, `db74ba36500b`,
  `90eefde08d7d`, and `340d56559e50`.
- **Feature userspace never sends:** `67621e934754`, `af2d9ce950d0`,
  `391d769fb336`, `ed85f6256729`, `08764fe77bd7`, `488af9c8a195`,
  `29075a4ec006`, and `3e11b74cf816`.
- **Cleanup, merge container, or obsolete kernel-build compatibility:**
  `e6c60675cbda`, `abb155f597c5`, `5fd8e4bcfded`, `7a5c44fd100d`,
  `964583e4b38b`, `5d6ef118e0f7`, and `9bf9dbb3e614`.
- **Net-zero pair:** `6cddb8da052c`; its Armbian revert is
  `6886240fe8444c0cdcbcf4d933ec9b611d4d29c4`.

## Conflict and validation record

The sole pick changes the RGA3 `sys_ctrl` value after yisding's mode-state
rebuild. It preserves the 7.2 port's `RGA_LGC_CLK_ON` bit and adds only
`FRMEND_AUTO_RSTN_EN`; it does not undo a CeraLive rebase delta. Compilation and
UAPI parity are release gates. Runtime validation remains deliberately assigned
to todo 26 because only its injected timeout campaign can prove the hardware
reset trace and recovery semantics.
