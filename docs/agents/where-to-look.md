<!-- Moved verbatim from AGENTS.md on 2026-10-05 by lean-rules-docs-landing-latam -->

## WHERE TO LOOK

| Task | Location |
|------|----------|
| Find out what a CI job asserts, or why one is currently vacuous | [`docs/CI.md`](../CI.md) |
| Regenerate the series after changing `drivers/` or `integration/` | `scripts/build-series.py` — then `--check` and `scripts/verify-series-parity.py` |
| Change the target kernel | **Not here.** Bump [`rk3588-kernel-patches/kernel-pin.env`](https://github.com/CERALIVE/rk3588-kernel-patches/blob/main/kernel-pin.env) first, then mirror it into [`kernel-pin.env`](../../kernel-pin.env) |
| Decide which driver owns a silicon block | [`docs/OWNERSHIP.md`](../OWNERSHIP.md) |
| Classify an external symbol the drivers call | [`docs/COMPAT.md`](../COMPAT.md) |
| Find where a source file came from | [`docs/PROVENANCE.md`](../PROVENANCE.md) |
| Audit Rockchip fixes after the donor snapshot | [`docs/VENDOR-BACKLOG.md`](../VENDOR-BACKLOG.md) and `scripts/vendor-backlog.sh --check` |
| Look up a pinned upstream SHA | [`docs/REFERENCES.md`](../REFERENCES.md) |
| See whether mainline has caught up on a block | [`docs/UPSTREAM-STATUS.md`](../UPSTREAM-STATUS.md) |
| Know what a board must demonstrate before a tick | [`docs/BOARD-QUALIFICATION.md`](../BOARD-QUALIFICATION.md) |
| Orange Pi merged PR #150 candidate evidence (OTA/ownership pass, HDMI converter failure, incomplete recovery/benchmark qualification) | [`docs/qualification/orange-pi-98f9f198-2026-09-06.md`](../qualification/orange-pi-98f9f198-2026-09-06.md); ten-class inventory in `tests/board/usb-matrix.yaml` |
| Orange Pi round 3 / PR #152 candidate (installed RGA factories, real-capture benchmarks and component recovery; UI admission still fails) | [`docs/qualification/orange-pi-1f56ca03-round3-2026-09-06.md`](../qualification/orange-pi-1f56ca03-round3-2026-09-06.md); prior microphone evidence is retained in `tests/board/usb-matrix.yaml` |
| RGA probe version-return / raster-mode regressions and their hardware limits | [`tests/board/README.md`](../../tests/board/README.md) — `make -C tests/board selftest` includes intercepted-ioctl regressions |
| Measure forced-IDR latency | `tests/board/idr-latency.sh` — local engine IPC requester plus offline NAL/PTS scorer; collector and same-host clock requirements in [`tests/board/README.md`](../../tests/board/README.md#forced-idr-measurement). Self-test is not board proof. |
| Look up a fault control, its counter, its errno, its call site or the row that consumes it | [`docs/FAULT-SEAM-CONTRACT.md`](../FAULT-SEAM-CONTRACT.md) — the authoritative table, plus the `T4` vocabulary every ledger cell is written in |
| Run the 16-row island fault matrix on a board | `tests/board/fault-matrix.sh --driver island` — `--self-test` scores committed island fixtures and still prints `16 MPP rows registered` |
| Run the separate four-row RGA fault matrix | `tests/board/fault-matrix.sh --driver island-rga --probe-rga <binary>` — default-off `ROCKCHIP_RGA_CERALIVE_TEST`; host-tested source, **not board-qualified**. Contract and limits in `docs/FAULT-SEAM-CONTRACT.md`. |
| Prove the five controls no matrix row consumes, or the explicit-only idle-window row | `tests/board/fault-controls-probe.sh` (`--row all` is the five; `--row idle-iommu-fault` is the separate experiment) |
| Run a long-duration media soak and score its slope rules | `tests/board/soak.sh` — 60 s sampling into a CSV, then one literal verdict; `--self-test` scores committed fixtures on a dev host |
| Read what those drills actually measured on silicon | [`docs/FAULT-CAMPAIGN.md`](../FAULT-CAMPAIGN.md) → "Fault-seam contract and the 2026-09 campaigns" |
| Understand which licence branch applies to a file | [`LICENSE.md`](../../LICENSE.md) |
| Build the modules | [`README.md`](../../README.md) → "Building the modules" |
| MPP static-analysis dispositions and instrumented KUnit coverage | [`docs/HARDENING-FINDINGS.md`](../HARDENING-FINDINGS.md) — helper tests are not silicon validation |
| Linux 7.2 modernization and proof boundaries | [`docs/MODERNIZATION.md`](../MODERNIZATION.md) |
| Direct ioctl boundary KUnit, source staging, and coverage limits | [`docs/IOCTL-BOUNDARY-TESTS.md`](../IOCTL-BOUNDARY-TESTS.md) |
| Runtime-PM autosuspend policy and get/put ownership audit | [`docs/RUNTIME-PM-AUDIT.md`](../RUNTIME-PM-AUDIT.md) — all eleven nodes, software-only exceptions, and KUnit regressions; no thermal verdict |
| RGA table ownership, high-memory routing and software regressions | [`docs/RGA-MEMORY-ADDRESSABILITY.md`](../RGA-MEMORY-ADDRESSABILITY.md) — job-owned tables, early legacy preparation and bounded staging; source-only, no release or board qualification; H7 causality remains unproven |
| RGA job ownership between commit publication and completion | [`docs/RGA-JOB-LIFETIME.md`](../RGA-JOB-LIFETIME.md) — the committer's own reference across queue publication, and the host sanitizer reproducer that proves it; software ownership only, no DMA/IRQ/PM emulation |
| Add a compat shim | `drivers/video/rockchip/mpp/compat/` — and add its row to `docs/COMPAT.md`, or the lint refuses the build |
| Change a device-tree node's owner | `integration/` — and update the `docs/OWNERSHIP.md` row in the same change |

