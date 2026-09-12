# Orange Pi 5+ — round 3, RGA plugin installed

Date: **2026-09-06, 05:36–07:30 UTC**. Board: **192.168.78.151 only**.

**Verdict: build, full Kconfig closure, OTA and plugin registration PASS;
requested product qualification remains FAIL / incomplete.** Both direct
30-minute real-HDMI codec benchmarks completed, and real-source
decoder+RGA+encoder component recovery completed. Neither result is a substitute
for the failed UI-driven sessions or the unrun product recovery/preview gates.
No plan checkbox, release, PR or commit was created by this run.

## Candidate and deployment

| Field | Observed value |
|---|---|
| Image source | Updated `master`, `1f56ca03c94dcc462a8b1f7a88c1c87e64532b42` |
| Merged prerequisites | PR #150, `98f9f198`; PR #152, `1f56ca03` |
| Kernel source / consumer | Linux v7.2 `8d3ae59288f1e7d58d76558a6ee96d533bc5019f`; patches `365b2463294019e3d4e2d5718a787c2055f4ab59`, island v2026.9.2 |
| Candidate | `orange-edge`, non-debug image, bench `x` PARTLABELs |
| Signing | Installed NON-PRODUCTION root accepted existing development signer; not a releasable production-signed image |
| Bundle | `20260906T054117Z.raucb` |
| Bundle SHA-256 | `1f615870e3aedefad6f8e95aa0d77a66d827258fc16570a26f0b4fe89bb54e71` |
| Rootfs SHA-256 | `2a5b6ccd7f1d3c5fd9c185ad34be396b54334f675708776be9340bd52d858b46` |
| Resolved config SHA-256 | `7f11b1434e48574a9066046fdaf6f64f470ca16d862ca2c99c972f18107df323` |
| Booted kernel | `7.2.0-ceralive-rk3588 #ceralive1 SMP PREEMPT @1788671395` |
| Installed plugin | `gstreamer1.0-rockchip-ceralive 1.14.4+ceralive.2` |
| Engine / UI | `cerastream 2026.9.1+5cfa1ba`; `ceralive-device 2026.9.0-20260902T184015.b720f33` |
| librga | Unchanged Radxa `librga2 2.2.0-1`, API string `1.10.1_[4]` |

The normal hardware-candidate builder ran under Docker's native `default`
context with fresh board preflight/trust files, explicit signing inputs, and
`--only orange-edge --bench-labels 1`. Its six dry-run probes ran first; they
contact no boards. Rootfs size was **1,186,641,920 B**, below 1,500,000,000 B;
boot-artifact validation and package parity (**20 pass / 0 warn / 0 fail**) passed.
The known recorder error `candidate_is_source_built: command not found` recurred
at line 437. It was retained, not repaired. The separate build-log census gate
was not run; build success is not a clean-build-log certification.

The full pre-deployment command was:

```sh
bash lib/verify-kernel-config.sh \
  --config test-results/opi-round3-1f56ca03-20260906/build/orange-edge.bench-labels-1.config \
  --declared manifests/kernel/rk3588-edge.fragment \
  --required manifests/kernel/required-symbols.list \
  --forbidden manifests/kernel/forbidden-symbols.list
```

Exit 0:

```text
ok: 187 of 187 declared symbol(s) survived into the resolved kernel .config (0 reviewed exception(s))
ok: 185 required and 81 forbidden symbol(s) hold
```

Before: **B active/booted/good**, A good, `BOOT_ORDER=B A`, A=3/B=3,
root `/dev/mmcblk1p3`, system `running`; engine PID 21950/NRestarts=1 from
the previous round. SSH worked with the freshly read existing password.

The complete pre-deployment journal was captured. Board-side SHA-256 and
`rauc info` verified the transferred bundle and compatible string. With CeraUI
idle, CeraUI and cerastream were stopped before RAUC installation. Transaction
**`e03ae8f2` succeeded at 05:54:10 UTC**, installing A. The shared mark-good
marker was cleared as the installed update wrapper prescribes. B remained
good with budget 3; the journal was captured again before reboot.

