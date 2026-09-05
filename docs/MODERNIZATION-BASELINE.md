# Modernization baseline — 2026-09-05

Read-only SSH checks and one live encode on the existing kernels. No package
installation, module loading, service restart, tracing configuration, or reboot.
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

## Mapping decision and outstanding comparison

**UNMEASURABLE ON THIS BOARD** for the iommu_map time fraction: no perf binary
on either board; Rock also exposes no trace-event tree and cannot currently
instantiate the hardware encoder. No instrumentation was installed or enabled.
No measured percentage exists; neither ≥5% nor NOT-WORTH-IT can be asserted.
The driver mapping algorithm is unchanged.

**Cost gate PARTIAL:** a pre-change Orange baseline exists. The after comparison
requires the modified kernel on the same board, which the owner explicitly
excluded from this task. Retake controlled baselines with repeated runs and
verified module identity as part of that future deployment drill.
