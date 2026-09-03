# Phase-0 measurement harness

Reusable board probes for the RK3588 media-island effort: UAPI probes, a
per-core IRQ/fps sampler, journal counters, a dma-buf FD identity tracer, an
encode-corruption oracle, and the driver that turns all of them into the
Phase-0 baseline documents.

**This directory is temporary.** It is the harness the plan's todo 4 builds and
todo 6 moves into the island repository:

| here (today) | island repo (after todo 6) |
|---|---|
| `docs/media-island/phase0/harness/*.sh`, `*.c`, `uapi/`, `lib/`, `Makefile` | `tests/board/` |
| `docs/media-island/phase0/harness/tests/fixtures/` | `tests/fixtures/` |

Every script resolves its fixtures through `harness_fixtures_dir`, which
accepts **both** layouts, so the move is a `git mv` with no edits.

---

## What each tool answers

| tool | question it answers | Phase-0 row |
|---|---|---|
| `probe-mpp-uapi.c` | which MPP clients does the running kernel actually expose, and what does each answer? | 3(a) decode truth |
| `probe-rga-uapi.c` | is there a multi_rga character device, and can it blit an NV12 dma-buf? | 3(b) copy census, RGA flip |
| `librga-compat-probe.c` | what does librga's "compatibility mode" really do with no `/dev/rga`? | A2 |
| `librga-async-probe.cpp` + `librga-ioctl-trace.c` | does pinned librga construct a fence-bearing `IM_ASYNC` request? | todo 54 fence verdict |
| `probe-telemetry.sh` | are the required MPP/RGA procfs and debugfs trees readable, including any live session's fdinfo-style `stats` file? | todo 54 / todo 15 |
| `trace-dual-core.sh` | do two complete MPP task lifecycles select, start, and finish on two distinct cores? | todo 15 / todo 16 |
| `dual-core-matrix.sh` | do the six concurrency workloads sustain their rates, use both RKVENC2 cores, split tiled HEVC frames, and schedule a low-rate session fairly? | todo 16 / G1 / G2 |
| `trace-rga.sh` | does one real NV12 blit emit a complete RGA queued/selected/started/completed lifecycle, with all six trace events registered? | todo 15 / todo 19 |
| `sample-cores.sh` | did the second encoder core run, and at what per-process fps? | 3(d) dual-core |
| `count-journal.sh` | how many copy/fallback events happened in a measured window? | 3(b) copy census |
| `fd-trace.sh` | did a buffer cross this boundary, or was it copied? | 3(b) copy census |
| `encode-psnr-oracle.sh` | is the shipped encoder CLEAN or DIRTY at fixed QP? | 3(e) ENC-CORRUPT |
| `control-encode-per-codec.sh` | does a cold boot encode every supported control codec, with H.265 deliberately first? | todo 9 / board gates 14, 16 and 17 |
| `rkvenc-fault-campaign.sh` | do the canonical malformed ioctls keep their exact errno while the known BASE-only harness case stays honestly red? | todo 9 |
| `run-baseline.sh` | all five, written into the baseline document and the ledger | 3(a)–(e) |

---

## The four rules every tool here obeys

1. **`set -uo pipefail`, never `-e`.** These scripts MEASURE. A failing command
   is frequently the result — an ioctl answering `ENOENT`, a grep matching
   nothing, a board refusing. `-e` turns each of those into a silent abort with
   no verdict written, which is the one outcome a measurement harness may not
   produce.

2. **One exit contract**, mirroring `cerastream/tests/hw-smoke.sh`:
   `0` ran and passed · `1` ran and failed · `2` usage · `77` hardware-gated.
   **77 is not a pass.** A probe that could not reach hardware measured nothing
   and must never be counted as a green row.

3. **`--self-test` on everything, and it must discriminate.** Each self-test
   runs on a dev host with no board and scores **both directions** against
   committed fixtures — a clean input must read clean AND a bad input must read
   bad. A counter that returns zero for everything looks green forever; that is
   the failure mode these self-tests exist to prevent.

4. **Read-only against board state.** No unit is controlled, no module is
   loaded, nothing under `/sys` is written. Every remote payload is screened by
   `assert_payload_is_read_only` before it is sent, and the whole directory is
   screened by an independent grep in CI (below).

---

## Running the self-tests

```bash
cd docs/media-island/phase0/harness

for s in ./*.sh; do
  printf '=== %s ===\n' "$s"
  "$s" --self-test || echo "FAILED: $s"
done

make selftest          # host-builds the three C probes and runs their --self-test
./control-encode-per-codec.sh --self-test
./rkvenc-fault-campaign.sh --self-test
```

The C probes cross-build for the device with the target-suite toolchain:

```bash
make CROSS_COMPILE=aarch64-linux-gnu- clean all
```

The async-fence probe is compiled against the exact SDK being qualified rather
than a host development package. The preload shim substitutes `/dev/null` for
`/dev/rga`, logs the request bytes before the expected `-ENOTTY`, and therefore
measures librga's request construction without claiming a driver result:

```bash
make CROSS_COMPILE=aarch64-linux-gnu- \
  LIBRGA_PREFIX=/path/to/airockchip-librga-v1.10.0 async-fence-probe
LD_LIBRARY_PATH=build \
LD_PRELOAD="$PWD/build/librga-ioctl-trace.so" \
  ./build/librga-async-probe
```

