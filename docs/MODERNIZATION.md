# Linux 7.2 modernization

Source changes are UAPI-frozen. KUnit runs on UML and is distinct from board
evidence. The owner-authorized matching-config module experiment now includes a
real Rock 5B+ camera A/B measurement; its limits and failed cost gate are below.

| Item | Source status | Proof |
|---|---|---|
| (a) Fault logging | Shared per-device budget on the common MPP, selected-client IRQ/reset, and RGA fault paths | `media_fault_storm_test`: 1,000 direct log calls admit 10 lines in the five-second burst window; UML 57/57. Probe diagnostics are not rate limited |
| (b) Wedge snapshots | ≤4 KiB text snapshots, IRQ-safe capture and deferred vzalloc/submission; last eight lifecycle events | `media_dump_submission_owns_buffer_test` uses CONFIG_DEV_COREDUMP=y, checks task=42 in formatted data, a real sysfs devcoredump link, and no retained buffer pointer after submission; UML 58/58 |
| (c) Recovery epochs / bulk resets | Managed optional exclusive reset lists; epoch claims in common MPP and RGA recovery | `media_recovery_concurrent_epoch_test`: two kernel threads, 2,000 attempts, one claim. `media_recovery_later_epoch_test`: a new start permits a second claim and rejects stale epochs. UML 60/60 |
| (d) Deferred resource diagnostics | Named probe errors for clocks, interrupts, IOMMU and power domains; provider deferrals propagated | `media_probe_names_deferred_resource_test` checks the kernel's stored deferred-probe reason names iommus provider and aclk_vcodec, retaining -EPROBE_DEFER; UML 61/61 |
| (e) Request sizing | Checked multiplication; variable-sized RGA request/pool/job arrays use kvzalloc with kvfree on every exit | `media_request_size_rejects_overflow_test`: SIZE_MAX / sizeof(u64) + 1 returns -EINVAL and clears the size; 64 KiB boundary accepted. UML: 55/55 passed |
| (f) iosys_map | Raw mapping state replaced; legacy dma-buf vmap and PDE_DATA branches removed | `media_map_lifetime_test` covers page mapping cleanup; `media_mapping_preserves_exporter_map_test` uses a real dma-buf exporter and checks its I/O map survives until the exact unmap and is then cleared. UML 62/62; selected MPP/RGA objects sparse C=2 with -Wsparse-error clean; raw-vmap/PDE_DATA grep empty |
| (g) Mapping cost decision | NOT-WORTH-IT on the measured steady-state MPP camera workload; no iommu_map_sg change | [Board experiment](MODERNIZATION-BASELINE.md#item-g-measured-below-threshold-on-this-workload): 0 of 412 attributed setup samples, 0.00% observed cycle-period share; sampling is not a claim of universally zero mapping time |

## Fault logging

Runtime fault macros use `dev_err_ratelimited` behind a shared device limiter,
including register-dump lines. This avoids multiplying the burst by the number
of register addresses or fault call sites. Explicit operator-enabled debug
tracing remains separate. The first 10 diagnostic lines are retained; structured
wedge snapshots are the intended source of complete register evidence.

## Request sizing

MPP consumes individual fixed-sized messages, not a count-sized message allocation.
Its register-offset array copy now uses the same checked size helper as RGA's pool
imports/releases and job copies. RGA request-array copies use `array_size`, whose
overflow result cannot become a small allocation. Coherent command arrays retain
the DMA allocator (vmalloc memory cannot replace coherent device memory); their
nested products use `array_size`. No ioctl values or public structures changed.

## Wedge evidence and image requirement

MPP task errors (including IRQ timeout and reset-after-fault) and RGA timeout/
reset paths copy status/config registers, task/core identity, one active IOVA
window and an eight-event lifecycle ring before reset can erase the registers.
MPP names the first task memory window; RGA names the command-buffer window.
The snapshot worker owns no task or DMA-buffer pointer. It allocates with
`vzalloc`; the core owns that allocation after `dev_coredumpv` returns. Device
teardown cancels the worker before freeing the embedded state.

Both driver Kconfigs select `WANT_DEV_COREDUMP`. The image-side kernel fragment
must include **CONFIG_DEV_COREDUMP=y** (with ALLOW_DEV_COREDUMP enabled) when this
series is adopted through the consumer's island lane. No image repository is
changed here. KUnit explicitly enables the real implementation rather than its
vfree-only stub.

The live timeout → `/sys/class/devcoredump/devcd*/data` → five-minute kernel
expiry drill remains **unrun**. The board follow-up exercises normal encoding
with the modified MPP module, not fault injection or expiry. UML tests prove
submission/ownership and the sysfs link; they do not fill that hardware gap.

The dedicated encoder result-wait timeout and the decoder link/soft-CCU/hard-CCU
timeout and IOMMU paths also capture through `mpp_dump_task`. MMIO is sampled
only while a runtime-PM reference is available; a late userspace timeout after
power-down records metadata with zero registers instead of touching an unpowered
block. The kernel buffer is self-contained before queued work can outlive the task.

## Mapping ownership

RGA staging retains its RAM-only map as an `iosys_map`; exporter maps use the
reservation-locking `_unlocked` dma-buf wrappers. Debug reads and image dumps use
iosys accessors rather than interpreting an I/O mapping as a normal pointer.
Retained RKVDEC-v1 PPS access also uses the reservation-locking wrappers and
iosys accessors. It is not a selected production client; the selected-object
sparse result does not claim to compile that dormant client.

The live sysfs and exporter hardware drills remain separate from UML ownership
tests. No driver or KUnit test changes public structures or ioctl numbers.

## Probe diagnostics

The shared probe helper routes errors through `dev_err_probe`. The UML test
inspects the driver's stored deferred reason, not an invented journal excerpt.
An absent optional clock remains optional; a DT-named clock whose provider is
deferred must defer the decoder/JPEG probe instead of silently continuing with
a NULL clock. A missing IOMMU provider device and deferred provider IRQ also
retain their deferral. Invalid/missing IOMMU phandles remain configuration errors.
The deliberately dangling-phandle board drill remains a separate, unrun exercise.

## Recovery ordering

MPP acquires its device-local reset list in one managed bulk operation. Shared
reset-group controls deliberately retain their existing group owner. The three
selected clients use bulk assert/deassert while preserving their distinct
deassert order (the Linux bulk API walks that list in reverse). MPP serializes
recovery through a mutex and returns the saved error to duplicate callers;
existing PMU-idle, IRQ masking, IOMMU refresh and task failure paths remain.

RGA serializes the recovery claim under the existing IRQ lock. Its RK3588 CRU
reset provider is MMIO-only; this atomic path must not be generalized to a
sleeping reset provider. With reset controls present the backend performs a bulk
cycle inside the existing IOMMU-register save/restore boundary; absent optional
controls retain the register-reset fallback. Existing job-mutex and power-reference
ownership remains with the callers. Each hardware task start opens a fresh epoch;
repeated faults in that epoch cannot trigger another reset sequence.

Default MPP, link, both decoder CCU modes and the decoder's pre-suspend reset
enter the same `mpp_hw_recover` owner. Mode-specific callbacks retain their own
stop/mask/reset/IOMMU/restore sequence rather than losing those differences in a
generic bulk call. The common task-run boundary advances epochs for linked tasks
as well as the default worker.

These unit proofs exercise recovery ownership, not silicon reset efficacy. A
dedicated reset/fault drill must still establish the latter.

## Board compatibility: matching modules were actually inserted

The initial factory/module absence did not make the board unusable. The full
`/proc/config.gz` was captured; both PR modules were built against the same pinned
Linux commit using the board's GCC 14.2.0-19/binutils 2.44. Normal insertion with
exact matching vermagic succeeded for **MPP (exit 0)**. Both encoder cores, both
decoder cores and JPGDEC probed, `/dev/mpp_service` appeared, and a fresh private
GStreamer registry exposed the hardware factories.

**RGA insertion exited 1, `Bad address`:** its init reported
`rga_iommu_bind, binding map scheduler failed!` and `rga iommu bind failed!`.
The live DT has `rockchip,rk3588-rga3` / `rockchip,rk3588-rga` compatibles, whereas
the island expects its `rockchip,rga3_core*` / `rockchip,rga2_core0` identities.
No mapping scheduler binds. This is a DT ownership-integration mismatch, **not**
an ABI, CRC, missing-symbol or mainline-version mismatch. Force-loading would
not change it and the board has `CONFIG_MODULE_FORCE_LOAD=n` anyway.

The recorded image provenance pins the same Linux base and island v2026.9.0;
the board had installed `rk_vcodec.ko` and older `rga3.ko`, not an absence of all
island source. Kernel stamp `@1788474771` matches the image-builder commit date,
not the Linux commit date. Exact provenance, config delta, hashes, insertion
commands and kernel messages are in [MODERNIZATION-BASELINE.md](MODERNIZATION-BASELINE.md).

## Cost gate — measured, NOT PASSED

Perf 6.12.107 was installed after working around the board's captive-portal
download failure with SHA-256-verified Debian packages transferred over SSH.
The real HDMI camera was captured on `/dev/video1` at 3840×2160 NV16/59.94 Hz,
software-converted to 1920×1080 NV12, and hardware-encoded with `mpph264enc`.
Before/after used independently built `10894bc` / `0ec331c` MPP modules on the
same running kernel/config/toolchain, with CPU affinity 4–7 and unchanged
performance governors.

Three trials per variant were retained. One pre-PR trial produced 599 of 600
frames and remains a failed frame-count check. The equal-frame trial means were
**8418.555 ms before** (n=2) and **8637.150 ms after** (n=3) of perf task-clock:
an observed **+2.596586%**, above 1%. The valid baseline spans **5.044215%**,
so this pilot does not isolate a causal modernization cost. It is not acceptable
to claim the budget passed or assign the difference to a particular item.

The whole-series qualification also remains incomplete: RGA could not bind,
the software conversion/live scene affects CPU cost, and per-process task-clock
does not include all asynchronous kernel workers. See the full table, frame
failures, profiling method and scope in
[MODERNIZATION-BASELINE.md](MODERNIZATION-BASELINE.md). The earlier Orange-only
baseline and blanket "after comparison unavailable" conclusion are superseded
by this real but non-qualifying Rock experiment.

The test-owned MPP module was unloaded successfully at the end, restoring the
initial unloaded state. Perf remains installed; the expected out-of-tree kernel
taint persists until reboot. No reboot, driver override, persistent module
replacement, DTB update or boot-state change was performed.

## Review corrections and source wiring proof

The initial independent review rejected missing encoder/link timeout hooks,
decoder-link recovery bypasses, leftover selected-path fault logs, and the MPP
buffer pool's loss of the dma-buf map tag. The follow-up source corrections cover
those paths. `scripts/check-modernization.py --self-test` now rejects five
mutations: missing encoder snapshot, private link recovery, missing epoch advance,
loss of the persistent iosys_map, and unbounded timeout output. This source check
complements UML; neither substitutes for a board drill.

LSP was attempted on all changed C files. A subsequent standalone compiler and
history comparison established that the intentionally unselected RKVDEC-v1
source has the **same eight diagnostic classes before and after this PR**.
The failing call sites blame to the original import; the PR's scaling-list
changes introduce no additional diagnostic. This is out of scope by policy,
not an unfinished modernization requirement. See
[RKVDEC-V1-DIAGNOSTICS.md](RKVDEC-V1-DIAGNOSTICS.md) for exact base/PR lines,
compiler errors and blame evidence. No additional dormant-client port fix or
enablement was made in the follow-up.
