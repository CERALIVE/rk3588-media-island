# Linux 7.2 modernization

Source changes are UAPI-frozen. KUnit runs on UML; it does not prove a flashed
board. Hardware deployment and the after-change cost comparison are separate
drills, not part of this source series.

| Item | Source status | Proof |
|---|---|---|
| (a) Fault logging | Pending | Pending |
| (b) Wedge snapshots | Pending | Pending |
| (c) Recovery epochs / bulk resets | Pending | Pending |
| (d) Deferred resource diagnostics | Pending | Pending |
| (e) Request sizing | Checked multiplication; variable-sized RGA request/pool/job arrays use kvzalloc with kvfree on every exit | `media_request_size_rejects_overflow_test`: SIZE_MAX / sizeof(u64) + 1 returns -EINVAL and clears the size; 64 KiB boundary accepted. UML: 55/55 passed |
| (f) iosys_map | Pending | Pending |
| (g) Mapping cost decision | Pending measurement record | No mapping change authorized without a measured ≥5% fraction |

## Request sizing

MPP consumes individual fixed-sized messages, not a count-sized message allocation.
Its register-offset array copy now uses the same checked size helper as RGA's pool
imports/releases and job copies. RGA request-array copies use `array_size`, whose
overflow result cannot become a small allocation. Coherent command arrays retain
the DMA allocator (vmalloc memory cannot replace coherent device memory); their
nested products use `array_size`. No ioctl values or public structures changed.

## Cost gate

Pending baseline record. No after-change comparison has been taken.
