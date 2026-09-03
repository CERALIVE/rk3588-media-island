# RK3588 media-island compatibility shim and dependency inventory

> This inventory was produced in the CeraLive workspace root during the island's
> Phase-0 investigation and **moved here unchanged** at repository bootstrap.
> This file is now its only home. It is machine-owned as well as human-read: the
> `shim-lint` CI job parses the table below as its allow/deny list rather than
> maintaining a second copy of the symbol set, so a row's `class` cell is a build
> input and editing it changes what compiles.

This is the input to the island source import. It inventories the maintained
vendor-forward-port result, not the unrelated clean-room rewrite and not the
frozen two-patch/DKMS anchor.

## Source identity and A6 lineage verification

All source citations below were read at these immutable objects:

- yisding integration/patch record: `yisding/rock-5b-ysp@ca3da04280c48c004e522c15f31862bf88a2d1b9`;
- realized maintained series: `yisding/linux-rock5b@e7ff978398825b63ddcb13e0572d77564034c1e2`;
- vendor donor: `rockchip-linux/kernel@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`;
- historical comparison only: `armbian/linux-rockchip@fd9f82366e235b8afbdf516765210e97d24dce93`;
- mainline replacement baseline: Linux `v7.2@8d3ae59288f1e7d58d76558a6ee96d533bc5019f`.

**A6 — CONFIRMED; no lineage contradiction.** The maintained-series README
says, verbatim, “The **single** RK3588 MPP/RGA/AV1 forward-port patch series for
Armbian `rockchip64-current` / Linux 6.18, exported from branch
**`rk3588-video-6.18`**”
(`kernel-drivers/patches/forward-port-rk3588/README.md:3-5@ca3da04280c48c004e522c15f31862bf88a2d1b9`).
It separately says the checked-in export is contiguous `0001`–`0097`
(`README.md:42-47@ca3da04280c48c004e522c15f31862bf88a2d1b9`). The public source branch exists
in `yisding/linux-rock5b` and resolves to `e7ff978398825…`, the same tip named by
the `0097` index row (`README.md:423-446@ca3da04280c48c004e522c15f31862bf88a2d1b9`).

The donor is independently recorded as “donor
`rockchip-kernel@b4ef083dc0c3` (`develop-6.1`)”
(`kernel-drivers/docs/vendor-delta.md:18-19@ca3da04280c48c004e522c15f31862bf88a2d1b9`).
The donor commit's committer timestamp is 2025-12-26. The historical Armbian
object is the head of `rk-6.1-rkr5.1`, and its RGA header reports 1.3.7
(`drivers/video/rockchip/rga3/include/rga_drv.h:89-95@fd9f82366e235b8afbdf516765210e97d24dce93`);
the donor reports 1.3.11
(`drivers/video/rockchip/rga3/include/rga_drv.h:90-96@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`).
It is therefore comparison material, not the import source. The README does
**not** claim that the vendor series was built on 7.2; CeraLive's 6.18→7.2
rebase remains todo 8.

## Classification rules

- `STUB-SAFE(-ENODEV/no-op)` means the selected RK3588 GA clients still bind and
  execute correctly with the stated loss. It does not mean the vendor feature
  is equivalent.
- `REAL-DEPENDENCY` means a stub would remove memory-safety, fault recovery,
  hardware-start, or an enabled userspace contract. These rows may use a small
  provider adapter where mainline intentionally has no public one-for-one API.
- `QUICK-WIN (≤1 day drop-in)` and `MEDIUM (1–3 day adapter)` are implementation
  grades. `HARD-DEFER` needs a missing platform contract or fresh scope.
  `KEEP-STUB` is deliberate for the GA configuration.
- “lexical-census only” marks names emitted by the required grep because the
  shim declaration or a comment contains `name(`, even though no imported
  call site exists. They remain rows so the census is mechanically closed.

## Shim and dependency table

