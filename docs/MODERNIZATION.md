# Linux 7.2 modernization

Source changes are UAPI-frozen. KUnit runs on UML; it does not prove a flashed
board. Hardware deployment and the after-change cost comparison are separate
drills, not part of this source series.

| Item | Source status | Proof |
|---|---|---|
| (a) Fault logging | Shared per-device budget on the common MPP, selected-client IRQ/reset, and RGA fault paths | `media_fault_storm_test`: 1,000 direct log calls admit 10 lines in the five-second burst window; UML 57/57. Probe diagnostics are not rate limited |
| (b) Wedge snapshots | ≤4 KiB text snapshots, IRQ-safe capture and deferred vzalloc/submission; last eight lifecycle events | `media_dump_submission_owns_buffer_test` uses CONFIG_DEV_COREDUMP=y, checks task=42 in formatted data, a real sysfs devcoredump link, and no retained buffer pointer after submission; UML 58/58 |
| (c) Recovery epochs / bulk resets | Pending | Pending |
| (d) Deferred resource diagnostics | Pending | Pending |
| (e) Request sizing | Checked multiplication; variable-sized RGA request/pool/job arrays use kvzalloc with kvfree on every exit | `media_request_size_rejects_overflow_test`: SIZE_MAX / sizeof(u64) + 1 returns -EINVAL and clears the size; 64 KiB boundary accepted. UML: 55/55 passed |
| (f) iosys_map | Raw mapping state replaced; legacy dma-buf vmap and PDE_DATA branches removed | `media_map_lifetime_test`: real page vmap, bounded read, unmap clears ownership, repeated cleanup safe. UML 56/56; selected MPP/RGA objects sparse C=2 with -Wsparse-error clean; raw-vmap/PDE_DATA grep empty |
| (g) Mapping cost decision | Pending measurement record | No mapping change authorized without a measured ≥5% fraction |

## Request sizing

Runtime fault macros use `dev_err_ratelimited` behind a shared device limiter,
including register-dump lines. This avoids multiplying the burst by the number
of register addresses or fault call sites. Explicit operator-enabled debug
tracing remains separate. The first 10 diagnostic lines are retained; structured
wedge snapshots are the intended source of complete register evidence.

MPP consumes individual fixed-sized messages, not a count-sized message allocation.
Its register-offset array copy now uses the same checked size helper as RGA's pool
imports/releases and job copies. RGA request-array copies use `array_size`, whose
overflow result cannot become a small allocation. Coherent command arrays retain
the DMA allocator (vmalloc memory cannot replace coherent device memory); their
nested products use `array_size`. No ioctl values or public structures changed.

## Mapping ownership

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

RGA staging retains its RAM-only map as an `iosys_map`; exporter maps use the
reservation-locking `_unlocked` dma-buf wrappers. Debug reads and image dumps use
iosys accessors rather than interpreting an I/O mapping as a normal pointer.
Retained RKVDEC-v1 PPS access also uses the reservation-locking wrappers and
iosys accessors. It is not a selected production client; the selected-object
sparse result does not claim to compile that dormant client.

The live sysfs and exporter hardware drills remain separate from UML ownership
tests. No driver or KUnit test changes public structures or ioctl numbers.

## Cost gate

Pending baseline record. No after-change comparison has been taken.
