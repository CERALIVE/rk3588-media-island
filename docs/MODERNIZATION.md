# Linux 7.2 modernization

Source changes are UAPI-frozen. KUnit runs on UML; it does not prove a flashed
board. Hardware deployment and the after-change cost comparison are separate
drills, not part of this source series.

| Item | Source status | Proof |
|---|---|---|
| (a) Fault logging | Shared per-device budget on the common MPP, selected-client IRQ/reset, and RGA fault paths | `media_fault_storm_test`: 1,000 direct log calls admit 10 lines in the five-second burst window; UML 57/57. Probe diagnostics are not rate limited |
| (b) Wedge snapshots | ≤4 KiB text snapshots, IRQ-safe capture and deferred vzalloc/submission; last eight lifecycle events | `media_dump_submission_owns_buffer_test` uses CONFIG_DEV_COREDUMP=y, checks task=42 in formatted data, a real sysfs devcoredump link, and no retained buffer pointer after submission; UML 58/58 |
| (c) Recovery epochs / bulk resets | Managed optional exclusive reset lists; epoch claims in common MPP and RGA recovery | `media_recovery_concurrent_epoch_test`: two kernel threads, 2,000 attempts, one claim. `media_recovery_later_epoch_test`: a new start permits a second claim and rejects stale epochs. UML 60/60 |
| (d) Deferred resource diagnostics | Named probe errors for clocks, interrupts, IOMMU and power domains; provider deferrals propagated | `media_probe_names_deferred_resource_test` checks the kernel's stored deferred-probe reason names iommus provider and aclk_vcodec, retaining -EPROBE_DEFER; UML 61/61 |
| (e) Request sizing | Checked multiplication; variable-sized RGA request/pool/job arrays use kvzalloc with kvfree on every exit | `media_request_size_rejects_overflow_test`: SIZE_MAX / sizeof(u64) + 1 returns -EINVAL and clears the size; 64 KiB boundary accepted. UML: 55/55 passed |
| (f) iosys_map | Raw mapping state replaced; legacy dma-buf vmap and PDE_DATA branches removed | `media_map_lifetime_test` covers page mapping cleanup; `media_mapping_preserves_exporter_map_test` uses a real dma-buf exporter and checks its I/O map survives until the exact unmap and is then cleared. UML 62/62; selected MPP/RGA objects sparse C=2 with -Wsparse-error clean; raw-vmap/PDE_DATA grep empty |
| (g) Mapping cost decision | UNMEASURABLE ON THIS BOARD: no perf binary; Rock also lacks exposed trace events and an available hardware encoder | [Baseline transcript](MODERNIZATION-BASELINE.md). No percentage inferred; no iommu_map_sg change made, and NOT-WORTH-IT is not claimed |

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
expiry drill is **deferred until a modified kernel is deployed**. UML tests
submission/ownership and the sysfs link, not the board timeout or expiry timer.

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
The deliberately dangling-phandle board drill remains a post-flash exercise.

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

These unit proofs exercise recovery ownership, not silicon reset efficacy. The
post-flash reset/fault drill must still establish the latter.

## Cost gate — PARTIAL

On 2026-09-05 the live Rock 5B+ was reachable at its corrected address, but had
no `/dev/mpp_service`, no loaded island modules, and no `mpph264enc` factory.
No module was loaded and no board state was changed to make a measurement work.

Orange Pi 5+ did complete a real, pre-change 1080p60 H.264 encode: 1,200 source
buffers, EOS, **20.430 s elapsed, 6.322 s user CPU, 5.402 s system CPU**.
This uses Bash's `time` resource accounting because `perf` is absent. The exact
command, kernel identity, output and limits are in [MODERNIZATION-BASELINE.md](MODERNIZATION-BASELINE.md).

**PARTIAL: baseline measured; after-change comparison deferred to a future
board-flash drill.** No modified module or kernel was deployed. There is no
measured delta and no ≤1% acceptance claim. This single run is not a variance
study and cannot attribute an iommu_map fraction; a controlled before/after
campaign on the same board and kernel configuration remains required.

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
compiler errors and blame evidence. No dormant-client fix or enablement was made.