| symbol | called from (file:line@sha) | vendor semantics | class ∈ {STUB-SAFE(-ENODEV/no-op), REAL-DEPENDENCY} | mainline replacement (API + file) | fixed-clock/PM impact | PROMOTION ∈ {QUICK-WIN (≤1 day drop-in), MEDIUM (1–3 day adapter), HARD-DEFER, KEEP-STUB} | hot-path (per task/job) or probe-time | what the operator/engine GAINS | executing todo |
|---|---|---|---|---|---|---|---|---|---|
| `compat/linux/rockchip/rockchip_sip.h` | `mpp/mpp_rkvdec2.h:23@e7ff978398825b63ddcb13e0572d77564034c1e2` | Supplies only a zero-result `sip_smc_vpu_reset`; caller ignores it and uses CRU reset (`compat/linux/rockchip/rockchip_sip.h:10-31@e7ff978398825b63ddcb13e0572d77564034c1e2`). | STUB-SAFE(-ENODEV/no-op) | `reset_control_*`; `include/linux/reset.h` and the existing rkvdec2 CRU reset path. | No frequency effect; avoids a firmware-specific reset dependency. | KEEP-STUB | Fault/timeout reset, not ordinary jobs. | Portable decoder reset on mainline TF-A; no false firmware requirement. | 40 records; 54 keeps stub. |
| `compat/rockchip_pmu_idle.h` | `mpp/mpp_common.h:839@e7ff978398825b63ddcb13e0572d77564034c1e2` | Returns success; every island node sets `rockchip,skip-pmu-idle-request`, so the wrapper exits before it (`compat/rockchip_pmu_idle.h:15-29@e7ff978398825b63ddcb13e0572d77564034c1e2`). | STUB-SAFE(-ENODEV/no-op) | Generic PM-domain/runtime-PM ownership; `drivers/base/power/domain.c`, `include/linux/pm_runtime.h`. | Leaves assigned clocks plus runtime autosuspend in charge; no BSP idle handshake. | KEEP-STUB | Wrapper is per task, stub is unreachable on island DT. | Predictable PM without importing BSP genpd internals. | 10 carries DT property; 40 measures PM; 54 ledger. |
| `compat/rockchip_qos_compat.h` | `mpp/mpp_rkvdec2_link.c:649,654@e7ff978398825b63ddcb13e0572d77564034c1e2` | No-op success matching vendor `!CONFIG_ROCKCHIP_PM_DOMAINS`; vendor implementation snapshots/restores QoS registers (`drivers/soc/rockchip/pm_domains.c:722-769,813-857@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`). | STUB-SAFE(-ENODEV/no-op) | None required; genpd/provider owns power sequencing. | Reset returns to hardware defaults; no clock-rate change. | KEEP-STUB | Decoder reset/recovery only. | Smaller mainline dependency surface; ordinary decode unchanged. | 40 measures; 54 ledger. |
| `compat/soc/rockchip/rockchip_dmc.h` | `mpp/mpp_rkvdec2.c:21,1473-1475@e7ff978398825b63ddcb13e0572d77564034c1e2` | Vendor read-locks a global DMC devfreq semaphore (`drivers/devfreq/rockchip_dmc_common.c:17-36@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`); vendor's disabled-config branch is also no-op. | STUB-SAFE(-ENODEV/no-op) | No mainline global DMC lock; keep decoder CRU reset self-contained. | No DDR-devfreq coordination; fixed media clocks unchanged. | KEEP-STUB | Decoder SIP/reset window only. | Avoids importing a board-wide DDR governor solely for reset. | 40 measures; 54 ledger. |
| `compat/soc/rockchip/rockchip_iommu.h` (historical `0001` shim; deleted by `0005`) | `kernel-drivers/patches/forward-port-rk3588/rk3588-fwport-0001-video-rockchip-RK3588-vendor-MPP-rkvenc2-rkvdec2-RGA.patch:408-452@ca3da04280c48c004e522c15f31862bf88a2d1b9` | Originally returned `-ENODEV`/false/no-op for provider control; that loses refresh and fault IRQ control. `0005` replaces it with a real exported provider API (`kernel-drivers/patches/forward-port-rk3588/rk3588-fwport-0005-iommu-add-Verisilicon-IOMMU-provider-and-Rockchip-pr.patch:427-550@ca3da04280c48c004e522c15f31862bf88a2d1b9`). | REAL-DEPENDENCY | Provider adapter in `integration/` over `iommu_attach_group`, `iommu_detach_group`, `iommu_flush_iotlb_all`; `include/linux/iommu.h:944-1006@8d3ae59288f1e7d58d76558a6ee96d533bc5019f` plus `drivers/iommu/rockchip-iommu.c`. | No DVFS effect; runtime-PM must keep provider registers live during control. | QUICK-WIN (≤1 day drop-in) | Task admission, fault IRQ, and recovery. | Real mapping refresh and bounded fault recovery instead of silent degradation. | 8 imports provider exports; 7 later forbids this stub. |
| `compat/soc/rockchip/rockchip_ipa.h` | `mpp/mpp_rkvenc2.c:32@e7ff978398825b63ddcb13e0572d77564034c1e2` | Dead include; no `rockchip_ipa_*` caller exists (`compat/soc/rockchip/rockchip_ipa.h:5-11@e7ff978398825b63ddcb13e0572d77564034c1e2`). | STUB-SAFE(-ENODEV/no-op) | Delete include/header; no API replacement. | None; fixed 800 MHz encoder clock remains. | QUICK-WIN (≤1 day drop-in) | Probe-time include only; no runtime path. | Removes misleading unsupported static-power code. | 54 deletes it. |
| `compat/soc/rockchip/rockchip_opp_select.h` | `mpp/mpp_rkvenc2.c:33,2483-2484@e7ff978398825b63ddcb13e0572d77564034c1e2` | Stubs PVTM/binning/read-margin state; init returns `-EOPNOTSUPP` (`compat/soc/rockchip/rockchip_opp_select.h:29-64@e7ff978398825b63ddcb13e0572d77564034c1e2`). | STUB-SAFE(-ENODEV/no-op) | Future `dev_pm_opp_of_add_table`/`dev_pm_opp_set_rate` + regulators/devfreq; `include/linux/pm_opp.h`, `drivers/devfreq/`. | Keeps assigned 800 MHz encoder clock; no voltage/bin/leakage-aware DVFS. | HARD-DEFER | Probe; lock/unlock would be per frequency transition. | Today: stable fixed clock. Future promotion: lower idle/load power and safe scaling. | 40 records reopen-on-STARVED memo. |
| `compat/soc/rockchip/rockchip_system_monitor.h` | `mpp/mpp_rkvenc2.c:34,2465-2469,2523@e7ff978398825b63ddcb13e0572d77564034c1e2` | Register returns `ERR_PTR(-ENODEV)` and callbacks no-op; vendor applies low/high-temperature voltage/frequency limits (`include/soc/rockchip/rockchip_system_monitor.h:58-152@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`). | STUB-SAFE(-ENODEV/no-op) | `devm_thermal_of_cooling_device_register` / `thermal_cooling_device_ops`; `include/linux/thermal.h:210,296-300@8d3ae59288f1e7d58d76558a6ee96d533bc5019f`. | No media-specific throttle today; SoC `rockchip-thermal` and fan remain independent. | MEDIUM (1–3 day adapter) | Probe plus thermal events, not each job. | Evidence-gated encoder/decoder clock-step thermal throttling. | 40 decides; 55 implements if NEEDED. |
| `soc/rockchip/pm_domains.h` | `mpp/mpp_common.c:37; mpp/mpp_rkvenc2.c:31@e7ff978398825b63ddcb13e0572d77564034c1e2` | Vendor header also exposes idle/QoS and direct PD controls; v7.2 exposes only `rockchip_pmu_block/unblock` (`include/soc/rockchip/pm_domains.h:9-23@8d3ae59288f1e7d58d76558a6ee96d533bc5019f`). | STUB-SAFE(-ENODEV/no-op) | Keep v7.2 header; generic runtime PM/genpd for RK3588 clients. | No direct PD toggles on RK3588; autosuspend owns power. | KEEP-STUB | Include/probe; PX30-only direct-PD path is not RK3588. | Prevents obsolete direct-PD control entering the GA path. | 8 keeps non-RK clients disabled; 40 audits runtime PM. |
| `soc/rockchip/rockchip_dmc.h` | `mpp/mpp_rkvdec2_link.c:14@e7ff978398825b63ddcb13e0572d77564034c1e2` | Header side of DMC reset serialization; real vendor calls are a read semaphore (`include/soc/rockchip/rockchip_dmc.h:70-93@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`). | STUB-SAFE(-ENODEV/no-op) | Compat no-op; no mainline header. | No DDR governor imported. | KEEP-STUB | Reset only. | Keeps decoder portable and fixed-clock. | 40/54. |
| `soc/rockchip/rockchip_iommu.h` | `mpp/mpp_iommu.c:29; rga3/rga_iommu.c:15@e7ff978398825b63ddcb13e0572d77564034c1e2` | Real provider-private control and fault callback contract (`include/soc/rockchip/rockchip_iommu.h:16-29@e7ff978398825b63ddcb13e0572d77564034c1e2`). | REAL-DEPENDENCY | Island `integration/` header + Rockchip provider exports; generic domain/map APIs remain in `include/linux/iommu.h`. | Provider accesses must be runtime-PM balanced; no frequency selection. | QUICK-WIN (≤1 day drop-in) | Per task/fault/recovery. | Safe MPP and RGA IOMMU ownership and recovery. | 8; 7 lint. |
| `soc/rockchip/rockchip_ipa.h` | `mpp/mpp_rkvenc2.c:32@e7ff978398825b63ddcb13e0572d77564034c1e2` | No call consumes the header. | STUB-SAFE(-ENODEV/no-op) | Delete. | None. | QUICK-WIN (≤1 day drop-in) | Probe-time include only. | Less dead compatibility surface. | 54. |
| `soc/rockchip/rockchip_opp_select.h` | `mpp/mpp_rkvdec2.c:22; mpp/mpp_rkvenc2.c:33@e7ff978398825b63ddcb13e0572d77564034c1e2` | Carries vendor OPP/PVTM/binning structures and operations (`include/soc/rockchip/rockchip_opp_select.h:68-145,152-192@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`). | STUB-SAFE(-ENODEV/no-op) | Mainline OPP/devfreq plus a future RK3588 voltage/read-margin adapter. | Fixed clocks; no regulator/PVTM contract. | HARD-DEFER | Probe and frequency transitions. | Future efficiency only if fixed clocks prove starved/thermally inadequate. | 40. |
| `soc/rockchip/rockchip_sip.h` | `mpp/mpp_rkvdec2.h:28@e7ff978398825b63ddcb13e0572d77564034c1e2` | No declaration from this header is consumed; `sip_smc_vpu_reset` comes from the separate Linux-path shim. | STUB-SAFE(-ENODEV/no-op) | Keep v7.2's existing header or delete this dead include during rebase; `include/soc/rockchip/rockchip_sip.h`. | None. | KEEP-STUB | Probe-time include only. | No operator-visible change. | 8 rebase; 54 ledger. |
| `soc/rockchip/rockchip_system_monitor.h` | `mpp/mpp_rkvdec2.c:23; mpp/mpp_rkvenc2.c:34@e7ff978398825b63ddcb13e0572d77564034c1e2` | BSP temperature/voltage policy service. | STUB-SAFE(-ENODEV/no-op) | Mainline thermal cooling adapter; `include/linux/thermal.h`. | No device-specific throttling until evidence asks for it. | MEDIUM (1–3 day adapter) | Probe/thermal-event. | Honest thermal integration without the BSP-wide monitor. | 40→55. |
| `soc/rockchip/vsi_iommu.h` | `mpp/mpp_iommu.c:30@e7ff978398825b63ddcb13e0572d77564034c1e2` | Selects Verisilicon/AV1 provider refresh, IRQ, and callback hooks; disabled branch returns `-ENODEV` (`include/soc/rockchip/vsi_iommu.h:10-52@e7ff978398825b63ddcb13e0572d77564034c1e2`). | STUB-SAFE(-ENODEV/no-op) | Keep a local disabled-client shim; importing `drivers/iommu/vsi-iommu.c` is outside GA scope. | None for RKVENC2/RKVDEC2/JPGDEC/RGA; AV1 remains disabled. | KEEP-STUB | Branch-tested during MPP fault setup; resolves immediately to Rockchip provider. | No accidental AV1/provider promise. | 8 drops VSI provider/marks AV1 BROKEN; 54 ledger. |
| `compat/soc/rockchip/vsi_iommu.h` | Local resolution of `mpp/mpp_iommu.c:30` after the manifest drops the AV1-only provider/header from `0005` | Carries only the provider-disabled `-ENODEV`/no-op branch; selected Rockchip clients take the real Rockchip provider path first. | STUB-SAFE(-ENODEV/no-op) | Island-local disabled-client shim under the MPP `$(src)/compat` include root. | None; AV1 and IEP2 remain unselectable. | KEEP-STUB | Branch-tested fallback after the Rockchip provider probe. | Lets the selected clients compile without importing or pretending to support the Verisilicon provider. | 8. |
| `rockchip_dmcfreq_lock` | `mpp/mpp_rkvdec2.c:1473; mpp/mpp_rkvdec2_link.c:2069,2761@e7ff978398825b63ddcb13e0572d77564034c1e2` | Read-locks DMC frequency changes around firmware reset (`drivers/devfreq/rockchip_dmc_common.c:20-24@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`). | STUB-SAFE(-ENODEV/no-op) | No replacement; CRU reset is the live path. | No DDR-frequency exclusion; media clocks unchanged. | KEEP-STUB | Fault/reset path. | Avoids board-wide DMC dependency. | 40/54. |
| `rockchip_dmcfreq_lock_nested` | lexical-census only: `mpp/compat/soc/rockchip/rockchip_dmc.h:20@e7ff978398825b63ddcb13e0572d77564034c1e2` | Nested form of vendor DMC read lock; no imported caller. | STUB-SAFE(-ENODEV/no-op) | None; delete if shim is narrowed. | None. | KEEP-STUB | Never called. | No gain; census closure only. | 54 ledger. |
| `rockchip_dmcfreq_unlock` | `mpp/mpp_rkvdec2.c:1475; mpp/mpp_rkvdec2_link.c:2071,2763@e7ff978398825b63ddcb13e0572d77564034c1e2` | Releases vendor DMC read semaphore (`drivers/devfreq/rockchip_dmc_common.c:32-36@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`). | STUB-SAFE(-ENODEV/no-op) | No replacement. | No DDR-frequency exclusion. | KEEP-STUB | Fault/reset path. | Same reset behavior without BSP DMC stack. | 40/54. |
| `rockchip_get_opp_data` | `mpp/mpp_rkvenc2.c:2483@e7ff978398825b63ddcb13e0572d77564034c1e2` | Loads SoC-specific OPP callbacks/data (`drivers/soc/rockchip/rockchip_opp_select.c:1261@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`). | STUB-SAFE(-ENODEV/no-op) | Future `of_device_get_match_data` + OPP adapter. | Fixed 800 MHz, no PVTM metadata. | HARD-DEFER | Probe. | Future safe voltage/frequency policy; none needed for current fixed-clock GA. | 40. |
| `rockchip_init_opp_table` | `mpp/mpp_rkvenc2.c:2484; mpp/mpp_rkvdec2.c:1122@e7ff978398825b63ddcb13e0572d77564034c1e2` | Builds vendor OPP table with regulators, bin/process/leakage/PVTM/read-margin policy (`include/soc/rockchip/rockchip_opp_select.h:68-145,189-192@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`). | STUB-SAFE(-ENODEV/no-op) | Future mainline OPP/devfreq/regulator adapter. | Returns `-EOPNOTSUPP`; encoder documents DT-pinned nominal 800 MHz (`mpp_rkvenc2.c:2485-2493@e7ff978398825b63ddcb13e0572d77564034c1e2`). | HARD-DEFER | Probe. | Current predictable clocks; future adaptive power only on STARVED evidence. | 40. |
| `rockchip_iommu_disable` | `mpp/mpp_iommu.c:1131@e7ff978398825b63ddcb13e0572d77564034c1e2` | Stalls, disables paging/IRQs/DTE, and clocks provider during refresh (`drivers/iommu/rockchip-iommu.c:1135-1171@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`). | REAL-DEPENDENCY | Provider adapter + `iommu_detach_group`/domain flush; `drivers/iommu/rockchip-iommu.c`, `include/linux/iommu.h`. | Runtime-PM-sensitive, no DVFS. | QUICK-WIN (≤1 day drop-in) | Recovery/refresh. | Reusable domain after codec faults. | 8; 7 lint. |
| `rockchip_iommu_enable` | `mpp/mpp_iommu.c:1141@e7ff978398825b63ddcb13e0572d77564034c1e2` | Programs DTE, zaps TLB, enables paging/IRQ (`drivers/iommu/rockchip-iommu.c:1174-1248@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`). | REAL-DEPENDENCY | Provider adapter + `iommu_attach_group`; `drivers/iommu/rockchip-iommu.c`, `include/linux/iommu.h:976-978@8d3ae59288f1e7d58d76558a6ee96d533bc5019f`. | Runtime-PM must be active; no clock policy. | QUICK-WIN (≤1 day drop-in) | Recovery/refresh. | Hardware resumes with valid translation state. | 8; 7 lint. |
| `rockchip_iommu_enable_irq_delivery` | `mpp/mpp_iommu.c:1313@e7ff978398825b63ddcb13e0572d77564034c1e2` | Enables fault delivery only after task ownership and START are committed (`drivers/iommu/rockchip-iommu.c:1506@e7ff978398825b63ddcb13e0572d77564034c1e2`). | REAL-DEPENDENCY | Provider-private adapter retained in `integration/`; no safe generic IRQ-delivery API. | Short runtime-PM provider access; no DVFS. | QUICK-WIN (≤1 day drop-in) | Per task commit. | No lost or misattributed post-START faults. | 8; 9 fault tests; 7 lint. |
| `rockchip_iommu_force_reset` | `mpp/mpp_rkvdec2.c:1438,1458@e7ff978398825b63ddcb13e0572d77564034c1e2` | Stalls and pulses provider reset (`drivers/iommu/rockchip-iommu.c:1263-1283@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`). | REAL-DEPENDENCY | Provider-private reset adapter plus generic domain reattach/flush. | Recovery-only PM lease; fixed clocks unchanged. | QUICK-WIN (≤1 day drop-in) | Decoder reset/fault. | Decoder recovers instead of remaining wedged. | 8; 9. |
| `rockchip_iommu_is_enabled` | `mpp/hack/mpp_hack_px30.c:188@e7ff978398825b63ddcb13e0572d77564034c1e2` | Reads provider enable state (`drivers/iommu/rockchip-iommu.c:1251-1261@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`). | REAL-DEPENDENCY | Provider adapter; generic core has domain attachment but no equivalent hardware-enable boolean. | None on RK3588; PX30 hack only. | QUICK-WIN (≤1 day drop-in) | Non-RK probe/hack path. | Preserves source completeness without lying if that client is later enabled. | 8; 7 lint. |
| `rockchip_iommu_mask_irq` | `mpp/mpp_iommu.c:952,1401; rga3/rga_iommu.c:312-347@e7ff978398825b63ddcb13e0572d77564034c1e2` | Masks all provider MMU IRQs to stop a page-fault storm (`drivers/iommu/rockchip-iommu.c:1535-1546@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`). | REAL-DEPENDENCY | Provider-private adapter in `integration/`; generic fault handler alone cannot mask hardware IRQs. | Fault-path PM access only. | QUICK-WIN (≤1 day drop-in) | Fault and task teardown. | Bounded logs/CPU and safe task lifetime during faults. | 8; 9; 7 lint. |
| `rockchip_iommu_prepare_irq` | `mpp/mpp_iommu.c:1264@e7ff978398825b63ddcb13e0572d77564034c1e2` | Masks delivery, synchronizes an in-flight IRQ, acknowledges only stale pre-task status (`mpp/mpp_iommu.c:1259-1268@e7ff978398825b63ddcb13e0572d77564034c1e2`). | REAL-DEPENDENCY | Provider-private adapter retained; compose IRQ synchronization and Rockchip MMIO in `drivers/iommu/rockchip-iommu.c`. | Per-task short provider PM lease. | QUICK-WIN (≤1 day drop-in) | Per task admission. | Fault ownership starts from a clean epoch. | 8; 9; 7 lint. |
| `rockchip_iommu_set_fault_handler` | `mpp/mpp_iommu.c:1168; rga3/rga_iommu.c:312@e7ff978398825b63ddcb13e0572d77564034c1e2` | Installs provider-local callback because DMA domains already own a core cookie (`mpp/mpp_iommu.c:1162-1181@e7ff978398825b63ddcb13e0572d77564034c1e2`). | REAL-DEPENDENCY | Provider adapter; generic `iommu_set_fault_handler` only for cookie-less fallback; `include/linux/iommu.h`. | No clock-rate impact; callback lifetime must be PM/teardown safe. | QUICK-WIN (≤1 day drop-in) | Task activation and teardown. | Correct MPP/RGA fault attribution and recovery. | 8; 9; 7 lint. |
| `rockchip_iommu_sync_fault_handler` | `mpp/mpp_iommu.c:1103,1365@e7ff978398825b63ddcb13e0572d77564034c1e2` | Quiescence barrier: waits until no provider IRQ uses the old callback token (`include/soc/rockchip/rockchip_iommu.h:28-29@e7ff978398825b63ddcb13e0572d77564034c1e2`). | REAL-DEPENDENCY | Provider-private synchronization in `drivers/iommu/rockchip-iommu.c`; no generic token-quiesce API. | May sleep on teardown/recovery; not frequency-related. | QUICK-WIN (≤1 day drop-in) | Teardown/recovery. | Prevents callback-token UAF. | 8; 9; 7 lint. |
| `rockchip_iommu_unmask_irq` | `mpp/mpp_iommu.c:1272,1350; mpp/mpp_iep2.c:1065@e7ff978398825b63ddcb13e0572d77564034c1e2` | Zaps TLB, restores IRQ mask, acknowledges page fault (`drivers/iommu/rockchip-iommu.c:1548-1568@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`). | REAL-DEPENDENCY | Provider-private adapter + `iommu_flush_iotlb_all`. | Recovery/task-boundary PM access. | QUICK-WIN (≤1 day drop-in) | Task abort/recovery. | Translation and fault delivery return cleanly. | 8; 9; 7 lint. |
| `rockchip_ipa_get_static_power` | lexical-census only: `mpp/compat/soc/rockchip/rockchip_ipa.h:34-37@e7ff978398825b63ddcb13e0572d77564034c1e2` | Would report leakage/static power; no caller. | STUB-SAFE(-ENODEV/no-op) | Delete with dead header. | None. | QUICK-WIN (≤1 day drop-in) | Never called. | Removes dead API fiction. | 54. |
| `rockchip_ipa_power_model_init` | lexical-census only: `mpp/compat/soc/rockchip/rockchip_ipa.h:27-31@e7ff978398825b63ddcb13e0572d77564034c1e2` | Would create BSP IPA power model; no caller. | STUB-SAFE(-ENODEV/no-op) | Delete with dead header. | None. | QUICK-WIN (≤1 day drop-in) | Never called. | Removes dead API fiction. | 54. |
| `rockchip_monitor_check_rate_volt` | callback assigned at `mpp/mpp_rkvenc2.c:2467@e7ff978398825b63ddcb13e0572d77564034c1e2` | Vendor validates current clock rate/voltage under OPP lock (`drivers/soc/rockchip/rockchip_system_monitor.c:1374-1402@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`). | STUB-SAFE(-ENODEV/no-op) | Mainline cooling adapter + clock/OPP validation. | No rate/voltage validation today; fixed assigned clock. | MEDIUM (1–3 day adapter) | Thermal/monitor event. | Detectable safe throttling if thermal evidence demands it. | 40→55. |
| `rockchip_monitor_dev_high_temp_adjust` | callback assigned at `mpp/mpp_rkvenc2.c:2469; mpp/mpp_rkvdec2.c:1097@e7ff978398825b63ddcb13e0572d77564034c1e2` | Vendor constrains max OPP/voltage at high temperature (`include/soc/rockchip/rockchip_system_monitor.h:58-126,149-152@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`). | STUB-SAFE(-ENODEV/no-op) | `thermal_cooling_device_ops.set_cur_state` selecting safe clock steps. | No media-specific hot throttle today. | MEDIUM (1–3 day adapter) | Thermal event. | Protects sustained workloads if passive trips are observed. | 40→55. |
| `rockchip_monitor_dev_low_temp_adjust` | callback assigned at `mpp/mpp_rkvenc2.c:2468; mpp/mpp_rkvdec2.c:1096@e7ff978398825b63ddcb13e0572d77564034c1e2` | Vendor applies low-temperature voltage margin (`include/soc/rockchip/rockchip_system_monitor.h:58-126,149-150@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`). | STUB-SAFE(-ENODEV/no-op) | No safe clock-only equivalent for voltage margin; cooling adapter can only cap rates. | Fixed rate/board regulator policy; no low-temp voltage uplift. | HARD-DEFER | Thermal event. | None now; full gain requires regulator/OPP contract, not a cosmetic adapter. | 40 memo; reopen with OPP scope. |
| `rockchip_nvmem_cell_read_u8` | Donor-only `mpp/mpp_rkvenc.c:969@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`, inside the RV1126 OPP path | Reads the vendor `performance` NVMEM cell by device-tree node to select an RV1126 process bin. | STUB-SAFE(-ENODEV/no-op) | No RK3588 replacement is needed; a future legacy-client port can acquire the cell and call mainline `nvmem_cell_read_u8()` from `include/linux/nvmem-consumer.h`. | None on RK3588; the RKVENC-v1 client is `BROKEN`-gated. | HARD-DEFER | Probe-time on RV1126 only. | No GA gain; the row closes the complete-donor lexical census without pretending the legacy client is supported. | 8 keeps RKVENC v1 source-complete and unselectable. |
| `rockchip_opp_dvfs_lock` | `mpp/mpp_rkvenc2.c:2368@e7ff978398825b63ddcb13e0572d77564034c1e2` | Serializes vendor voltage and clock transition (`include/soc/rockchip/rockchip_opp_select.h:69-72,160-161@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`). | STUB-SAFE(-ENODEV/no-op) | Future adapter mutex around regulator + `dev_pm_opp_set_rate`. | Inert because devfreq init fails; clock fixed. | HARD-DEFER | Per frequency transition; no current calls after failed probe. | Future race-free adaptive frequency. | 40. |
| `rockchip_opp_dvfs_unlock` | `mpp/mpp_rkvenc2.c:2378@e7ff978398825b63ddcb13e0572d77564034c1e2` | Completes serialized voltage/clock transition. | STUB-SAFE(-ENODEV/no-op) | Future adapter mutex. | Inert; fixed clock. | HARD-DEFER | Per frequency transition; disabled today. | Future race-free adaptive frequency. | 40. |
| `rockchip_pmu_block` | lexical-census only (comments): `mpp/compat/rockchip_pmu_idle.h:6; mpp/compat/rockchip_qos_compat.h:8@e7ff978398825b63ddcb13e0572d77564034c1e2` | Vendor/mainline can block concurrent domain transitions; imported driver has no call. | STUB-SAFE(-ENODEV/no-op) | Already present in v7.2 `include/soc/rockchip/pm_domains.h:11-21@8d3ae59288f1e7d58d76558a6ee96d533bc5019f`. | None. | KEEP-STUB | Never called. | No gain; records grep false-positive. | 54 ledger. |
| `rockchip_pmu_idle_request` | `mpp/mpp_common.h:839@e7ff978398825b63ddcb13e0572d77564034c1e2` | Vendor toggles a genpd bus-idle request under PMU lock (`drivers/soc/rockchip/pm_domains.c:660-681@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`). | STUB-SAFE(-ENODEV/no-op) | Runtime PM/genpd; island DT forces wrapper short-circuit. | Fixed clocks plus autosuspend; no explicit bus-idle request. | KEEP-STUB | Per task wrapper, unreachable stub. | Avoids unsupported PMU register coupling. | 10 + 40 + 54. |
| `rockchip_pmu_pd_is_on` | `mpp/hack/mpp_hack_px30.c:224@e7ff978398825b63ddcb13e0572d77564034c1e2` | Queries direct PM-domain state (`include/soc/rockchip/pm_domains.h:17-20@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`). | STUB-SAFE(-ENODEV/no-op) | `pm_runtime_active`/genpd; path is PX30-only and disabled for island. | None on RK3588. | KEEP-STUB | Non-RK hack path. | No GA gain; prevents importing direct-PD BSP API. | 8 keeps client disabled; 54 ledger. |
| `rockchip_pmu_pd_off` | `mpp/hack/mpp_hack_px30.c:242@e7ff978398825b63ddcb13e0572d77564034c1e2` | Directly powers vendor domain off (`drivers/soc/rockchip/pm_domains.c:1127@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`). | STUB-SAFE(-ENODEV/no-op) | `pm_runtime_put_sync_suspend`; path disabled. | None on RK3588. | KEEP-STUB | Non-RK hack path. | No GA gain. | 8/54. |
| `rockchip_pmu_pd_on` | `mpp/hack/mpp_hack_px30.c:226@e7ff978398825b63ddcb13e0572d77564034c1e2` | Directly powers vendor domain on (`drivers/soc/rockchip/pm_domains.c:1109@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`). | STUB-SAFE(-ENODEV/no-op) | `pm_runtime_resume_and_get`; path disabled. | None on RK3588. | KEEP-STUB | Non-RK hack path. | No GA gain. | 8/54. |
| `rockchip_restore_qos` | `mpp/mpp_rkvdec2_link.c:654@e7ff978398825b63ddcb13e0572d77564034c1e2` | Restores PM-domain QoS/shaping register snapshot (`drivers/soc/rockchip/pm_domains.c:747-769,836-857@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`). | STUB-SAFE(-ENODEV/no-op) | No replacement; defaults after CRU reset are accepted and measured. | No clock effect; possible reset-only QoS-default difference. | KEEP-STUB | Decoder reset. | Avoids BSP PM-domain internals. | 40/54. |
| `rockchip_save_qos` | `mpp/mpp_rkvdec2_link.c:649@e7ff978398825b63ddcb13e0572d77564034c1e2` | Snapshots PM-domain QoS/shaping registers (`drivers/soc/rockchip/pm_domains.c:722-745,813-834@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`). | STUB-SAFE(-ENODEV/no-op) | No replacement. | Reset-only impact; no DVFS. | KEEP-STUB | Decoder reset. | Simpler mainline reset path. | 40/54. |
| `rockchip_system_monitor_register` | `mpp/mpp_rkvenc2.c:2523; mpp/mpp_rkvdec2.c:1151@e7ff978398825b63ddcb13e0572d77564034c1e2` | Registers OPP-backed device in vendor thermal/voltage monitor; disabled form errors and callers continue (`include/soc/rockchip/rockchip_system_monitor.h:139-168@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`). | STUB-SAFE(-ENODEV/no-op) | `devm_thermal_of_cooling_device_register`; `include/linux/thermal.h`. | No media cooling state today. | MEDIUM (1–3 day adapter) | Probe. | Native thermal cooling only if measured necessary. | 40→55. |
| `rockchip_system_monitor_unregister` | `mpp/mpp_rkvenc2.c:2565; mpp/mpp_rkvdec2.c:1172@e7ff978398825b63ddcb13e0572d77564034c1e2` | Removes vendor monitor registration. | STUB-SAFE(-ENODEV/no-op) | `thermal_cooling_device_unregister`/devm teardown. | None while monitor absent. | MEDIUM (1–3 day adapter) | Remove. | Balanced cooling-device lifetime. | 40→55. |
| `rockchip_uninit_opp_table` | `mpp/mpp_rkvenc2.c:2574; mpp/mpp_rkvdec2.c:1176@e7ff978398825b63ddcb13e0572d77564034c1e2` | Tears down vendor OPP/regulator/PVTM state (`drivers/soc/rockchip/rockchip_opp_select.c:2605@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`). | STUB-SAFE(-ENODEV/no-op) | Future `dev_pm_opp_of_remove_table` + adapter cleanup. | None because init is refused and clocks remain fixed. | HARD-DEFER | Remove. | Future balanced adaptive-PM teardown. | 40. |
| `sip_smc_vpu_reset` | `mpp/mpp_rkvdec2.c:1474; mpp/mpp_rkvdec2_link.c:2070,2762@e7ff978398825b63ddcb13e0572d77564034c1e2` | Vendor invokes TF-A VPU reset SMC; declaration/result ABI is in `include/linux/rockchip/rockchip_sip.h:275-287,361-366@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`. Calls ignore the result. | STUB-SAFE(-ENODEV/no-op) | Existing CRU `reset_control_*` fallback. | Reset-only; no clock policy. | KEEP-STUB | Fault/reset. | Works with mainline firmware contract; avoids relying on absent SMC. | 40/54. |
| `vsi_iommu_refresh` | `mpp/mpp_iommu.c:1133@e7ff978398825b63ddcb13e0572d77564034c1e2` | Refreshes Verisilicon provider after Rockchip provider returns `-ENODEV`. | STUB-SAFE(-ENODEV/no-op) | Disabled-client inline; generic `iommu_flush_iotlb_all` is final fallback. | None for GA clients. | KEEP-STUB | Recovery branch, immediately skipped on Rockchip IOMMU. | Honest no-AV1 scope. | 8/54. |
| `vsi_iommu_mask_irq` | `mpp/mpp_iommu.c:953,1402@e7ff978398825b63ddcb13e0572d77564034c1e2` | Masks VSI fault delivery. | STUB-SAFE(-ENODEV/no-op) | Disabled inline; VSI provider omitted. | None. | KEEP-STUB | Fault/teardown branch. | No accidental VSI dependency. | 8/54. |
| `vsi_iommu_unmask_irq` | `mpp/mpp_iommu.c:1273,1351@e7ff978398825b63ddcb13e0572d77564034c1e2` | Re-enables VSI fault delivery. | STUB-SAFE(-ENODEV/no-op) | Disabled inline. | None. | KEEP-STUB | Task abort branch. | No accidental VSI dependency. | 8/54. |
| `vsi_iommu_prepare_irq` | `mpp/mpp_iommu.c:1266@e7ff978398825b63ddcb13e0572d77564034c1e2` | Prepares VSI provider's fault epoch. | STUB-SAFE(-ENODEV/no-op) | Disabled inline. | None. | KEEP-STUB | Per task fallback branch. | Rockchip provider remains sole GA owner. | 8/54. |
| `vsi_iommu_enable_irq_delivery` | `mpp/mpp_iommu.c:1315@e7ff978398825b63ddcb13e0572d77564034c1e2` | Commits VSI fault delivery after START. | STUB-SAFE(-ENODEV/no-op) | Disabled inline. | None. | KEEP-STUB | Per task fallback branch. | No unsupported AV1 promise. | 8/54. |
| `vsi_iommu_set_fault_handler` | `mpp/mpp_iommu.c:1079,1172@e7ff978398825b63ddcb13e0572d77564034c1e2` | Installs/removes VSI provider-local callback. | STUB-SAFE(-ENODEV/no-op) | Disabled inline; generic handler remains fallback for cookie-less providers. | None. | KEEP-STUB | Activate/teardown fallback. | No unsupported provider lifetime. | 8/54. |
| `vsi_iommu_sync_fault_handler` | `mpp/mpp_iommu.c:1104,1366@e7ff978398825b63ddcb13e0572d77564034c1e2` | Quiesces VSI callback token. | STUB-SAFE(-ENODEV/no-op) | Disabled inline. | None. | KEEP-STUB | Teardown fallback. | No unsupported provider dependency. | 8/54. |
| `iommu_dma_get_iova_domain` | `rga3/rga_dma_buf.c:232@e7ff978398825b63ddcb13e0572d77564034c1e2` | Exposes the DMA domain's real IOVA allocator so scattered USERPTR pages can be mapped into one byte-contiguous hardware span without shadowing the private cookie layout. | REAL-DEPENDENCY | Narrow export from `drivers/iommu/dma-iommu.c` in `integration/0003`; v7.2 has no public equivalent. | Allocation only; no clock or PM effect. | QUICK-WIN (≤1 day drop-in) | RGA USERPTR fallback mapping. | Preserves the validated scattered-page mapping without coupling RGA to a private struct definition. | 8. |
| `reserve_iova_exclusive` | `mpp/mpp_iommu.c:1448`, reached by RKVENC2 RCB SRAM (`mpp_rkvenc2.c:3430`) and RKVDEC2 RCB SRAM (`mpp_rkvdec2.c:1899`) at `e7ff978398825b63ddcb13e0572d77564034c1e2` | Reserves a fixed IOVA only when the entire range is unowned, so teardown cannot free another DMA allocation's overlapping node. | REAL-DEPENDENCY | Narrow `drivers/iommu/iova.c` export in `integration/0003`; plain `reserve_iova()` treats overlap as success and does not preserve ownership. | Probe/task setup only; no clock policy. | QUICK-WIN (≤1 day drop-in) | Encoder/decoder RCB setup and disabled IEP2 auxiliary mapping. | Prevents cross-owner IOVA removal and keeps selected encoder/decoder SRAM mappings safe. | 8; discovered by the first 7.2 compile. |
| `rga_fence_context_init` | `rga3/rga_drv.c:1822@e7ff978398825b63ddcb13e0572d77564034c1e2` | Allocates dma-fence context/sequence state (`rga3/rga_fence.c:26-41@e7ff978398825b63ddcb13e0572d77564034c1e2`). | REAL-DEPENDENCY | Mainline `dma_fence_context_alloc`; `include/linux/dma-fence.h:753@8d3ae59288f1e7d58d76558a6ee96d533bc5019f`. | Negligible probe allocation; independent of clocks/PM. | QUICK-WIN (≤1 day drop-in) | Probe. | Enables real async request timelines if pinned librga emits fences. | 54 probe decides ON; 26 validates if ON. |
| `rga_fence_context_remove` | `rga3/rga_drv.c:1867@e7ff978398825b63ddcb13e0572d77564034c1e2` | Frees fence context (`rga3/rga_fence.c:44-51@e7ff978398825b63ddcb13e0572d77564034c1e2`). | REAL-DEPENDENCY | Normal driver/devm teardown around dma-fence context. | None. | QUICK-WIN (≤1 day drop-in) | Remove. | Balanced async lifetime. | 54/26 if ON. |
| `rga_dma_fence_alloc` | `rga3/rga_job.c:1666@e7ff978398825b63ddcb13e0572d77564034c1e2` | Allocates and initializes one release fence (`rga3/rga_fence.c:53-70@e7ff978398825b63ddcb13e0572d77564034c1e2`). | REAL-DEPENDENCY | `dma_fence_init`; `include/linux/dma-fence.h:275@8d3ae59288f1e7d58d76558a6ee96d533bc5019f`. | Small per-request allocation; no PM impact. | QUICK-WIN (≤1 day drop-in) | Per async request/job. | Nonblocking RGA submissions with completion dependency. | 54/26 if ON. |
| `rga_dma_fence_get_fd` | `rga3/rga_job.c:1728@e7ff978398825b63ddcb13e0572d77564034c1e2` | Wraps release fence in a sync-file fd (`rga3/rga_fence.c:73-93@e7ff978398825b63ddcb13e0572d77564034c1e2`). | REAL-DEPENDENCY | `sync_file_create`; `include/linux/sync_file.h:58@8d3ae59288f1e7d58d76558a6ee96d533bc5019f`. | None. | QUICK-WIN (≤1 day drop-in) | Per async request. | Fence fd consumable by librga/GStreamer. | 54/26 if ON. |
| `rga_get_dma_fence_from_fd` | `rga3/rga_job.c:669@e7ff978398825b63ddcb13e0572d77564034c1e2` | Imports acquire fence from sync-file fd (`rga3/rga_fence.c:96-105@e7ff978398825b63ddcb13e0572d77564034c1e2`). | REAL-DEPENDENCY | `sync_file_get_fence`; `include/linux/sync_file.h:59@8d3ae59288f1e7d58d76558a6ee96d533bc5019f`. | May delay hardware start until producer completes; PM acquired only for runnable job. | QUICK-WIN (≤1 day drop-in) | Per async job. | Zero-copy producer→RGA dependency without CPU waits. | 54/26 if ON. |
| `rga_dma_fence_wait` | definition/API: `rga3/rga_fence.c:107-115@e7ff978398825b63ddcb13e0572d77564034c1e2` (no current imported caller) | Interruptible wait then drops fence reference. | REAL-DEPENDENCY | `dma_fence_wait` + `dma_fence_put`; `include/linux/dma-fence.h:302,736@8d3ae59288f1e7d58d76558a6ee96d533bc5019f`. | Wait path only; no clock selection. | QUICK-WIN (≤1 day drop-in) | Async wait API; currently unused. | Correct future synchronous bridge. | 54 if ON. |
| `rga_dma_fence_add_callback` | `rga3/rga_job.c:726@e7ff978398825b63ddcb13e0572d77564034c1e2` | Arms job when acquire fence signals (`rga3/rga_fence.c:118-128@e7ff978398825b63ddcb13e0572d77564034c1e2`). | REAL-DEPENDENCY | `dma_fence_add_callback`; `include/linux/dma-fence.h:446@8d3ae59288f1e7d58d76558a6ee96d533bc5019f`. | Defers PM/hardware start until dependency is ready. | QUICK-WIN (≤1 day drop-in) | Per async job. | No polling and correct producer ordering. | 54/26 if ON. |
| `rga_dma_fence_remove_callback` | `rga3/rga_job.c:768@e7ff978398825b63ddcb13e0572d77564034c1e2` | Cancels acquire callback when job is torn down (`rga3/include/rga_fence.h:29-33@e7ff978398825b63ddcb13e0572d77564034c1e2`). | REAL-DEPENDENCY | `dma_fence_remove_callback`; `include/linux/dma-fence.h:449@8d3ae59288f1e7d58d76558a6ee96d533bc5019f`. | Teardown only. | QUICK-WIN (≤1 day drop-in) | Per cancelled job. | Prevents callback-after-free. | 54/26 if ON. |
| `rga_dma_fence_put` | `rga3/rga_job.c:686,749,774,1678,1886@e7ff978398825b63ddcb13e0572d77564034c1e2` | Releases acquire/release fence reference. | REAL-DEPENDENCY | `dma_fence_put`; `include/linux/dma-fence.h:302@8d3ae59288f1e7d58d76558a6ee96d533bc5019f`. | None. | QUICK-WIN (≤1 day drop-in) | Per async job/error path. | Leak-free fence ownership. | 54/26 if ON. |
| `rga_dma_fence_signal` | `rga3/rga_job.c:1103,1413,1885@e7ff978398825b63ddcb13e0572d77564034c1e2` | Sets error then signals release fence on success/failure/cancel (`rga3/include/rga_fence.h:42-48@e7ff978398825b63ddcb13e0572d77564034c1e2`). | REAL-DEPENDENCY | `dma_fence_set_error` + `dma_fence_signal`; `include/linux/dma-fence.h:438,686@8d3ae59288f1e7d58d76558a6ee96d533bc5019f`. | Completion only. | QUICK-WIN (≤1 day drop-in) | Per async job terminal path. | Consumers never wedge on an unsignalled release fence. | 54 matrix; 26 board proof if ON. |
| `rga_dma_fence_get_status` | `rga3/rga_job.c:692,1102,1884@e7ff978398825b63ddcb13e0572d77564034c1e2` | Reads completion/error state. | REAL-DEPENDENCY | `dma_fence_get_status`; `include/linux/dma-fence.h:667@8d3ae59288f1e7d58d76558a6ee96d533bc5019f`. | None. | QUICK-WIN (≤1 day drop-in) | Per async job/callback. | Truthful completion/error propagation. | 54/26 if ON. |
| `rga_power_enable_all` | `rga3/rga_drv.c` module lifecycle | Powers every scheduler in vendor global-power builds; the island uses the real per-scheduler runtime-PM loop. | STUB-SAFE(-ENODEV/no-op) | Runtime PM per scheduler. | No loss in the production configuration; `RGA_DISABLE_PM` is unset. | KEEP-STUB | Module/debug lifecycle only. | Avoids a second global power owner. | 54 ledger; 40/55 verify runtime PM. |
| `rga_power_disable_all` | `rga3/rga_drv.c` module lifecycle | Matching vendor global-power teardown; production iterates the real schedulers. | STUB-SAFE(-ENODEV/no-op) | Runtime PM per scheduler. | No loss in the production configuration; `RGA_DISABLE_PM` is unset. | KEEP-STUB | Module/debug lifecycle only. | Balanced per-scheduler ownership. | 54 ledger; 40/55 verify runtime PM. |

