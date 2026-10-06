<!-- Moved verbatim from AGENTS.md on 2026-10-05 by lean-rules-docs-landing-latam -->

## CI

All workflows follow the CeraLive CI/CD canon: a `concurrency` block on every
workflow (`cancel-in-progress: true` for PR gates, `false` for release);
`push` constrained to `branches:` and `tags:` because a `pull_request` trigger
exists; top-level `permissions: contents: read`; every `uses:` pinned to the
latest stable major; the kernel clone and `ccache` cached; nothing published
without the gates having run first.

Three workflows: `ci.yml` (the PR gate), `release.yml` (`workflow_dispatch`, with
`publish` defaulting to **false**), and `upstream-watch.yml` (scheduled,
issue-only). Per-job detail, the mutation transcripts, and the honest list of
remaining deferred inputs live in [`docs/CI.md`](../CI.md).

**MPP partial-clock unwind is checked at the unlocked helper, not its wrapper.**
`scripts/check-mpp-hardening.py` inspects `rkvenc_clk_on_unlocked()` and the
wrapper's call/return chain. Its self-test accepts production source and rejects
seven clock-path mutations; the normal gate retains all 23 assertions. This is a
source-shape regression check, not hardware clock validation. See
[`docs/CI.md`](../CI.md#3a-mpp-partial-clock-unwind-checker).

| Job | Asserts |
|-----|---------|
| `shellcheck` | Every tracked shell script lints clean at `-S style` (only `SC1091` excluded) |
| `self-tests` | Every board harness and every CI tool passes its own scored fixtures; module and telemetry contracts check maintained source and mutation fixtures, including MPP dual-core and RGA lifecycle traces |
| `series-integrity` | `patches/` regenerates byte-identically from `drivers/` + `integration/`, verified again by an independent parity checker |
| `shim-lint` | No compat header gives a `REAL-DEPENDENCY` symbol a body; no unclassified `<soc/rockchip/*.h>` include or `rockchip_*` symbol exists |
| `dt-ownership-lint` | Applied MPP and RGA nodes are checked for one compatible, one island match and no pinned-mainline collision |
| `uapi-parity` | Every `MPP_CMD_*` / `MPP_IOC_*` value and the `mpp_request` layout match the pinned vendor header and the userspace that consumes them |
| `board-probes` | The three C probes cross-build for aarch64 with `-Werror`, and their host build passes its own self-tests |
| `action-pins` | Every `uses:` is at the current latest major. **Non-blocking** — an action's release cadence must not redden an unrelated PR |
| `pin` | Nothing — it *reads* the coordinates out of `kernel-pin.env` and emits them as job outputs |
| `pin-equality` | The four mirrored `KERNEL_*` values equal the consumer's |
| `cross-compile-modules` | Both pinned kernel objects resolve; the tree configures the way the device is configured; `vmlinux` supplies provider symbols, `modules_prepare` supplies the module linker script, and `vmlinux.symvers` is exposed as the `Module.symvers` external modpost requires; the two arm64 modules link with `-Werror` and expose their required OF aliases; both supported board DTBs build and pass `tests/dt/check-dtb-ownership.sh`; no island `compatible` collides with a mainline `of_match_table` |
| `kunit` | Builds the MPP request-boundary, fault/lifecycle, session-teardown, DMA policy, fence, RGA request-validation, capability, telemetry-format, direct ioctl, and runtime-PM ownership suites against the pinned tree |
| `static-analysis` | sparse with findings promoted to errors plus coccinelle over every selected island object; smatch remains conditional on a suitable runner package |
| `upstream-watch` | Nothing — it opens or updates ONE issue and never edits a pin or dispatches a build |

**`shellcheck` and `self-tests` are two jobs because they answer two questions.**
Shellcheck cannot see an ERE bracket expression containing a literal `\t` — valid
shell, valid regex, and it matches a backslash and a `t` rather than a tab. That
defect shipped once here. Reintroducing it leaves shellcheck green and turns the
harness self-test red; the transcript is [`docs/CI.md`](../CI.md) §3.

**The source-dependent gates are live.** Series integrity reconstructs 87 source
files and eight applied integration payloads, shim/UAPI checks inspect the imported
surface, sparse checks every selected object, and cross-compile asserts exactly
`rk_vcodec.ko` plus `rga_multicore.ko` and rejects either module if its compiled OF aliases
are absent. The source-side half also rejects a device match table that is not
published and an `IRQF_ONESHOT` hard-IRQ request with no threaded handler. DT ownership is also live: the MPP nodes ship,
both board DTBs are inspected, and the applied RGA3/RGA2 hunks are verified as
one complete ownership flip.

**Telemetry is part of the production island contract.** The island fragment
forces MPP procfs and the RGA procfs debugger on. Module init fails rather than
silently succeeding when either required root cannot be created, and
`tests/board/probe-telemetry.sh` checks the operator-facing files. Production
also enables debugfs for cumulative per-core and per-session counters. Tracefs
events use Linux tracepoint static keys, so disabled tracing executes only the
patched unlikely branch. The production fragment selects the event tracer but
keeps the function tracer off; CI asserts the hidden `TRACING`, `EVENT_TRACING`,
and `TRACEPOINTS` closure survives Kconfig resolution. Each live session exposes one fdinfo-style
`stats` snapshot. `/proc/mpp_service` and `/proc/rkrga/load` remain the
stable compatibility surfaces; their exact contract is [`docs/TELEMETRY.md`](../TELEMETRY.md).

**No workflow restates a pinned coordinate.** The kernel tag is read from
`kernel-pin.env`; a literal tag anywhere in `.github/` is a regression, because a
pin bump would otherwise leave CI proving the series against a kernel nobody ships
— green, which is the worst kind of failure.

