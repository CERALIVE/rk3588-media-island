# Silicon ownership — one driver per device, structurally

This is the island's ownership contract. It says, per silicon block, which
driver ends up bound to it and by what mechanism. Every device-tree hunk in
`integration/` and every CI ownership lint reads this document as its input, so a
row here is machine-checked rather than aspirational.

## The mechanism, and why it is not Kconfig

The Linux driver core binds **one** driver per platform device: `device_attach`
sets `dev->driver`, and a second matching driver's `probe` never runs. Two device
nodes covering the same `reg` window collide at `devm_request_mem_region` with
`-EBUSY`. When two drivers match one node, which one wins is decided by module
**load order** — non-deterministic, and therefore not a design.

So the ownership mechanism is exactly this:

> **Every island-owned node carries exactly ONE `compatible` string, matched by
> exactly ONE driver.**

That is already why the MPP encoder driver and the mainline V4L2 drivers coexist
in the shipped kernel today: they bind different nodes. Keeping one compatible
per node is what keeps them coexisting after the port.

**No Kconfig mutual exclusion is used, deliberately.** There is no
`depends on !VIDEO_ROCKCHIP_VDEC` and no `depends on !VIDEO_ROCKCHIP_RGA`, and
adding one is a defect rather than a tidy-up. Keeping the mainline `rkvdec` and
`rockchip-rga` modules BUILT alongside the island is what makes each step
reversible by a device-tree `compatible` flip — and bench-A/B-able through
`driver_override` — instead of by a kernel rebuild. It also keeps the
upstream-migration target alive inside the same image.

Exclusivity is enforced by a **CI lint** instead: each island-owned node has one
compatible, and no in-tree driver's `of_match_table` lists that string.
`CONFIG_VIDEO_ROCKCHIP_RGA` moves to the image's forbidden list only at the RGA
flip, once no node is left for it to bind — a dead module in the image is exactly
what that list exists for.

## Ownership table

Mainline node references are to `rk3588-base.dtsi` in the pinned v7.2 tree (see
[`../kernel-pin.env`](../kernel-pin.env)).

| Silicon | Mainline node (v7.2 `rk3588-base.dtsi`) | Final owner | Mechanism |
|---|---|---|---|
| RKVENC2 #0/#1 + CCU | none | island `mpp` (`ROCKCHIP_MPP_RKVENC2`) | `integration/` DT hunk adds `mpp_srv`, `rkvenc_ccu`, `rkvenc0/1` and their IOMMUs, replacing the existing `rk3588-kernel-patches` `0001` hunk byte-for-byte in intent |
| RKVDEC2 #0/#1 + CCU | `vdec0` / `vdec1`, `rockchip,rk3588-vdec` (`:1400-1462`) | island `mpp` (`ROCKCHIP_MPP_RKVDEC2`) | DT hunk swaps `compatible` to the vendor decoder string as the sole entry and adds `rkvdec_ccu` plus vendor properties. Upstream `rkvdec` stays BUILT (`CONFIG_VIDEO_ROCKCHIP_VDEC=m`) but matches no node — a recorded migration target and a one-line rollback |
| JPEG decoder | none upstream | island `mpp` (`ROCKCHIP_MPP_JPGDEC`) | DT hunk adds `jpegd`, values taken from the vendor DTSI as a first-party hunk |
| JPEG encoders `vepu121_0..3`, `vpu121` (G1 decode) | hantro (`CONFIG_VIDEO_HANTRO=m`) | **UNCHANGED mainline** | Not touched. CeraLive never JPEG-encodes and RKVDEC2 covers its decode codecs; MPP `RKJPEGE` and `VDPU2` clients stay `=n` |
| AV1 `av1d` | `rockchip,rk3588-av1-vpu`, bound by hantro | **UNCHANGED mainline hantro** (unused) | MPP `AV1DEC` stays `=n`; there is no ownership contest |
| RGA3 #0/#1 | `rga3_core0` / `rga3_core1`, `rockchip,rk3588-rga3` (`:1265-1307`) | island `multi_rga` | DT hunk swaps `compatible` to `rockchip,rga3_core0` / `rockchip,rga3_core1` as sole entries; mainline `rockchip-rga` then matches nothing |
| RGA2E | `rga`, `rockchip,rk3588-rga` + `rockchip,rk3288-rga` (`:1308-1318`) | island `multi_rga` | Same flip — the vendor driver matches `rockchip,rga2_core0` natively. DT hunk swaps to `rockchip,rga2_core0` as the sole entry; `CONFIG_VIDEO_ROCKCHIP_RGA` joins the image forbidden list because no node is left to bind |
| HDMI-RX, dma-heaps, IOMMU | mainline plus the existing series | **UNCHANGED** | Stays in `rk3588-kernel-patches`; the island does not touch it |

## Board truth this table was written against

Measured on both CeraLive bench boards running `7.2.0-ceralive-rk3588`, probed
2026-09-02. Coexistence here is a measurement, not a theory:

- `rkvenc` (the Rockchip-ported MPP service) binds `mpp-srv`, `rkvenc-ccu` and
  both encoder cores; mainline `rockchip-rga` binds RGA3 core0 and RGA2;
  `hantro-vpu` binds `vpu121` (G1 decode), `vepu121_0` (JPEG encode) and `av1d`;
  `snps_hdmirx` binds HDMI-RX. Five drivers, disjoint nodes, zero conflict.
- Unbound on both boards: RGA3 core1 (`rockchip-rga: missing multi-core support,
  ignoring`) and `vdec0` / `vdec1`.

## MPP codec → silicon map

MPP userspace covers nearly every codec, but each client maps to a silicon block.
The island compiles the three clients whose block nothing else in the image
needs, and no others:

| Compiled client | Silicon | Codecs |
|---|---|---|
| `RKVENC2` | VEPU580 ×2 | H.264 / H.265 encode |
| `RKVDEC2` | VDPU381 ×2 | H.264 / H.265 / VP9 decode |
| `JPGDEC` | `jpegd` | MJPEG decode |

**Not compiled**, each for a stated reason: `RKJPEGE` (`vepu121` JPEG encode —
unused, hantro-owned), `VDPU2` (`vpu121` MPEG/VP8/G1-H.264 — covered by RKVDEC2,
hantro-owned), `AV1DEC` (`av1d` — hantro-owned, and AV1 is out of scope),
`IEP2` / `VDPP` (owner-decision items), `VEPU1` / `VEPU2` / `VEPU22`, and the v1
`RKVENC` / `RKVDEC` clients (not present on RK3588).

VP8 **encode** does not exist on RK3588 silicon at all, so a VP8 encoder element
can never register on this SoC. A downstream drill that fails for that reason is
reporting hardware truth and must be reclassified, not fixed.

Any hantro-owned block can move under MPP later by the same `compatible` flip.
That is a recorded owner option, not scope.