## Todo-54 DMA capability table

The programmed address fields, not the CPU physical-address width, decide each
mask. Every MPP address register audited below is one 32-bit word. Consequently
MPP uses `dma_set_mask_and_coherent(DMA_BIT_MASK(32))`; applying the originally
proposed universal 40-bit mask would permit an address that the hardware cannot
represent and would turn a clean allocation failure into silent truncation.

| block | streaming DMA | coherent DMA | descriptor/link/RCB evidence |
|---|---:|---:|---|
| `rkvenc0` | 32 | 32 | Imported IOVAs are written into `u32` task registers (`mpp_rkvenc2.c:256-261,1268-1285`); RCB is one register word and rejects spans above `U32_MAX` (`:1113-1116,3385-3401`). |
| `rkvenc1` | 32 | 32 | Shares the same task-register and RCB implementation; core selection changes scheduling, not address layout (`mpp_rkvenc2.c:1131-1150,1590-1613`). |
| `vdec0` | 32 | 32 | Task registers are `u32`, including translated stream and RCB addresses (`mpp_rkvdec2.h:119-147`; `mpp_rkvdec2.c:331-365,390-407,501-521,1850-1867`). |
| `vdec1` | 32 | 32 | Shares vdec0's register layout; link-table IOVA, next-node, readback and segment pointers are single `u32` entries (`mpp_rkvdec2_link.c:488-507,589-621,742-775`). |
| `jpegd` | 32 | 32 | Registers 9-13 contain the translated addresses as `u32`; there is no separate link/RCB allocator (`mpp_jpgdec.c:71-73,81-94,116-128,224-230`). |
| RGA3 | 40 | 32 | Streaming IOMMU addresses are 40-bit, but coherent command-buffer registers are 32-bit (`rga_drv.c`, `rga3_dma_capability`). |
| RGA2 | 32 | 32 | RGA2 address words and its fail-closed memory-limit path remain 32-bit. |

