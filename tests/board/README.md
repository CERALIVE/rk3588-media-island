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
| `rga-psnr-oracle.sh` | does the RGA3 crop/scale/transpose victim preserve 600 frames at async depths 2 and 0, above 35 dB mean PSNR? | comparison kernel / todo 26 RGA oracle |
| `control-encode-per-codec.sh` | does a cold boot encode every supported control codec, with H.265 deliberately first? | todo 9 / board gates 14, 16 and 17 |
| `rkvenc-fault-campaign.sh` | do the canonical malformed ioctls keep their exact errno while the known BASE-only harness case stays honestly red? | todo 9 |
| `fault-matrix.sh --driver island\|rewrite\|auto` | do the sixteen fault rows leave the device recovered, with the armed one-shot consumed exactly once and the healthy session's throughput intact? The `--driver` profile selects which seam is expected: `island` keeps every island assertion, `rewrite` keeps them and additionally LABELS the telemetry the rewrite does not publish rather than scoring it | fault-seam parity / the 16-row matrix; both campaigns and the rewrite comparison |
| `fault-controls-probe.sh` | do the five fault controls no matrix row consumes actually fire, exactly once, with their documented errno and a recovering device? Same `--driver` profiles; `--row idle-iommu-fault` is the separate, explicit-only idle experiment | fault-seam parity / the five non-matrix controls |
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

   `fault-controls-probe.sh` is a named exception, and it is a narrow one. It
   performs exactly two kinds of write. First, it arms one-shot fault knobs in
   the seam directory `/sys/kernel/debug/rkvenc-test/` — the same nodes
   `fault-matrix.sh` already arms for its four matrix controls. Second, for the
   three controls that only fire inside the driver's probe path
   (`service-attach`, `ccu-attach`, `irq-request`) it detaches and reattaches
   **one** encoder core, by writing that core's name into the `unbind` and then
   the `bind` attribute of its platform-bus driver directory. Both the core name
   and the driver directory are read off the bus at run time, so no board
   device-node address is spelled anywhere in this directory and the literal
   screen below stays empty.

   This paragraph is itself screened. The exception is described here in prose
   precisely because the acceptance gate below greps every byte of this
   directory, documentation included — so the two write kinds are named by what
   they do (arm a seam knob; detach and reattach one core through its driver's
   bus attributes) rather than by a literal a reader could paste into a script.
   Both campaigns of 2026-09-09 exercised this path and the screen stayed empty.

   Nothing else is touched: no unit is controlled, no module is loaded or
   unloaded, and a `trap` retries outstanding core restoration on exit,
   including after a failed assertion. A failed reattachment returns failure,
   retains the core's restoration marker and stops subsequent probe mutations;
   it is never silently treated as successful cleanup. Both write kinds require an `edge-test` kernel
   carrying `CONFIG_KASAN=y`, `CONFIG_PROVE_LOCKING=y` and the active profile's
   fault-seam symbol, plus `CERALIVE_BOARD_TEST=1`, root, and a caller holding
   the external board lock — the drill exits `77` rather than writing anything
   if any of those is missing, and it must never be pointed at a production
   kernel. The three probe-time rows are gated once more on top of that:
   `docs/FAULT-SEAM-CONTRACT.md` must record `bind-attr: yes` for the active
   driver, and without that recorded check each row reports
   `GATED reason=no-bind-attr` and performs no write at all.

---

## Running the self-tests

Both fault drills reject a value-taking option with no following argument with
usage exit `2`, before board admission. Their self-tests exercise every such
option under a timeout, and confirm valid arguments still reach the board gate.

The clock-enable row re-captures its journal after the recovery encode; its
self-test rejects a report emitted only during that otherwise successful encode.
It accepts the driver's numeric `clk_on failed: -5` diagnostic as well as the
symbolic/strerror forms, but not an unrelated `-5` or a different numeric errno.

The optional idle-window experiment is explicit-only:
`fault-controls-probe.sh --row idle-iommu-fault --driver island|rewrite`.
It is not part of that probe's five-control `--row all` sweep and never enters
the 16-row matrix, which runs a competing healthy encoder. With no encode
running, it arms `inject_iommu_fault_idle_ms=3000`, completes one 30-buffer
encode, leaves the device untouched for six seconds, and checks consumption,
actual firing, PM-at-fire state, callback errno, journal and recovery. All four
idle debugfs files must exist together. Absence gates this row; a partial block
fails inventory. Its self-test exercises both PM readings and both driver
profiles with synthetic fixtures, including deliberately incorrect counters,
missing firing/state, recovery failure, journal reports and busy admission.
None of that fixture output is silicon evidence.

The RGA oracle's `--self-test` uses real software FFmpeg to distinguish identical,
corrupt, truncated and extra-frame output. Its hardware arm runs **locally on the
board**, under the external board lock, with `CERALIVE_BOARD_TEST=1` and a
checksum-pinned 1920×1080 H.264 input containing at least 600 frames:

```bash
CERALIVE_BOARD_TEST=1 FFMPEG=/path/to/rkmpp-enabled-ffmpeg \
  bash tests/board/rga-psnr-oracle.sh --input /path/to/input.h264 \
  --sha256 <input-sha256> --out /tmp/new-rga-oracle-run
```

The victim uses RGA3 core 0, crops 960×540 at (160,90), scales to 640×360,
rotates clockwise and encodes HEVC at 3 Mbit/s. Software scoring compares the
decoded 360×640 output with the crop/bicubic-scale/transpose reference. The
35 dB mean-PSNR bar comes from
[`ffmpeg-suite.sh` at the pinned upstream record](https://github.com/yisding/rock-5b-ysp/blob/ca3da04280c48c004e522c15f31862bf88a2d1b9/kernel-drivers/tests/ffmpeg-suite.sh#L712-L747);
600 frames and the depth-0 control are CeraLive's comparison requirements.
This is an end-to-end victim, not an isolated RGA-only score: decoder or encoder
corruption can also make it red. Command failure or missing frames is
`INCOMPLETE`, never `NOT-REPRODUCED`. The output directory must be new; each
command, software version, bitstream, decoded file and scoring log is retained.
The calling locked session must capture stdout and the surrounding kernel journal.
No hardware result is claimed by creating or self-testing this harness.

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

## Where the fault-drill fixtures live

The two fault drills score against different fixture sources, and the difference
is worth stating because only one of them is committed.

- **`tests/fixtures/reliability/orange-pi-5-plus/`** — real captures from that
  board, and what `fault-matrix.sh --self-test` scores its **island** profile
  against.
- **`tests/fixtures/reliability/rewrite-synthetic/`** — hand-written, and clearly
  labelled as such in its own README. It exists so the matrix's **rewrite**
  profile is scored in both directions on a host with no board, because the
  profile most likely to be wrong would otherwise go unexercised. No number in
  it may be quoted as a measurement; the real rewrite numbers live in the root
  ledger's phase-3 comparison.
- **`fault-controls-probe.sh` has no committed fixture directory.** Its
  `--self-test` builds a synthetic one-shot seam — a shell "driver", not a fake
  device — in a fresh `mktemp -d` on every run, then scores both directions
  against it, including deliberately wrong counters, a missing firing or state
  file, a failed recovery, a journal report and a busy admission. There is no
  `tests/fixtures/fault-controls/` directory, and adding one would only freeze
  what the drill already generates deterministically.

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