After boot: **A active/booted/good**, B good, A=3/B=3. The image-build marker
matches the full source SHA. SSH was disabled by production-image policy and
enabled through **CeraUI Settings → SSH Access → Start SSH Server**. The
original password authenticated afterwards. **No credential changed.**

Both `gst-inspect-1.0 rgaconvert` and `gst-inspect-1.0 rgacompositor` produced
their complete factory descriptions from
`/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstrockchiprga.so`. All three RGA
cores probed, and the boot journal records `IOMMU binding successfully`.
Registration is therefore installed/booted evidence, not just a manifest pin.

## Todo 36 — UI admission FAIL; no product soak

Fresh HDMI queries before deployment, after boot and at final cleanup all
reported **3840×2160 progressive, 593396000 Hz pixel clock, 4400×2250 total,
59.94 frames/s**, at `/dev/hdmirx` → `/dev/video0`. The initial configured
640×480 NV16 format was stale state, not the detected signal. No 10-bit claim.

CeraUI selected HDMI Input, 4K, 59.94 fps and 5 Mbps, H.265 first and H.264
second. Both failed before a session could run:

```text
06:00:36.124Z H.265 att_mtpekr9c_yWA9hVxK
06:01:03.613Z H.264 att_mtpelclo_TXEBqpf9
phase=start-rpc class=engine_internal code=-32603 retry=not_retriable
stream start failed internal engine error: no safe V4L2 converter factory matched the platform policy
```

This failure persists **despite both RGA elements being installed**. The engine
converter resolver inspected during the run filters V4L2 converter factory
names and probes driver/card identity; plugin registration alone does not
establish that the deployed engine uses the new factory. No engine, plugin,
Kconfig or package fix was attempted.

For the requested acceptance record, **`gates."4k60" = FAIL`**: neither
UI-driven 30-minute session began, no running product pipeline demonstrated
`rgaconvert`, no typed capped-fps posture was measured, and preview-ladder
rung/less-than-1%-main-stream-loss and typed runtime link-loss behavior remain
unmeasured. The direct runs below do not change this gate.

### SIGUSR1 absence and clean-boot requirements also fail

This was not a clean boot journal:

```text
05:56:19 ceralive.service: Sent signal SIGUSR1 to main process 968 (ceralive) on client request.
05:56:19 ceralive.service: Main process exited, code=killed, status=10/USR1
05:56:19 ceralive.service: Scheduled restart job, restart counter is at 1.
```

That signal preceded this run's fault injections and was not sent by the
operator commands here. CeraUI recovered as PID 992; cerastream stayed PID
797/NRestarts=0. The sender of the boot-time client request was not identified.

Other retained boot findings include the FAT unclean-unmount warning, GPT
backup-header position warning, rejected regulatory.db signature, deprecated
HDMI hotplug workqueue warning, HDMI audio underflow and duplicate debugfs
session entry. No kernel Oops/Call-trace or IOMMU-fault signature was found in
the captured journal. That narrow absence does not make the boot clean.

## Todo 37 — extend, do not replace, the USB evidence

The existing [USB matrix](../../tests/board/usb-matrix.yaml) and its original
DJI Mic Mini capture PASS are retained. Added a dated round-3 inventory block;
the historical capture values were not regenerated or relabeled as new-image
evidence.

At **06:04:43 UTC**, zero USB video-class interfaces and zero UVC nodes were
enumerated. Video row IDs **1–8 and 10 remain NO-DEVICE**. Onboard HDMI and
the three V4L2 codec nodes are not USB capture devices. No camera, MS2130 or
Cam Link was inferred from their presence.