MPP imports still require one mapped DMA segment and a complete 32-bit IOVA
span (`mpp_iommu.c:122-158`); todo 9's offset guardrail remains unchanged. The
probe now caps `dma_set_max_seg_size()` by `dma_max_mapping_size()`, with
`U32_MAX` as the API's zero/unbounded normalization. RGA's USERPTR and RGA2
staging paths both pass the scheduler device's normalized maximum to
`sg_alloc_table_from_pages_segment()`, so neither silently falls back to a
page-sized or universal segment policy. KUnit's 1 GiB case locks that limit.

## Todo-54 QUICK-WIN completion ledger

Every QUICK-WIN row above resolves to one of these landed commits. Symbols are
listed individually so the promotion column has no implicit wildcard:

| symbol | implementation commit |
|---|---|
| `compat/soc/rockchip/rockchip_iommu.h` | `b88a8eb` — provider media hooks imported as real integration |
| `compat/soc/rockchip/rockchip_ipa.h` | `d92ba95` — deleted |
| `soc/rockchip/rockchip_iommu.h` | `b88a8eb` — real provider header and exports |
| `soc/rockchip/rockchip_ipa.h` | `d92ba95` — deleted |
| `rockchip_iommu_disable` | `b88a8eb` |
| `rockchip_iommu_enable` | `b88a8eb` |
| `rockchip_iommu_enable_irq_delivery` | `b88a8eb` |
| `rockchip_iommu_force_reset` | `b88a8eb` |
| `rockchip_iommu_is_enabled` | `b88a8eb` |
| `rockchip_iommu_mask_irq` | `b88a8eb` |
| `rockchip_iommu_prepare_irq` | `b88a8eb` |
| `rockchip_iommu_set_fault_handler` | `b88a8eb` |
| `rockchip_iommu_sync_fault_handler` | `b88a8eb` |
| `rockchip_iommu_unmask_irq` | `b88a8eb` |
| `rockchip_ipa_get_static_power` | `d92ba95` — deleted with its dead header |
| `rockchip_ipa_power_model_init` | `d92ba95` — deleted with its dead header |
| `iommu_dma_get_iova_domain` | `a10e5bc` — narrow real IOVA-provider export |
| `reserve_iova_exclusive` | `b88a8eb` — exclusive reservation provider export |
| `rga_fence_context_init` | `22d9702` — mainline dma-fence implementation always linked |
| `rga_fence_context_remove` | `22d9702` |
| `rga_dma_fence_alloc` | `22d9702` |
| `rga_dma_fence_get_fd` | `22d9702` |
| `rga_get_dma_fence_from_fd` | `22d9702` |
| `rga_dma_fence_wait` | `22d9702` |
| `rga_dma_fence_add_callback` | `22d9702` |
| `rga_dma_fence_remove_callback` | `22d9702` |
| `rga_dma_fence_put` | `22d9702` |
| `rga_dma_fence_signal` | `22d9702` |
| `rga_dma_fence_get_status` | `22d9702` |

