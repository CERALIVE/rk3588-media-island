# Modernization baseline — 2026-09-05

The initial pass below used read-only SSH checks and one live encode on the
existing kernels. The owner-authorized follow-up later in this document builds
and inserts matching modules, installs perf, and measures real camera A/B runs.
No kernel image, DTB, boot state or persistent module installation was changed.
Credentials were read at execution time and are deliberately not part of this
record. Private credential paths are not a repository dependency.

## Rock 5B+

Authenticated SSH at the owner-corrected DHCP address succeeded. Observed:

```text
Linux ceralive2 7.2.0-ceralive-rk3588 #ceralive1 SMP PREEMPT @1788474771 aarch64 GNU/Linux
os=debian 13
No such element or plugin 'mpph264enc'
CONFIG_PERF_EVENTS=y
CONFIG_DEV_COREDUMP=y
CONFIG_ROCKCHIP_MPP_SERVICE=m
CONFIG_ROCKCHIP_MPP_RKVENC2=y
CONFIG_ROCKCHIP_MPP_RKVDEC2=y
CONFIG_ROCKCHIP_MPP_JPGDEC=y
# CONFIG_ROCKCHIP_MPP_CERALIVE_TEST is not set
CONFIG_ROCKCHIP_MULTI_RGA=m
ls: cannot access '/dev/*mpp*': No such file or directory
ls: cannot access '/dev/rga': No such file or directory
ls: cannot access '/sys/module/rk_vcodec': No such file or directory
ls: cannot access '/sys/module/rga_multicore': No such file or directory
gstreamer1.0-rockchip-ceralive  1.14.4+ceralive.1
linux-image-7.2.0-ceralive-rk3588  7.2.0-ceralive1
ls: cannot access '/sys/kernel/tracing/events': No such file or directory
ls: cannot access '/sys/kernel/debug/tracing/events': No such file or directory
```

`command -v perf` produced no path. The privileged inventory confirmed the
missing device/module and trace-event paths. The installed plugin file exists,
but factory registration is absent; this task did not diagnose or repair that
separate board condition. **No Rock encode baseline was measured.**

## Orange Pi 5+

```text
Linux ceralive 7.2.0-ceralive-rk3588 #3 SMP PREEMPT Thu Sep  3 20:11:22 -05 2026 aarch64 GNU/Linux
mpp_service=present
```

The encoder factory registered and exposed `bitrate`, `bitrate-max`,
`bitrate-min` and `rc-mode`; `command -v perf` produced no path. Ran:

```bash
TIMEFORMAT='elapsed_seconds=%R user_seconds=%U system_seconds=%S cpu_pct=%P'
time timeout 40 gst-launch-1.0 -e \
  videotestsrc is-live=true num-buffers=1200 \
  ! video/x-raw,format=NV12,width=1920,height=1080,framerate=60/1 \
  ! mpph264enc ! h264parse ! fakesink sync=false
```

```text
Setting pipeline to PAUSED ...
Pipeline is live and does not need PREROLL ...
Pipeline is PREROLLED ...
Setting pipeline to PLAYING ...
New clock: GstSystemClock
Redistribute latency...
Redistribute latency...
Got EOS from element "pipeline0".
EOS received - stopping pipeline...
Execution ended after 0:00:20.127945638
Setting pipeline to NULL ...
Freeing pipeline ...
elapsed_seconds=20.430 user_seconds=6.322 system_seconds=5.402 cpu_pct=57.38
```

Exit status was zero. The buffer count is the configured **source** count, not
an independently decoded output-frame census. Codec settings were the installed
encoder's defaults. This single run includes process startup/teardown CPU and
elapsed time and occurred on a running appliance, not an isolated benchmark
boot. The island source SHA of the loaded module was not established. Do not
compare this Orange result against a later Rock result or claim sub-percent
statistical resolution from it.

## Initial mapping decision (superseded by the follow-up)

**UNMEASURABLE ON THIS BOARD** for the iommu_map time fraction: no perf binary
on either board; Rock also exposes no trace-event tree and cannot currently
instantiate the hardware encoder. No instrumentation was installed or enabled.
No measured percentage exists; neither ≥5% nor NOT-WORTH-IT can be asserted.
The driver mapping algorithm is unchanged.

**Cost gate PARTIAL:** a pre-change Orange baseline exists. The after comparison
requires the modified kernel on the same board, which the owner explicitly
excluded from this task. Retake controlled baselines with repeated runs and
verified module identity as part of that future deployment drill.

## Follow-up: matching-config module experiment

