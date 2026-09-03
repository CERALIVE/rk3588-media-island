# Telemetry contract

The MPP and multi-RGA drivers expose trace events for timing and cumulative
counters for snapshots. Trace events are disabled by default. Their generated
call sites use the kernel tracepoint static-key branch, so disabled events do
not format records, allocate memory, or take locks; the hot path pays only the
patched unlikely branch defined by Linux's tracepoint machinery. That disabled
cost statement is specifically about trace recording. Counter maintenance is
always on and adds fixed atomic updates plus one monotonic timestamp around a
started hardware job.

The production fragment enables `FTRACE` plus `ENABLE_DEFAULT_TRACERS`, which
selects `TRACING`, `EVENT_TRACING`, and `TRACEPOINTS`; it explicitly leaves
`FUNCTION_TRACER` off. The linked MPP and RGA objects therefore carry Linux
`__jump_table` entries and tracepoint descriptors, while a disabled event stays
on the static-key false branch.

## MPP trace events

Tracefs system: `rockchip_mpp`.

| Event | Stable fields |
|---|---|
| `mpp_task_queued` | `session`, `task`, `client` |
| `mpp_core_selected` | `task`, `core`, `idle` |
| `mpp_task_started` | `core`, `task` |
| `mpp_task_done` | `core`, `task`, `ns` |
| `mpp_task_error` | `core`, `task`, `irq_status` |
| `mpp_reset` | `core`, `reason` |

The events are defined in `mpp_trace.h`; the sole `CREATE_TRACE_POINTS`
translation unit is `mpp_trace.c`. Core IDs come from the selected MPP device.
Consumers must not infer them from IRQ numbers.
`mpp_task_error` is emitted at most once per task. `irq_status=0` denotes a
failure before a hardware IRQ status existed; hardware and timeout failures
carry the status recorded on the task.

## RGA trace events

Tracefs system: `rockchip_rga`.

| Event | Stable fields |
|---|---|
| `rga_req_queued` | `session`, `request`, `tasks` |
| `rga_core_selected` | `request`, `scheduler`, `requested` |
| `rga_job_started` | `scheduler`, `request` |
| `rga_job_done` | `scheduler`, `request`, `ns` |
| `rga_job_timeout` | `scheduler`, `request` |
| `rga_reset` | `scheduler`, `reason` |

`rga_req_queued` precedes `rga_core_selected` for an accepted request. Reset
reasons use negative errno values (`-EIO`, `-EFAULT`, `-ETIMEDOUT`,
`-ECANCELED`, or `-ESHUTDOWN`); `0` identifies the RGA2 pre-run reset required
on hardware whose automatic reset is disabled.

## Diagnostic counter trees

With the production `CONFIG_DEBUG_FS=y` configuration:

```text
/sys/kernel/debug/rockchip-mpp/
  queue_depth
  cores/<n>/{busy_ns,tasks,errors,resets}
  sessions/<pid>-<session>/{client,tasks,bytes,stats}

/sys/kernel/debug/rockchip-rga/
  queue_depth
  cores/<n>/{busy_ns,tasks,errors,resets}
  sessions/<tgid>-<session>/{tasks,bytes,stats}
```

The MPP core number is the stable enumeration of every populated task-queue
core at service probe. The RGA core number is the scheduler registration index;
trace events carry that scheduler's hardware core mask. `queue_depth` counts
pending, not running, jobs and is decremented on dispatch, cancellation, and
shutdown.

Core counters are cumulative for the lifetime of the module object. `busy_ns`
spans successful hardware submission through completion for MPP, and through
completion, timeout, cancellation, or shutdown for RGA. Core `tasks` counts jobs
that reached hardware completion, including completion with an IRQ error.
`errors` counts a task once on MPP and counts RGA pre-start, IRQ, and timeout
failures; operator cancellation is not an error. `resets` counts every reset
attempt. Session `tasks` counts accepted submissions, while session `bytes`
counts imported MPP buffer extents or RGA command bytes. Reads use atomic
snapshots; IRQ and worker updates never take a telemetry lock.
Every per-session file takes a session reference at open and drops it at
release. Teardown removes the directory before dropping the owning reference,
so a reader opened before removal sees a valid final snapshot and no reader can
extend the visible lifetime of a closed session.

Each session's `stats` file is the fdinfo-style single-read form. MPP renders:

```text
client:\t<client-number>
tasks:\t<submitted-jobs>
bytes:\t<submitted-bytes>
```

RGA renders the same `tasks` and `bytes` lines without `client`. The individual
counter files remain available for simple metric collectors. Production pins
`CONFIG_DEBUG_FS=y` and `CONFIG_ROCKCHIP_RGA_DEBUG_FS=y`; consequently there is
no duplicate sysfs tree. If that production invariant changes, a sysfs mirror
is required before the debugfs symbols may be removed from the fragment.
In the schemas above, `\t` denotes one literal tab byte.

`tests/board/trace-dual-core.sh` correlates complete MPP lifecycles across two
cores. `tests/board/trace-rga.sh` runs the real NV12 RGA UAPI probe and correlates
one queued/selected/started/completed lifecycle while checking that all six RGA
event files are registered. Both have host-only mutation fixtures. KUnit calls
the production formatters and exactly-once state primitive; it does not replace
the board-gated trace probes.

## Frozen MPP procfs surface

`/proc/mpp_service/load_interval` is mode `0644` and holds milliseconds. A zero
interval makes `/proc/mpp_service/load` print exactly:

```text
please set load_interval first!!!
e.g. set 1000ms to load_interval:
echo 1000 > /proc/mpp_service/load_interval
```

When armed, each probed core uses this exact row format:

```text
%-25s load: %3d.%02d%% utilization: %3d.%02d%%\n
```

The current implementation accumulates `busy_time` from `task->on_run` until
the task is reaped and publishes that ratio as `load`. It accumulates
`hw_busy_time` from hardware cycles when available, otherwise from scheduled
start to IRQ, and publishes that ratio as `utilization`. This ordering is the
literal contract in `mpp_common.c`; the names must not be reinterpreted or
swapped by a consumer.

`/proc/mpp_service/sessions-summary` keeps these lines for every active session:

```text
session: pid=<pid> index=<i>
 device: <device-tree node name>
 memory: <MiB> MiB
```

The node names measured on the Orange Pi 5+ island kernel are
`fdbd0000.rkvenc-core`, `fdbe0000.rkvenc-core`,
`fdc38100.video-codec`, `fdc40100.video-codec`, and `fdb90000.jpegd`.

## Frozen RGA load surface

The existing RGA load file remains `/proc/rkrga/load`; the same callback is also
available at `/sys/kernel/debug/rkrga/load`. The new counter tree does not
replace either file. Its exact structure is:

```text
num of scheduler = <count>
================= load ==================
scheduler[<index>]: <driver-name>
\t load = <integer>%
-----------------------------------
... one block per scheduler ...
=========================================
<session>  <status>  <tgid>  <rga2-stage-bytes>  <process>
<id>       <active|idle>  <tgid>  <bytes>             <command-line>
```

RGA load is the scheduler's recorded hardware-busy microseconds divided by the
fixed load interval and capped at 100 percent. Session status is `active` while
`last_active` is within `RGA_LOAD_ACTIVE_MAX_US`, otherwise `idle`.

Changing any field name, line format, path, or meaning above is an
operator-visible contract change and must be called out in the island release.
Todo 16 adds verbatim idle, one-session, and two-session board captures under
`tests/fixtures/telemetry/<board>/`.