## A14 licence inventory

The repository policy says Yi Ding's kernel-source additions are
`GPL-2.0-or-later` (`LICENSE.md:26-40@ca3da04280c48c004e522c15f31862bf88a2d1b9`),
but explicitly warns that imported files and patch context retain their own
notices (`LICENSE.md:51-66,72-90@ca3da04280c48c004e522c15f31862bf88a2d1b9`).
That distinction is material; the collection policy does not relicense Rockchip
payload.

The checked `LICENSES/` directory contains exactly seven texts:

| file | verified identity |
|---|---|
| `Apache-2.0.txt` | “Apache License / Version 2.0, January 2004” (`:2-4@ca3da04280c48c004e522c15f31862bf88a2d1b9`) |
| `CC-BY-SA-4.0.txt` | “Attribution-ShareAlike 4.0 International” (`:1@ca3da04280c48c004e522c15f31862bf88a2d1b9`) |
| `GPL-2.0-only.txt` | “GNU GENERAL PUBLIC LICENSE / Version 2, June 1991” (`:1-2@ca3da04280c48c004e522c15f31862bf88a2d1b9`) |
| `GPL-2.0-or-later.txt` | “GNU GENERAL PUBLIC LICENSE / Version 2, June 1991” (`:1-2@ca3da04280c48c004e522c15f31862bf88a2d1b9`) |
| `LGPL-2.1-or-later.txt` | “GNU LESSER GENERAL PUBLIC LICENSE / Version 2.1, February 1999” (`:1-2@ca3da04280c48c004e522c15f31862bf88a2d1b9`) |
| `LGPL-3.0-or-later.txt` | “GNU LESSER GENERAL PUBLIC LICENSE / Version 3, 29 June 2007” (`:1-2@ca3da04280c48c004e522c15f31862bf88a2d1b9`) |
| `MIT.txt` | “MIT License” (`:1@ca3da04280c48c004e522c15f31862bf88a2d1b9`) |