DJI MIC MINI `2ca3:4011`, USB `1-1.4`, 12 Mb/s, remains present and published
as a PipeWire source. ALSA reordered it from card 4 to **card 0**, preserving
id `usbaudio`; capture is now `pcmC0D0c`. Its advertised native format remains
S24_3LE, 48 kHz, two channels. This scan is not a second audio capture test.
No connected Bluetooth device was reported. Native 96 kHz, HDMI eight-channel,
HFP and USB hotplug axes are still unqualified; the overall audio class remains
FAIL/incomplete with its narrower existing 48 kHz PASS intact.

## Direct real-source admission and its failures

The first direct command wrongly constrained the encoder input to
`video/x-raw(memory:DMABuf)`; the installed encoder pad template refused that
caps feature before execution. Removing that feature constraint allowed the
ordinary caps path with **actual DMA-BUF memory**, subsequently measured by
pad probes rather than inferred from caps text.

The next real NV16→NV12 conversion failed explicitly:

```text
no 2D converter available for rgaconvert: the trial-verified RGA backend rejected the conversion
Not support full csc mode [300]
src yuv_bt.601-limit(0x300); dst yuv_bt.709-limit(0x500)
```

The source negotiated `colorimetry=2:4:7:1`. Constraining the output to that
**same reported colorimetry**, without changing the source's metadata, removed
the requested cross-color-space operation. A finite real-HDMI→RGA→H.265→MPP
decode graph then completed. This proves that graph, not general CSC support
or pixel/color fidelity. All successful direct tests below keep that constraint.

## Todo 38 — real full-island component drills PASS; product drills incomplete

A live publisher captured HDMI 4K59.94 NV16, scaled with RGA to 1080p, encoded
H.264, and published to the board's local MediaMTX `/publish/live` path. Each
faulted consumer used:

```text
real HDMI-derived RTMP → flvdemux → h264parse → mppvideodec
  → rgaconvert (1280×720, preserved colorimetry) → mpph265enc → h265parse → fakesink
```

This is real-time physical video, not a synthetic or replayed fixture. Admission
required advancing encoded buffers before each injected signal. Loaded snapshots
show both encoder cores, both decoder cores and RGA activity; decoded and
converted buffers were actual DMA-BUFs. The instrument's `capture` counter on
these relay consumers is the **decoder output**, not the HDMI capture boundary.

| Drill | Result and limit |
|---|---|
| 20 finite pipeline teardowns | All exited 0; real decoder→RGA→encoder work, not UI PiP toggles |
| 10 SIGKILLs mid-workload | All admitted and exited 137; subsequent processes admitted successfully |
| SIGSEGV mid-workload | Admitted process exited 139; unlike the prior round, process death was actually induced |
| 50 two-process concurrent destructions | Both consumers admitted on every repetition, then both exited 143 after TERM |
| Final reuse | Real consumer completed with exit 0 |
| DMA-BUF/resource return | Publisher-only baseline before/after was exactly 15 objects / 88,121,344 B, same live publisher; both queue depths 0. After publisher and all benchmarks stopped: 0 objects / 0 bytes |
| Kernel errors/resets | Exposed MPP/RGA error counters stayed 0. MPP reset counters stayed 0; RGA2 normal per-job reset growth is not fault-reset proof |
| cerastream live crash/restart; KillMode helper survival | **NOT RUN on an admitted product stream**. Engine remained idle/PID 797 throughout; an idle kill would not qualify |
| ADR-0009 loaded-island link drills | **NOT RUN**; no admitted product transport session. Management networking was not disrupted |
| Watchdog restart and resumed stream | **NOT RUN**; no qualifying product session to stall |
| General leak/RSS-slope proof | **Not established** by fresh-process trials and DMA-BUF snapshots |

Product RTMP-ingest starts were attempted, but failed: an initial publisher URI
was incomplete (`Host is not set`); after correcting it, one start encountered
SRT connect reason 16, and a later attempt with a restarted receiver failed
`pipeline did not reach PLAYING: Element failed to change its state`. The
working direct relay consumer proved the real publisher could supply frames,
not that the product start failure was resolved. All attempt logs are retained.