**Current result:** the PR's MPP module loads normally and encodes real HDMI
camera frames. The RGA module passes the loader's ABI checks but its init returns
`-EFAULT` because this image still has the pre-RGA-flip device-tree identities.
This is **not** an unavailable board, mainline-version mismatch, or missing
kernel-header-package barrier. Perf is now installed and actual before/after
measurements exist. The complete performance acceptance gate is **not passed**.

### Source identity: same mainline base, older island/image integration

On 2026-09-05, authenticated SSH and password-authenticated sudo both worked.
The running kernel reported:

```text
Linux version 7.2.0-ceralive-rk3588 (ceralive@ceralive-builder)
(aarch64-linux-gnu-gcc (Debian 14.2.0-19) 14.2.0,
GNU ld (GNU Binutils for Debian) 2.44)
#ceralive1 SMP PREEMPT @1788474771
```

`uname` alone cannot identify a source commit. The additional provenance was:

- `/etc/ceralive/image-build-commit` names
  `fd453f12a1ef13259695632bf65f1d9bd3ef7db5`.
- That immutable image commit's
  [`manifests/families/rk3588.yaml`](https://github.com/CERALIVE/image-building-pipeline/blob/fd453f12a1ef13259695632bf65f1d9bd3ef7db5/manifests/families/rk3588.yaml)
  pins Linux `v7.2` at **`8d3ae59288f1e7d58d76558a6ee96d533bc5019f`**, the
  exact peeled base in this repository's `kernel-pin.env`.
- Its consumer patch pin is `cb491dc16fc102649c7d4c003ea954cfa9e3c494`, carrying
  island **v2026.9.0**, not this PR. Installed files include `rk_vcodec.ko` and
  the older `rga3.ko`; neither was loaded before the experiment.
- `1788474771` is **2026-09-03T22:32:51Z**, exactly the image-builder commit's
  date. It is not the Linux commit date, which is 2026-08-16T21:32:26Z.

Thus the recorded mainline source base matches; the complete patched image and
its older island/DT integration do not equal this PR. The manifest is provenance
evidence, not a claim that a uname timestamp cryptographically identifies a binary.

### Build inputs and artifacts

Pulled the complete `zcat /proc/config.gz` output rather than reusing the CI
fragment. Used the board's compiler and linker versions in the local Trixie
kernel-builder container, the pinned Linux tag/commit, and immutable PR source
`0ec331c907820c7e32d1157ca6a23cadd5829366`. The shared checkout was switched by
another process during the work; source was therefore extracted by immutable
commit and follow-up documentation was isolated in its own worktree.

Configured with `merge_config.sh -m <board.config>` and `olddefconfig`, using
`LOCALVERSION=-ceralive-rk3588`. Built `vmlinux`, `modules_prepare`, exposed
`vmlinux.symvers` as `Module.symvers`, and built both external module directories
with `KCFLAGS=-Werror`. Both module builds succeeded.

```text
board.config SHA256:
6ae7d27e262c861a8ccfda364c3d9cc00e33a38f61e72edaf551d07d18e90d03
normalized .config SHA256:
b2cf02ab5df3ac20c14f873518e25f5d9651ec544e1d70743daef532ff721400
scripts/diffconfig output:
-DMABUF_HEAPS_SYSTEM_UNCACHED y
```

That image-side heap option has no Kconfig definition in the module-only
integration tree. No CI fragment was merged over the board config. In particular,
the board's `FTRACE=n`, `KPROBES=n`, `MODVERSIONS=n`, and `MODULE_FORCE_LOAD=n`
were retained. There are no symbol-version CRCs to force past on this kernel.

| Artifact | SHA-256 |
|---|---|
| PR `rk_vcodec.ko` | `72896981283cc1ddb0b58c219f9918edc93c0b8e3d6946e74a08204c72bfca92` |
| PR `rga_multicore.ko` | `a0cedd3f9d800716921790708bd98f3edeed6372a493676d2e16b03c5663f13e` |
| Pre-PR `rk_vcodec.ko`, source `10894bc`, same tree/config/toolchain | `b3ce673c8807b38176346560a601bfa246850f4fa781e7b845241cc0b15c8ffe` |

All three have the exact running vermagic:

```text
7.2.0-ceralive-rk3588 SMP preempt mod_unload aarch64
```

### Exact insertion result, 2026-09-05T23:32:18Z

Copied the PR modules into `/tmp/ceralive-modernization.hDP6U4` and invoked
ordinary `insmod` under sudo, with full before/after `dmesg` snapshots:

```text
insmod ./rk_vcodec.ko
insmod_exit[rk_vcodec]=0
insmod ./rga_multicore.ko
insmod: ERROR: could not insert module ./rga_multicore.ko: Bad address
insmod_exit[rga_multicore]=1
```

Relevant **verbatim** kernel output from the insertion window:

```text
[152656.564176] rk_vcodec: loading out-of-tree module taints kernel.
[152656.573008] mpp_service mpp-srv: 6.18-rkvenc-fwport
[152656.573458] mpp_service mpp-srv: probe start
[152656.575088] mpp_jpgdec fdb90000.jpegd: probe device
[152656.575723] mpp_jpgdec fdb90000.jpegd: probing finish
[152656.610003] mpp_rkvenc2 fdbd0000.rkvenc-core: probing start
[152656.610639] mpp_rkvenc2 fdbd0000.rkvenc-core: attach ccu as core 0
[152656.611201] mpp_rkvenc2 fdbd0000.rkvenc-core: probing finish
[152656.611810] mpp_rkvenc2 fdbe0000.rkvenc-core: probing start
[152656.612456] mpp_rkvenc2 fdbe0000.rkvenc-core: attach ccu as core 1
[152656.613015] mpp_rkvenc2 fdbe0000.rkvenc-core: probing finish
[152656.613725] mpp_service mpp-srv: probe success
[152656.635093] rga: rga_iommu_bind, binding map scheduler failed!
[152656.635657] rga: rga iommu bind failed!
```

Both decoder cores also probed. `/dev/mpp_service` appeared; `/dev/rga` did not.
There was no `Unknown symbol` or vermagic rejection. RGA reached its own
`rga_iommu_bind()` fallback at `rga_iommu.c:514–518`, which returns `-EFAULT`
when no mapping scheduler was registered.

The concrete RGA mismatch is the **DT binding identity**:

| Block | Running DT compatible | PR module's corresponding compatible |
|---|---|---|
| RGA3 core0 | `rockchip,rk3588-rga3` | `rockchip,rga3_core0` |
| RGA3 core1 | `rockchip,rk3588-rga3` | `rockchip,rga3_core1` |
| RGA2 | `rockchip,rk3588-rga`, `rockchip,rk3288-rga` | `rockchip,rga2_core0` |

The module additionally accepts `rockchip,rga3` and `rockchip,rga2`; none match
those live aliases. The existing `rockchip_rga` remains bound to core0/RGA2.
The ownership changes are already maintained in integration patches `0020` and
`0021`; this experiment did not apply a DT overlay, force a driver override or
unbind a live driver. **Force-loading cannot repair this mismatch**, and is
disabled in the running kernel anyway. The actual remaining RGA wall is adoption
of the RGA ownership flip, not a Linux-version/CRC mismatch.

### Perf installation and the real camera

A fresh registry in the private test directory exposed `mpph264enc`,
`mpph265enc`, `mppvideodec` and `mppjpegdec`. The earlier factory absence was
stale registry state from probing before the MPP device existed; no GStreamer
plugin upgrade was necessary.

The actual camera input is `/dev/video1` (HDMI-RX), not `/dev/video0` (RGA).
`VIDIOC_QUERY_DV_TIMINGS` returned 3840×2160 progressive, pixel clock 593416000 Hz,
59.94 fps, and capture format NV16. A smoke run produced 60 H.264 output frames
at 1920×1080, independently counted by ffprobe.

The direct `apt-get install linux-perf` failed: HTTP package downloads were
redirected to `https://mi.tigo.com.co/assets/captive.html`, returning an 831-byte
HTML page and **Hash Sum mismatch**. The workaround downloaded the same 17 Debian
packages over HTTPS on the build host, checked their SHA-256 values against the
board's package metadata, copied them over SSH, and installed from a directory
readable by APT's `_apt` user. No integrity checks were disabled. Installation
finished with exit 0; **perf 6.12.107** successfully counted task-clock, cycles and
instructions on the running 7.2 kernel.

### Camera A/B: actual numbers, not an acceptance pass

Before is immutable source `10894bc`, not the older installed v2026.9.0 module.
After is PR source `0ec331c`. Loaded srcversions were respectively
`7D130C531FEDE4CEFB7F0B1` and `3C70B1D3130B26CA08C79B1`. Normal unload/load
succeeded for both. No forced removal was used.

Each trial ran the following pipeline under `taskset -c 4-7 perf stat`, with
`task-clock,cycles,instructions,context-switches,cpu-migrations` and semicolon
output. All CPU policies already used the `performance` governor; none was changed.

```bash
gst-launch-1.0 -e \
  v4l2src device=/dev/video1 io-mode=mmap num-buffers=600 \
  ! video/x-raw,format=NV16,width=3840,height=2160,framerate=60000/1001 \
  ! videoconvertscale n-threads=4 method=0 \
  ! video/x-raw,format=NV12,width=1920,height=1080 \
  ! mpph264enc bitrate=8000000 gop=60 level=4.2 \
  ! h264parse ! filesink location=trial.h264 sync=false
```

| Variant/run | perf task-clock (ms) | GStreamer execution (s) | ffprobe output frames | Frame-count gate |
|---|---:|---:|---:|---|
| Before 1 | 8630.88 | 10.253715 | 600 | pass |
| Before 2 | 8609.84 | 10.237488 | 599 | **fail** |
| Before 3 | 8206.23 | 10.246511 | 600 | pass |
| After 1 | 8641.98 | 10.269635 | 600 | pass |
| After 2 | 8622.99 | 10.243882 | 600 | pass |
| After 3 | 8646.48 | 10.231957 | 600 | pass |

Every pipeline exited 0 and reached EOS. The collector stopped at Before 2's
failed frame count and restored the PR module. The remaining planned trials were
then collected without overwriting that failure; the final frame gate exited 1.
Using only the valid, equal-frame trials:

```text
valid_before_mean_ms=8418.555000 n=2
valid_after_mean_ms=8637.150000 n=3
observed_task_clock_delta_pct=2.596586
baseline_valid_range_pct=5.044215
```

**The ≤1% cost gate is NOT PASSED.** These observations do not establish which
driver item caused the delta: the baseline itself spans 5.04%, one baseline trial
lost a frame, and this live scene/software-conversion workload is not a controlled
driver-only microbenchmark. Task-clock measures the pipeline process and its
threads, not all asynchronous kernel workers. RGA modernization is not exercised
because its module cannot bind this DT. The H.264 nominal `r_frame_rate` reported
by ffprobe was `120000/1001` in both variants; that metadata is not used to claim
120 fps or substitute for measured elapsed time and frame counts.

### Item (g): measured below threshold on this workload

Captured a separate **pre-PR** camera run with:

```bash
perf record -a -e cycles:k -F 999 --call-graph fp \
  -o before-kernel.perf.data -- <the same bounded camera pipeline>
```

Recording and `perf script` both exited 0. The record contains **13,896 samples**.
The exact pre-PR module was added to a private perf build-ID cache before decoding.
Userspace unwinding emitted `unwind: get_proc_name unsupported`; the analysis uses
resolved kernel/module frames only, not those userspace frames.

Setup attribution includes samples with a call-chain frame in
`mpp_process_task_default`, `rkvenc_alloc_task`, `rkvenc_run`, or `mpp_task_run`,
counted once per sample. The numerator requires `iommu_map` or `__iommu_map` in
the same setup sample. Summing recorded cycle periods gives:

```text
setup_samples=412
setup_cycle_period_sum=79592939
iommu_map_setup_samples=0
iommu_map_cycle_period_sum=0
sampled_iommu_map_fraction_pct=0.000000
```

**NOT-WORTH-IT for this measured steady-state encode workload:** observed mapping
cost did not reach 5%, so no `iommu_map_sg` change was made. This is a sampling
estimate, not a claim of literally zero execution time on every workload. The
remaining encoder page-wise RCB/SRAM mapping loop is in probe-time
`rkvenc2_alloc_rcbbuf()`, not per-frame setup. This does not qualify RGA mapping
performance on hardware that its driver never bound.

### Final state and retained evidence

The PR MPP module was restored after A/B, then removed with refcount 0 and
`rmmod` exit 0, restoring the initial unloaded-module state. Legacy
`rockchip_rga`/`hantro_vpu` were never removed. The out-of-tree taint bit remains
4096 until reboot; no force-load taint was introduced. Perf and its 16 dependencies
remain installed. No service restart, reboot, DTB change, persistent module-file
replacement or boot-state edit was performed. Both boot slots already had zero
attempts before the experiment and were left unchanged.

Raw evidence is retained in the experiment checkout under
`.work/rock5b-module-attempt/`: exact `board.config`, normalized config delta,
module build logs, `insmod-attempt.log`, before/after kernel snapshots, package
hash/install logs, six perf CSVs and frame-count records, kernel perf data/stacks,
and `analysis.txt`. Private camera captures remain in the board's private
`/tmp/ceralive-modernization.hDP6U4` directory; no camera footage is committed.