Per-file SPDX census, performed over every `.c`/`.h` in the pinned donor paths:

- donor `drivers/video/rockchip/mpp/`: **29/29** files carry
  `SPDX-License-Identifier: (GPL-2.0+ OR MIT)`; representative imported files are
  `mpp_common.c:1`, `mpp_iommu.c:1`, `mpp_rkvenc2.c:1`, `mpp_rkvdec2.c:1`, and
  donor-only `mpp_jpgdec.c:1`, all at `b4ef083dc0c3608e744deabb43dc6b781aadbe6e`;
- donor `drivers/video/rockchip/rga3/`: **24/24** files carry
  `SPDX-License-Identifier: GPL-2.0`; representative files are `rga_drv.c:1`,
  `rga_job.c:1`, `rga_iommu.c:1`, `rga_dma_buf.c:1`, and
  `include/rga_fence.h:1`, all at `b4ef083dc0c3608e744deabb43dc6b781aadbe6e`;
- realized yisding MPP directory: the **20** carried vendor `.c`/`.h` files remain
  `(GPL-2.0+ OR MIT)` and the **7** current yisding-authored compat headers carry
  `GPL-2.0`; no file lacks SPDX;
- realized yisding RGA3 directory: **24/24** files remain `GPL-2.0`; no file
  lacks SPDX.