These are deliberately short fault/finite-buffer drills, not shortened soak
passes. They ran 06:13:59–06:21:11 UTC. Full todo 38 remains incomplete.

## Todo 42 — real-capture benchmarks, with explicit limits

Two **30-minute** runs used the physical HDMI signal, at 8 Mb/s:

```text
v4l2src io-mode=dmabuf → 4K59.94 NV16 → rgaconvert
  → 4K59.94 NV12 (colorimetry=2:4:7:1)
  → mpph265enc OR mpph264enc → matching parser → mppvideodec → fakesink
```

The repo-local measurement program was cross-built with `-Wall -Wextra -Werror`.
It counted buffers at source/converter/encoder/decoder pads, matched source and
encoded PTS for latency, sampled CPU/core/thermal telemetry every five seconds,
watched bus errors/warnings, and read converter rejection/fallback counters.
The duration clock starts at the first encoded AU; stopping is quantized by the
100 ms bus wait. No 6h/24h/72h soak was attempted.

| Metric | H.265 primary | H.264 secondary |
|---|---:|---:|
| UTC window | 06:22:39–06:52:39 | 06:53:05–07:23:06 |
| Elapsed from PLAYING request, s | 1800.174818 | 1800.190221 |
| Captured / converted buffers | 107888 / 107888 | 107892 / 107892 |
| Encoded / decoded buffers at terminal snapshot | 107887 / 107885 | 107891 / 107889 |
| Steady-window AU/s | 59.9366 | 59.9383 |
| Source-buffer→encoded-AU mean latency, ms | 20.552 | 20.113 |
| Latency p95 bucket | [20, 21) ms | [20, 21) ms |
| Maximum measured latency, ms | 29.944 | 28.105 |
| Maximum encoded-AU arrival interval, ms | 67.135 | 66.846 |
| Pipeline CPU, one core = 100% | 92.53% | 89.54% |
| RKVENC core0 utilization mean/max | 86.59% / 87.39% | 82.87% / 83.74% |
| RKVENC core1 utilization | 0% | 0% |
| Package thermal min/max, °C | 43.461 / 50.846 | 47.153 / 49.923 |
| Converter fallback / dropped / layout rejected | 0 / 0 / 0 | 0 / 0 / 0 |
| Exit | 0 | 0 |

Steady rates/CPU exclude the initial sample interval and use cumulative deltas
over approximately 1792.9 s. Core mean/max includes sampled startup. Every
captured/converted/decoded buffer examined was DMA-BUF-backed; all encoded PTS
matched. The latency boundary starts when `v4l2src` delivers a buffer, **not at
sensor exposure or HDMI arrival**. Final counters precede NULL teardown, so the
one-AU/two-decoded-buffer tail difference is not a certified loss count. No
complete capture-sequence-gap or jitter-distribution instrument was present.
The measured rates are slightly **below** strict 59.94; no typed capped-fps
posture or at-least-59.94 guarantee is claimed. RGA core0 carried the conversion
in both long runs; the other RGA cores were not needed by these single streams.

### Finite 600-capture-buffer samples (not sustained/maxima certifications)

| Codec / output | Captured / converted / encoded / decoded | Whole-process s | Mean buffer→AU latency ms |
|---|---|---:|---:|
| H.265 4K29.97 | 600 / 304 / 304 / 304 | 10.242626 | 20.450 |
| H.264 4K29.97 | 600 / 304 / 304 / 304 | 10.235185 | 19.895 |
| H.265 1080p59.94 | 600 / 600 / 600 / 600 | 10.241286 | 12.590 |
| H.264 1080p59.94 | 600 / 600 / 600 / 600 | 10.241095 | 12.468 |

Input remained 4K59.94. `videorate drop-only=true` selected 30000/1001 for the
29.97 rows; these are **not exact 30/60 Hz** measurements. All four exited 0
with zero converter fallback/drop/rejection counters.