`-Wall -Wextra -Werror` is not decoration. Every UAPI struct in `uapi/` carries
`_Static_assert` layout and ioctl-number checks, so a drifted header is a **red
build** rather than a malformed ioctl sent to a real encoder.

### The forbidden-verb screen

The acceptance gate greps this whole directory for three literals: the
unit-control verb followed by `start`/`stop`/`restart`, the module-loader verb,
and a shell redirection into `/sys`. It must return **nothing**.

```bash
# assembled so that running this does not itself write the banned literals into
# your shell history — or, if you paste it into a file here, into the tree.
VERB_CTL="systemctl"; VERB_MOD="mod""probe"; VERB_SYS="> /""sys"
grep -rnE "${VERB_CTL} (start|stop|restart)|${VERB_MOD}|${VERB_SYS}" .
```

The gate applies to **every byte in the directory, comments and documentation
included**. That is why `lib/harness-lib.sh` assembles its own deny-list
patterns from string fragments, and why the command above is assembled too: a
literal spelling anywhere here — even inside the text describing the rule —
would trip the gate the harness exists to satisfy.

---

## Running against a board

Credentials come from the environment; **no file in this repository locates
them**, which keeps the harness self-contained when it moves into the island
repo (Rule D).

```bash
export CERALIVE_BOARD_TEST=1
export BOARD_IP=<board ip>
export BOARD_SSH_USER=ceralive
export BOARD_SSH_PASS="$(head -1 <pass file>)"
```

The bench boards accept **password authentication only**, and OpenSSH's
`BatchMode=yes` refuses to use a password, so board sessions go through
`sshpass`. That is a property of the boards, not a preference.

```bash
# prove the transport and capture the inventory every measurement row cites.
# Runs NONE of the five measurements and writes no baseline document.
./run-baseline.sh --connect-check --board rock-5b-plus --host "$BOARD_IP" \
    --user "$BOARD_SSH_USER" --pass-file <pass file>

# the full Phase-0 baseline (todo 3)
./run-baseline.sh --board rock-5b-plus --host "$BOARD_IP" \
    --user "$BOARD_SSH_USER" --pass-file <pass file> \
    --doc-dir ../../phase0 --ledger-dir ../../ledger
```

`--connect-check` is safe to run at any time. The full run stages the harness
under `/tmp` on the board, runs the legs there, and removes the staging
directory afterwards.

---

## What the shipped image answered on 2026-09-02 (Rock 5B+)

Recorded here because it is the ground truth every later comparison is read
against, and because two of these facts contradict assumptions in the plan.

- **`/dev/rga` does not exist.** The mainline `rockchip-rga` driver is a V4L2
  M2M device, not a character device, so `probe-rga-uapi` correctly reports
  `errno=2` and exits `77`. The `RGA_BLIT_SYNC` leg only becomes reachable
  after the island's RGA flip.
- **`/dev/mpp_service` exists and advertises RKVENC2 ONLY.**
  `MPP_CMD_PROBE_HW_SUPPORT` answers `0x00010000` — bit 16, `MPP_DEVICE_RKVENC`.
  Bit 9 (`RKVDEC`) and bit 13 (`RKJPEGD`) are **clear**. There is no MPP decoder
  client on this kernel, which is the mechanism behind the decode-truth row.
- **The IRQ labels are the MAINLINE spellings, not the vendor ones.**
  `/proc/interrupts` carries `fdbd0000.rkvenc-core` and `fdbe0000.rkvenc-core`
  at IRQ 113/114 (GIC 133/136), plus `fdb60000.rga` and `fdb80000.rga`. The
  plan's "GIC 101/104" and any `rkvenc0`/`rkvenc1` label are vendor-kernel
  spellings and do not appear. `sample-cores.sh` matches on a substring of the
  label, so it handles both, but a later reader must not hard-code either.
- **librga initialises "successfully" with no device.** `c_RkRgaInit()` returns
  **0** while printing `failed to open RGA:No such file or directory`;
  `c_RkRgaBlit()` then returns **-19 (`-ENODEV`)** and leaves the destination
  untouched. An application that gates on the init return value alone believes
  RGA is available. That is the A2 answer, and it is a trap worth remembering.

---

## Layout

```
harness/
├── lib/harness-lib.sh        exit contract, read-only screen, board transport,
│                             fixture resolution, checksum assertion
├── uapi/rk-mpp-uapi.h        MPP service UAPI subset + layout assertions
├── uapi/rga-uapi.h           multi_rga UAPI subset + ioctl-number assertions
├── probe-mpp-uapi.c          MPP client inventory
├── probe-rga-uapi.c          RGA version + one NV12 dma-buf blit
├── librga-compat-probe.c     the A2 compatibility-mode probe (dlopen, no link)
├── Makefile                  cross-build + host-build + selftest targets
├── sample-cores.sh           per-core IRQ deltas + per-process fps
├── count-journal.sh          generalised d2/d4 journal counters
├── fd-trace.sh               dma-buf inode identity + GST_MEMORY attribution
├── encode-psnr-oracle.sh     fixed-QP encode -> PSNR distribution -> CLEAN/DIRTY
├── run-baseline.sh           drives (a)-(e), writes the baseline + ledger rows
└── tests/fixtures/
    ├── oracle/               the one fixed encode input + its SHA-256
    ├── journal/              clean and RGA_BLIT-fail journal windows
    ├── interrupts/           two /proc/interrupts snapshots + two tracer logs
    └── gst-memory/           zero-copy and copy GST_MEMORY logs + two fd maps
```