Therefore the import inherits MPP's dual expression and RGA's GPL-2.0 notice;
the island uses the GPL-2.0 branch only and must not claim an independently
audited MIT grant. New CeraLive integration remains GPL-2.0-only as required by
the later repository bootstrap.

## Completeness and count reconciliation

The original lexical command produced **33** unique `rockchip_*` names. Todo 54
deleted the two dead `rockchip_ipa_*` definitions, so the maintained source now
contains **31**; their two historical rows remain as the auditable deletion
record. The surviving lexical-census-only entries are
`rockchip_dmcfreq_lock_nested` and `rockchip_pmu_block`.

The original source had **8** unique `<soc/rockchip/...>` includes:
`pm_domains.h`, `rockchip_dmc.h`, `rockchip_iommu.h`, historical `rockchip_ipa.h`,
`rockchip_opp_select.h`, `rockchip_sip.h`, `rockchip_system_monitor.h`, and
`vsi_iommu.h`; each has a header row. Patch `0001` created **8** compat headers;
the replayed tree has **7** because `rockchip_iommu.h` graduated into the real
provider contract in `0005`. The island added the disabled VSI provider branch
as an eighth current compat header; todo 54 then deleted dead `rockchip_ipa.h`,
leaving seven. Historical deleted and current real headers both retain rows.