Forced RGA3-core0, RGA3-core1 and RGA2 each converted **600 real 4K NV16→1080p
NV12 buffers**, followed by H.265 encode/decode, with zero converter errors.
Per-core task deltas were exactly 600 on the selected core and zero on the
others. Cumulative busy time per converted job was respectively **7.034 ms,
7.188 ms and 6.047 ms**. Those are busy-time measurements at a live-source
rate, not maximum sustainable conversion rates.

### Multi-stream observations

Mixed-codec **2×4K29.97, 4×1080p59.94 and 8×720p59.94** graphs completed,
all from one real HDMI source split before per-branch RGA converters. These
are multiple encodes of the same source, not multiple attached cameras.
Whole-process times were **10.718, 11.201 and 14.139 s** for 600 capture
buffers. The eight-stream shape is slower; a sustained per-stream rate is
not established.

Failures are retained: v1 had a CLI tokenization error; v2 put the tee AFTER
one converter and failed because that topology lost the downstream DMA-BUF
pool (`system-memory output is disabled`). v3 put a converter directly before
each encoder; no CPU-copy opt-in was enabled.

**Measurement limitation:** the `GstIdentity` deep-notify text census reported
more than 600 chain notifications for some branches. It is not an authoritative
AU census, so its derived per-stream rates in the raw analysis are flagged
uncertified, not promoted into throughput/duplicate-frame claims. Correct
per-pad counting for every concurrent encoder remains owed. Successful process
completion alone does not pass the multi-stream performance gate.

### Comparison with todo 3

The retained 2026-09-02 Orange Pi baseline had **no HDMI lock**, so it provides
no same-source captured-video performance comparator. Its supplementary
unpaced synthetic 600-AU 4K59.94 encodes measured H.264 **63.16 fps** and
H.265 **61.79 fps**; two synthetic live 4K30 H.265 processes measured
**30.01 fps each**. The current long graph is live-source-paced and also
converts and decodes, with different engine/plugin versions and accounting.
Calling the lower numeric result an explained island regression would be false.

The baseline H.264 PSNR CLEAN / H.265 DIRTY oracle findings and software
H.265/MJPEG decoding were not re-run as a matched oracle campaign. Current
explicit `mppvideodec` buffer production plus nonzero decoder utilization proves
hardware decode for these real graphs, not universal autoplug or pixel quality.
Full todo 42 remains incomplete: maximum/variance-matched throughput, exact
30/60 modes, full RGA operation/color matrix, sensor→AU latency, certified
multi-stream loss/jitter and every-regression explanation are still owed.

## Retained evidence and final state

Raw logs, candidate tuple/config, exact pipeline commands, measurement source
and binary, recovery snapshots, baseline copy and analysis are retained under
**`test-results/opi-round3-1f56ca03-20260906/`** (gitignored). Build/signing
inputs remain with the image builder; no private key is included here. The
prior-round report and raw audio evidence remain unchanged.

At **07:30:49 UTC**, A remained active/booted/good, B good, A=3/B=3, system
`running`, no failed units after clearing only this run's failed transient
publisher unit. Engine PID **797**, NRestarts **0**, `KillMode=process`;
all media loads and queues zero, DMA-BUF census **0 objects / 0 bytes**.
No capture-measure/gst-launch/srtla_send process remained. The local host
receivers were stopped; a later redundant stop reported the transient units
already unloaded. Test executables/scripts were removed from the board;
raw `/tmp` evidence remains available until reboot. HDMI still locked at the
mode above; DJI Mic Mini still enumerated.

CeraUI was left idle with **Test Pattern, 1080p30, Auto codec, 5 Mbps, HDMI
Input audio**, restoring the pre-run selections. The inherited custom bench
destination **192.168.78.228:15000** remains configured, but its receiver is
stopped: choose a live destination before broadcasting. SSH remains enabled.
No credential changed. No Rock 5B+ access, package/driver fix, PR, commit,
release, or plan-checkbox change occurred.
