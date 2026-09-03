# Deliberate compatibility stubs

This ledger mirrors every `KEEP-STUB` row in `docs/COMPAT.md`. A stub remains
only while its stated GA precondition is true; the reopening condition prevents
“keep” from becoming an unbounded deferral. The compatibility table contains 29
`KEEP-STUB` rows: the original 27 plus the two RGA global-power helpers made
explicit by todo 54.

| symbol or header | why it stays stubbed | what would reopen it |
|---|---|---|
| `compat/linux/rockchip/rockchip_sip.h` | The ignored SIP result is not the live reset; CRU reset is. | Mainline firmware exposes a required, validated VPU-reset SMC contract. |
| `compat/rockchip_pmu_idle.h` | Every island node sets `rockchip,skip-pmu-idle-request`, so the call is unreachable. | Island DT removes the bypass and qualification proves an explicit PMU idle request is required. |
| `compat/rockchip_qos_compat.h` | Mainline genpd owns sequencing and reset defaults are accepted. | Reset qualification shows QoS state must survive CRU reset. |
| `compat/soc/rockchip/rockchip_dmc.h` | Decoder reset does not import the vendor global DMC semaphore. | A reproducible DDR-devfreq/reset race appears. |
| `soc/rockchip/pm_domains.h` | Direct-PD operations are PX30-only; runtime PM owns RK3588. | A selected RK3588 client requires direct domain control. |
| `soc/rockchip/rockchip_dmc.h` | The header side of DMC serialization is intentionally absent. | Decoder recovery requires DMC frequency exclusion. |
| `soc/rockchip/rockchip_sip.h` | No declaration in this header is consumed. | A rebase introduces a live SIP dependency. |
| `soc/rockchip/vsi_iommu.h` | VSI/AV1 is outside the three-client GA closure. | A VSI-backed client is selected for a later release. |
| `compat/soc/rockchip/vsi_iommu.h` | The disabled fallback lets Rockchip-IOMMU clients compile without pretending VSI exists. | The VSI provider becomes a supported dependency. |
| `rockchip_dmcfreq_lock` | CRU reset is the live path without a board-wide DMC lock. | Reset/DDR-frequency qualification reproduces a race. |
| `rockchip_dmcfreq_lock_nested` | Lexical-census-only; no caller exists. | A selected client adds a caller. |
| `rockchip_dmcfreq_unlock` | It pairs with the deliberately absent DMC lock. | DMC lock coordination is implemented. |
| `rockchip_pmu_block` | Lexical-census-only comment hit; no caller exists. | A selected runtime path adds a caller. |
| `rockchip_pmu_idle_request` | The DT bypass short-circuits before this function on every island node. | The DT bypass is removed and the PMU handshake is hardware-proven. |
| `rockchip_pmu_pd_is_on` | PX30-only disabled hack path. | That client and direct-PD path become supported. |
| `rockchip_pmu_pd_off` | PX30-only disabled direct power-off path. | A supported RK3588 path needs direct power-off. |
| `rockchip_pmu_pd_on` | PX30-only disabled direct power-on path. | A supported RK3588 path needs direct power-on. |
| `rockchip_restore_qos` | Hardware defaults after CRU reset are accepted. | Qualification shows a required QoS value is lost. |
| `rockchip_save_qos` | No reset-time QoS snapshot is needed on the mainline path. | Qualification proves save/restore is required. |
| `sip_smc_vpu_reset` | Callers ignore its result and execute the CRU reset path; mainline TF-A has no promised SIP ABI. | Firmware publishes and qualification requires the SMC contract. |
| `vsi_iommu_refresh` | Rockchip IOMMU is the sole GA provider. | A VSI-backed client is enabled. |
| `vsi_iommu_mask_irq` | VSI fault delivery is absent. | VSI fault IRQ ownership becomes supported. |
| `vsi_iommu_unmask_irq` | VSI fault delivery is absent. | VSI recovery becomes supported. |
| `vsi_iommu_prepare_irq` | VSI fault epochs are unused. | VSI task admission becomes supported. |
| `vsi_iommu_enable_irq_delivery` | No selected client commits VSI delivery after START. | A selected VSI client requires it. |
| `vsi_iommu_set_fault_handler` | VSI provider-local callbacks are disabled. | VSI callback ownership enters the supported ABI. |
| `vsi_iommu_sync_fault_handler` | No VSI callback token exists to quiesce. | VSI callback teardown becomes supported. |
| `rga_power_enable_all` | The `RGA_DISABLE_PM` fallback is never selected; production acquires runtime PM per scheduler. | A supported build intentionally disables scheduler runtime PM. |
| `rga_power_disable_all` | The matching disabled-PM fallback is unreachable in the island configuration. | A supported build intentionally disables scheduler runtime PM. |

RGA's production `rga_power_enable_all()` and `rga_power_disable_all()` bodies
are real per-scheduler loops. Only their `RGA_DISABLE_PM` compile-time fallback
is retained as a no-op; it is not part of the release configuration.