The additional non-`rockchip_*` external dependency census is closed by one
`sip_smc_vpu_reset` row, seven `vsi_iommu_*` rows, two IOVA-provider rows, and
eleven RGA fence rows.
`rk_dma_heap_*` has **zero hits** in both donor and realized MPP/RGA paths; no
phantom row was created. MPP procfs and the RGA debugger are imported internal
code, not shims or unresolved externs; todo 54 makes them required-on rather
than classifying them here as dependencies.

Expected Markdown data-row count is therefore **73** = 17 header-identity rows
(8 original compat paths plus all 8 current `<soc/rockchip/...>` include
spellings plus the island-local VSI shim; four include spellings resolve to
compat files and are intentionally shown both ways) + 33 original Rockchip
lexical symbols + 1 SIP + 7 VSI + 2 IOVA + 11 fence rows + 2 RGA power-helper
rows. This exceeds
the 33-symbol grep denominator for the documented reasons above; `wc -l` alone
is not used to confuse document lines with table rows.

## Todo-7 CI check specification: REAL-DEPENDENCY stubs are forbidden

The future island `shim-lint` must parse `docs/COMPAT.md` as the machine-owned
allow/deny list, not maintain a second symbol list:

1. Parse the table and collect every `symbol` whose class cell is exactly
   `REAL-DEPENDENCY`. Expand the explicitly listed RGA rows individually; do not
   infer wildcard names.
2. Scan `drivers/video/rockchip/mpp/compat/**/*.h` and every island-local
   compatibility header. A REAL-DEPENDENCY symbol may be declared there, but it
   may not be `static inline`, macro-defined, or have a function body there.
   Any body returning `0`, `false`, `NULL`, `ERR_PTR(...)`, `-ENODEV`, or another
   value fails; a `void` empty body fails too. This is structural, not a
   return-text-only grep.
3. Compile and link the selected modules against the pinned v7.2 tree with the
   required `integration/` patches. Declarations without the real provider must
   fail at modpost/undefined-symbol time. The gate passes only when every
   REAL-DEPENDENCY resolves to a non-compat definition in the imported source,
   v7.2, or `integration/`.
4. Independently reject any `<soc/rockchip/...>` include absent from this table,
   and reject any new `rockchip_*` lexical-census symbol absent from the table.
   This makes source growth fail closed until its semantics are classified.
5. Negative non-vacuity fixture: inject
   `static inline int rockchip_iommu_enable(struct device *dev) { return 0; }`
   into a synthetic compat header. `shim-lint` must name
   `rockchip_iommu_enable`, cite its REAL-DEPENDENCY row, and fail before the
   module build. Deleting the body and omitting todo 8's provider integration
   must then fail the link, proving both halves of the gate.

This enforces the invariant: **a compile can never succeed by silently replacing
a REAL-DEPENDENCY with a compatibility stub.**
