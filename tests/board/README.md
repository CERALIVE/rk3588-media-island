# Phase-0 measurement harness

Reusable board probes for the RK3588 media-island effort: UAPI probes, a
per-core IRQ/fps sampler, journal counters, a dma-buf FD identity tracer, an
encode-corruption oracle, and the driver that turns all of them into the
Phase-0 baseline documents.

This is the maintained harness home, moved into `tests/board/` at todo 6.
Every script resolves its fixtures through `harness_fixtures_dir`, which also
accepts the earlier Phase-0 layout for retained historical runs.

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
| `idr-latency.sh` | how many encoder-input frames after each acknowledged IPC request precede the muxed IDR? | Phase 7 encoder hygiene |
| `encode-psnr-oracle.sh` | is the shipped encoder CLEAN or DIRTY at fixed QP? | 3(e) ENC-CORRUPT |
| `rga-psnr-oracle.sh` | does the RGA3 crop/scale/transpose victim preserve 600 frames at async depths 2 and 0, above 35 dB mean PSNR? | comparison kernel / todo 26 RGA oracle |
| `control-encode-per-codec.sh` | does a cold boot encode every supported control codec, with H.265 deliberately first? | todo 9 / board gates 14, 16 and 17 |
| `rkvenc-fault-campaign.sh` | do the canonical malformed ioctls keep their exact errno while the known BASE-only harness case stays honestly red? | todo 9 |
| `fault-controls-probe.sh` | do the five fault controls no matrix row consumes actually fire, exactly once, with their documented errno and a recovering device? | fault-seam parity / the five non-matrix controls |
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

   The Phase-7 `idr-latency.sh --request` arm is explicitly active: it requests
   keyframes from an already-running engine, locally under the external board
   lock with `CERALIVE_BOARD_TEST=1`. It does not start or stop that engine or
   perform fault injection. The caller owns those separate drill operations.

## Forced-IDR measurement

Python 3.11+ is required on the **engine host** for `--request`; scoring can run
on the development host with Python and `ffprobe`. Self-test additionally needs
FFmpeg with `libx264` and `libx265`. No package is installed by this harness.

```bash
bash tests/board/idr-latency.sh --self-test
CERALIVE_BOARD_TEST=1 bash tests/board/idr-latency.sh \
  --request /run/cerastream/control.sock /tmp/requests.tsv
bash tests/board/idr-latency.sh \
  --score recording.ts input.tsv requests.tsv 324000000
```

The final argument is the **measured mux PTS offset in 90 kHz ticks**, not a
constant to copy from this example. The collector must retain every program
encoder sink-pad buffer in `input.tsv` as `CLOCK_MONOTONIC_nanoseconds<TAB>PTS_90k`.
Use the same host clock as Python's `time.monotonic_ns()`, and convert input PTS
using the muxer's timestamp rounding. Capture starts before the first request
and ends after the last response has produced output. The request file contains
`id<TAB>send_ns<TAB>ack_ns<TAB>applied`, twenty rows with exclusive file creation.
There is no input-pad collector or stream recorder inside this tool: the
calling drill supplies those artifacts, plus per-frame DMA-BUF tracing.

Scoring requires exact input/output PTS sequence equality modulo 2^33 and no
B-frame reordering. It reads AVC type 5 or HEVC types 19/20 from Annex-B packet
NALs, not ffprobe's generic keyframe flag (HEVC CRA is not IDR). Multiple slices
of one picture are allowed; mixed slice kinds and ambiguous pictures are refused.
The first input at or after request **send** time is latency frame 1; later
frames count upward. Missing IDRs remain null/FAIL, and every value above 1
remains FAIL. A rejected acknowledgement or incomplete trace cannot pass.

For a hardware forced-keyframe claim, retain the encoder GOP configuration and
ensure scheduled IDRs cannot coincide with the request windows; this scorer
detects IDRs but cannot infer why the encoder generated one. The software
self-test deliberately uses known periodic GOPs to prove the parser and score,
then a real local Unix socket peer to prove RPC framing and acknowledgements.
Neither fixture is a hardware-latency or zero-copy result.

## Fault-control write boundary

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

   Nothing else is touched: no unit is controlled, no module is loaded or
   unloaded, and the core is reattached from a `trap` on every exit path,
   including a failed assertion. Both write kinds require an `edge-test` kernel
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
cd tests/board

for s in ./*.sh; do
  printf '=== %s ===\n' "$s"
  "$s" --self-test || echo "FAILED: $s"
done

make selftest          # three probe self-tests plus mocked RGA regressions
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

### RGA probe corrections from todo 26 (2026-09-10)

RUN19 reported valid driver `1.3.11` and three-core payloads with ioctl return
`+1`; the original probe's `== 0` checks falsely reported both as failures.
This is the driver's deliberate success convention, not a special case for
that board: both version cases in the pinned donor's
[`rga_ioctl()`](https://github.com/rockchip-linux/kernel/blob/b4ef083dc0c3608e744deabb43dc6b781aadbe6e/drivers/video/rockchip/rga3/rga_drv.c)
set `ret = true` after successful `copy_to_user`, and `-EFAULT` on copy failure.
The probe accepts nonnegative returns and reports errno only on failure.

RUN20 observed `src.rd_mode=1` and `dst.rd_mode=1` in a working librga request.
Changing only those two fields to zero caused `EINVAL` / `no core match`.
The donor's
[`RGA rd_mode` enum](https://github.com/rockchip-linux/kernel/blob/b4ef083dc0c3608e744deabb43dc6b781aadbe6e/drivers/video/rockchip/rga3/include/rga.h)
defines `RGA_RASTER_MODE = 1 << 0`; `fill_img()` now selects it for both operands.

`make selftest` runs `test-rga-probe.c` against the actual probe with intercepted
open/close/ioctl calls. It covers zero and positive version replies, independent
and combined errors (including stale errno on success), and both raster fields
at blit submission. The probe's own self-test also pins both read modes to `1`.
These tests contact no RGA device and do not certify a complete raw request:
the omitted tail fields still need independent validation before a board rerun.
In particular, these repairs do **not** clear the separate concurrent
default-policy `EBUSY` at blit 175 from RUN20. Historical FAIL results remain
historical; there is no new hardware pass from a tooling-only fix.

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
