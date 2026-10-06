<!-- Moved verbatim from AGENTS.md on 2026-10-05 by lean-rules-docs-landing-latam -->

## KEY FACTS

**Shipped reality, recorded 2026-09-21: the island is on a booted production
slot, not only in a pinned series.** Six tags exist, `v2026.9.0` through
`v2026.9.5`. `rk3588-kernel-patches` PR #25 (`6996f96bc883f637ddac11f81871a256632f3f48`)
carries the `v2026.9.5` asset byte-preserved in its `island/` lane (source commit
`836db612`, asset sha256 `364c4afd…`), and `image-building-pipeline` master pins
that commit as `patches_commit`. On 2026-09-21 the Rock 5B+ and the Orange Pi 5+
each promoted the image built from that pin to RAUC slot A, booted
`linux-image-7.2.0-ceralive-rk3588 7.2.0-ceralive1` from it with `systemctl
--failed` empty and `ceralive-healthcheck.service` self-marking the slot good with
the current boot's own `boot-id`, and kept the previous production payload on slot
B as the rollback. So the island's `rk_vcodec` owns the encoder, both decoders and
`jpegd`, and `multi_rga` owns RGA3 core0/core1 and RGA2, on the kernel both bench
boards run today. What that boot does NOT prove is unchanged: every fault-matrix,
probe, soak and composition row keeps the verdict its own ledger records, and the
board rule below ("every board result names its board, kernel build and island
tag") is exactly why a clean boot is a boot receipt and not a tick.

**RGA reset failure is fail-stop, not successful cancellation.** Backend reset
status gates cleanup; an unsuccessful reset retains the running job's mappings,
tables, command buffer and power reference until reboot. The failed core admits
no new work; module pinning and suppressed bind/unbind attributes preserve its
device lifetime. Low DMA-BUF/USERPTR execution on RGA2 requires an RGA2-owned
mapping and DMA-address PTEs, even below 4 GiB. Per-core queues cap at 32 jobs,
expire before start at 1,000 ms, and synchronous timeout cancels queued work.
Details and software proof limits: [`docs/RGA-MEMORY-ADDRESSABILITY.md`](../RGA-MEMORY-ADDRESSABILITY.md).
The timing and low-USERPTR KUnit fixtures are mutation-checked: prior-epoch
claims, literal 1,000 ms and captured wait jiffies, and nonidentity execution
DMA PTEs. See [`docs/verification/rga-round2-regression-locks.md`](../verification/rga-round2-regression-locks.md)
for individual RED/restored-GREEN receipts; production source was unchanged.

**MPP core debugfs follows the device lifetime.** `mpp_dev_remove()` drains
per-core counter readers before devres frees their client context. Telemetry
probe-error unwind removes clients before their parent debugfs tree; the
module-static fault counters have a separate lifetime. The carried regression
suite is `tests/kunit/mpp_debugfs_test.c`; see `docs/TELEMETRY.md`.

**RGA fault injection is independent and default-off.** Four one-shot controls in
`rga3/rga_test.{c,h}` mirror the MPP atomic/debugfs pattern without changing MPP.
Timeout and hang suppress START; IOMMU injection calls the real callback without
invalid DMA; reset failure changes only the debugger write result after abort.
KUnit compiles the controls and byte-preserved driver functions with hardware
fixtures, plus config-off stubs. The separate `island-rga` harness requires an
isolated RGA device and reports absent busy/mapping counters as GAPs. No production
fragment enables it and no board result is claimed. The rewrite remains deferred.

**MPP discovery has a narrow legacy scalar shape.** HW_SUPPORT and CMD_SUPPORT
accept size/offset/flags all zero and still access one checked user `u32`.
Other scalar commands require size four; unsupported clients and wrong-hardware
register ranges remain rejected. This is an ioctl compatibility fix, separate
from idle-fault instrumentation. See `docs/IOCTL-BOUNDARY-TESTS.md`.

**Idle IOMMU instrumentation is test-only and not board-qualified.** The optional
`inject_iommu_fault_idle_ms` control owns delayed work in each encoder's device
context, serializes enqueue with disable, cancels before teardown/system sleep,
and records PM status at callback time without resuming the device. Its probe is
explicitly `fault-controls-probe.sh --row idle-iommu-fault`, never a matrix row
or part of the five-control `--row all` sweep. See `docs/FAULT-CAMPAIGN.md` for
the direct-callback boundary and current proof limits.

**The maintained fault seam has a written contract.** [`docs/FAULT-SEAM-CONTRACT.md`](../FAULT-SEAM-CONTRACT.md)
is the authoritative table: nine controls plus the `target_session_pid`
selector, each one's consumed counter, injected effect, errno and island call sites, the harness row that consumes it, the sixteen matrix rows, and the
`T4` literals a ledger cell may carry. Two of its findings drive everything
downstream — the matrix arms only FOUR controls, because
`rkvenc-invalid-ioctl --all-malformed` skips `session-allocation-failure`
(`NOT-IN-MATRIX`), and the other five had never been board-proven on the island
at all, which is why `fault-controls-probe.sh` exists.

**Matrix verdicts follow final journal validation, never precede it.** Both
captures check command status, and both journal screens distinguish a match
from no-match and scanner failure. `journal-capture` / `journal-scan` fail closed
and stop the campaign even if the available text looks clean; a later successful
capture cannot erase an earlier I/O failure. Host campaign regressions run on
the island fixtures. See the T4 reason contract and `tests/board/README.md`.

**`kernel-pin.env` is a MIRROR, not a decision.** Its four `KERNEL_*` values are
byte-identical to `rk3588-kernel-patches/kernel-pin.env`, and a `pin-equality` CI
job proves it against the consumer at its pinned commit. Bumping the kernel is a
change to the consumer repository first; this file follows. A hand-edit here is a
red build, and that is the whole point — a modules-only cross-compile proves
nothing if it ran against a kernel the device never boots.

**`patches/` is generated. Editing it by hand is a bug, and CI catches it.**
The series generator regenerates from `drivers/` plus `integration/` into a temp
directory and byte-compares. Change the source, then regenerate — never the other
way round. An independent parity checker exists as a second opinion and must not
import the generator: a checker sharing the producer's code proves only that the
producer agrees with itself.

**Ownership is a device-tree `compatible` string, and never a Kconfig
dependency.** Every island-owned node carries exactly ONE `compatible`, matched
by exactly ONE driver. Mainline `rkvdec` and `rockchip-rga` stay BUILT alongside
the island so each silicon handover is reversible by a device-tree change and
A/B-able with `driver_override`. `CONFIG_VIDEO_ROCKCHIP_RGA` joins the image's
forbidden list only at the RGA flip, once no node is left for it to bind. The
mechanism, and why load order makes the alternative non-deterministic, is
[`docs/OWNERSHIP.md`](../OWNERSHIP.md).

**`docs/COMPAT.md` and `docs/OWNERSHIP.md` are machine inputs, not just prose.**
`shim-lint` parses COMPAT's table for every symbol classed `REAL-DEPENDENCY` and
fails if a compat header gives one a body — a stub returning `0`, `false`, `NULL`,
`ERR_PTR(...)`, `-ENODEV`, or an empty `void` body all fail. It also rejects any
`<soc/rockchip/*.h>` include and any new `rockchip_*` symbol absent from the
table, so source growth fails closed until its semantics are classified.
`dt-ownership-lint` reads OWNERSHIP the same way. Editing either table changes
what compiles; treat them as code.

**A compile can never succeed by silently replacing a REAL-DEPENDENCY with a
stub.** That invariant is the reason both halves of the shim gate exist: the lint
catches a stub with a body, and the link catches a declaration with no provider.
Neither alone is sufficient.

**Compat shims nest at `drivers/video/rockchip/mpp/compat/`.** That is where the
upstream Makefile consumes them. There is **no** root-level `compat/` directory,
and creating one moves the headers out from under both the build and the lint.

**Every board result names its board, kernel build and island tag.** A result
that cannot say which bytes it exercised is not a result. The RAUC precondition
(other slot confirmed good, attempt budget at least one, candidate-slot journal
captured **before** any reboot) is mandatory before any board deploy: the island
rides inside `linux-image`, so a broken kernel auto-rolls-back and takes its
evidence with it.

