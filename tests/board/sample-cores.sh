#!/usr/bin/env bash
#
# sample-cores.sh — per-core media-IRQ deltas at 1 s, alongside per-process fps.
#
# THE QUESTION IT ANSWERS. RK3588 has two RKVENC2 cores and three RGA cores, and
# the vendor driver dispatches each task to the FIRST IDLE core. Whether a given
# workload actually reaches the second core is therefore not a configuration
# fact — it is an observation, and the only first-party place it is visible from
# userspace is /proc/interrupts: one line per hardware core, one counter per
# CPU. A core that never fires an interrupt never ran a task.
#
# This is the pre-island number todo 3(d) records and todo 16 compares against.
# Two concurrent 4K30 encodes on the shipped stack should light BOTH rkvenc
# lines; a baseline where only rkvenc0 moves is itself the finding.
#
# FPS IS THE OTHER HALF, AND IT MUST BE PER PROCESS. IRQ deltas alone cannot
# distinguish "the second core is idle because dispatch never used it" from
# "the second core is idle because the second session produced no frames". So
# each measured process is driven with GStreamer's own framerate tracer
#
#     GST_DEBUG='GST_TRACER:7' GST_TRACERS=framerate <pipeline>
#
# and its log is attributed to that process's pid. Deltas and fps are then read
# together, which is the only way the dual-core claim is decidable.
#
# WHY DELTAS AND NOT TOTALS. /proc/interrupts counters are cumulative since
# boot, so a total says nothing about the measured window. Every row this emits
# is a difference between two samples taken `--interval` seconds apart.
#
# READ-ONLY. It reads /proc/interrupts and log files. It starts no service,
# loads no module, and writes nothing outside its own report directory.
#
# Usage:
#   sample-cores.sh [--duration N] [--interval N] [--out DIR]
#                   [--fps-log PID:FILE]... [--pattern REGEX]
#   sample-cores.sh --replay T0 T1 [--fps-log TAG:FILE]...
#   sample-cores.sh --chain-log TAG:FILE:ELAPSED ... [--score-only]
#   sample-cores.sh --self-test
#
#   --chain-log  derive per-process fps from an `identity silent=false` log
#                instead of the framerate tracer. The shipped GStreamer has no
#                `framerate` tracer -- `GST_TRACERS=framerate` answers
#                "no tracer named 'framerate'" and yields zero samples -- so on
#                these boards this is the only per-process fps that exists
#                without installing anything.
#
#   --replay  score two captured /proc/interrupts snapshots instead of sampling
#             live; this is how a measurement is re-scored without the board.
#   --pattern override the IRQ label filter (default below).
#
# Exit: 0 sampled, 1 failed, 2 usage.

set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness-lib.sh
. "${HARNESS_DIR}/lib/harness-lib.sh"

# The RK3588 media engines, by the label the driver registers. `vdpu`/`jpeg`
# are included because the copy census needs to see a decoder waking up.
readonly DEFAULT_IRQ_PATTERN='rkvenc|rkvdec|vdpu|vepu|rga|jpeg|hevc'

DURATION=60
INTERVAL=1
OUT_DIR=
IRQ_PATTERN="${DEFAULT_IRQ_PATTERN}"
REPLAY_T0=
REPLAY_T1=
SCORE_ONLY=0
declare -a FPS_LOGS=()
declare -a CHAIN_LOGS=()

# ---------------------------------------------------------------------------
# /proc/interrupts parsing
# ---------------------------------------------------------------------------
#
# Format: an optional header naming CPU0..CPUn, then one line per IRQ:
#   " 101:  1000  0  ...  GICv3 143 Level  rkvenc0"
# The label is the trailing field(s); the counters are the numeric run after
# the "NNN:" column. Non-numeric IRQ names (IPI0, ERR) are skipped because they
# are not device interrupts.

# irq_rows <file> <pattern> — emits "<irq> <label> <c0> <c1> ..." per match.
irq_rows() {
  awk -v pat="$2" '
    /^[[:space:]]*[0-9]+:/ {
      irq = $1; sub(/:$/, "", irq)
      # counters run from field 2 until the first non-numeric field
      n = 0; counts = ""
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^[0-9]+$/) { counts = counts " " $i; n++ }
        else break
      }
      label = $NF
      if (label ~ pat) printf "%s %s%s\n", irq, label, counts
    }
  ' "$1"
}

# delta_rows <t0> <t1> <pattern> — emits one row per matching IRQ:
#   irq=<n> label=<l> total_delta=<d> per_cpu=<d0,d1,...> active_cpus=<k>
delta_rows() {
  local t0=$1 t1=$2 pat=$3
  join -j 1 \
    <(irq_rows "${t0}" "${pat}" | sort -k1,1) \
    <(irq_rows "${t1}" "${pat}" | sort -k1,1) |
    awk '
      {
        irq = $1
        # after join: irq label0 c0... label1 d0...
        # find the split point: the second field is label0, then counters until
        # a non-numeric field (label1), then the second counter run.
        i = 3
        n0 = 0
        while (i <= NF && $i ~ /^[0-9]+$/) { a[++n0] = $i; i++ }
        label = $i; i++
        n1 = 0
        while (i <= NF && $i ~ /^[0-9]+$/) { b[++n1] = $i; i++ }
        if (n0 != n1) { printf "irq=%s label=%s error=cpu_count_changed\n", irq, label; next }
        total = 0; active = 0; per = ""
        for (k = 1; k <= n0; k++) {
          d = b[k] - a[k]
          total += d
          if (d > 0) active++
          per = per (k == 1 ? "" : ",") d
        }
        printf "irq=%s label=%s total_delta=%d per_cpu=%s active_cpus=%d\n",
               irq, label, total, per, active
      }
    '
}

# ---------------------------------------------------------------------------
# fps attribution
# ---------------------------------------------------------------------------
#
# GStreamer's framerate tracer emits, once per second per measured pad:
#   ... GST_TRACER :0:: framerate, pad=(string)<pad>, fps=(uint)<n>;
# The pid is the second whitespace field of the GStreamer log line, but the
# caller's TAG is authoritative: run-baseline.sh knows which process it started.
fps_summary() {
  local tag=$1 file=$2
  [ -r "${file}" ] || {
    printf 'fps tag=%s file=%s status=missing\n' "${tag}" "${file}"
    return 1
  }
  awk -v tag="${tag}" '
    # Two producers are accepted, because the framerate TRACER is not present on
    # every image: the tracer prints "fps=(uint)N", while fpsdisplaysink -v
    # prints "... current: N.NN, average: N.NN". Reading only the first spelling
    # reports samples=0 on a board that measured perfectly well.
    match($0, /fps=\(uint\)[0-9]+/) {
      v = substr($0, RSTART + 10, RLENGTH - 10) + 0
      sum += v; n++
      if (n == 1 || v < min) min = v
      if (n == 1 || v > max) max = v
      next
    }
    match($0, /current: [0-9]+\.[0-9]+/) {
      v = substr($0, RSTART + 9, RLENGTH - 9) + 0
      sum += v; n++
      if (n == 1 || v < min) min = v
      if (n == 1 || v > max) max = v
    }
    END {
      if (n == 0) { printf "fps tag=%s samples=0 status=no_tracer_lines\n", tag; exit 1 }
      printf "fps tag=%s samples=%d mean=%.2f min=%.2f max=%.2f\n", tag, n, sum / n, min, max
    }
  ' "${file}"
}

# fps_from_chain_log <tag> <file> <elapsed-s>
#
# `gst-launch-1.0 -v ... ! identity name=X silent=false` prints exactly one
# `last-message = chain` line per buffer that crossed that pad. Frames divided
# by the measured wall-clock window is the per-process frame rate, taken from
# the same log the session already writes. It is a WINDOW MEAN, not a series,
# so no min/max is claimed -- reporting a spread this method cannot see would
# be a fabrication.
fps_from_chain_log() {
  local tag=$1 file=$2 elapsed=$3 frames
  [ -r "${file}" ] || {
    printf 'fps tag=%s file=%s status=missing\n' "${tag}" "${file}"
    return 1
  }
  frames=$(grep -c 'last-message = chain' "${file}" 2>/dev/null || true)
  [ -n "${frames}" ] || frames=0
  if [ "${frames}" -eq 0 ]; then
    printf 'fps tag=%s frames=0 elapsed_s=%s status=no_chain_lines source=identity-chain-count\n' \
      "${tag}" "${elapsed}"
    return 1
  fi
  awk -v tag="${tag}" -v n="${frames}" -v d="${elapsed}" \
    'BEGIN {
       if (d + 0 <= 0) { printf "fps tag=%s frames=%d elapsed_s=%s status=bad_window source=identity-chain-count\n", tag, n, d; exit 1 }
       printf "fps tag=%s frames=%d elapsed_s=%.2f mean=%.2f source=identity-chain-count\n", tag, n, d, n / d
     }'
}

# ---------------------------------------------------------------------------
# Live sampling
# ---------------------------------------------------------------------------

sample_live() {
  local out=$1 elapsed=0 idx=0 prev cur
  prev="${out}/interrupts-0000.txt"
  cp /proc/interrupts "${prev}" || return 1
  printf 'sampling duration_s=%s interval_s=%s pattern=%s\n' \
    "${DURATION}" "${INTERVAL}" "${IRQ_PATTERN}"

  while [ "${elapsed}" -lt "${DURATION}" ]; do
    sleep "${INTERVAL}"
    elapsed=$((elapsed + INTERVAL))
    idx=$((idx + 1))
    cur="$(printf '%s/interrupts-%04d.txt' "${out}" "${idx}")"
    cp /proc/interrupts "${cur}" || return 1
    printf -- '--- t=%ss ---\n' "${elapsed}"
    delta_rows "${prev}" "${cur}" "${IRQ_PATTERN}"
    prev="${cur}"
  done

  printf -- '--- window total (t=0 .. t=%ss) ---\n' "${elapsed}"
  delta_rows "${out}/interrupts-0000.txt" "${prev}" "${IRQ_PATTERN}"
}

# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------
#
# Scores the committed snapshot pair and the two committed tracer logs, and
# asserts the EXACT expected values. The fixture pair deliberately encodes the
# single-core dispatch signature this measurement exists to detect: rkvenc0
# advances by 600 on CPU0 while rkvenc1 does not advance at all.
self_test() {
  local fixtures rows rc=0 got

  fixtures="$(harness_fixtures_dir)" || {
    harness_fail_msg "fixture tree not found"
    return "${HARNESS_FAIL}"
  }
  local t0="${fixtures}/interrupts/rk3588-t0.txt"
  local t1="${fixtures}/interrupts/rk3588-t1.txt"
  if ! [ -r "${t0}" ] || ! [ -r "${t1}" ]; then
    harness_fail_msg "interrupts fixtures missing under ${fixtures}/interrupts"
    return "${HARNESS_FAIL}"
  fi

  printf 'self_test=sample-cores\n'
  rows="$(delta_rows "${t0}" "${t1}" "${IRQ_PATTERN}")"
  printf '%s\n' "${rows}"

  expect_row() {
    local label=$1 want=$2 line
    line=$(printf '%s\n' "${rows}" | grep " label=${label} " || true)
    [ -n "${line}" ] || {
      harness_fail_msg "no delta row for ${label}"
      return 1
    }
    got=$(printf '%s\n' "${line}" | sed -n 's/.*total_delta=\([0-9-]*\).*/\1/p')
    [ "${got}" = "${want}" ] || {
      harness_fail_msg "${label} total_delta=${got}, expected ${want}"
      return 1
    }
    printf 'assert label=%s total_delta=%s ok\n' "${label}" "${got}"
  }

  expect_row rkvenc0 600 || rc=1
  expect_row rkvenc1 0 || rc=1
  expect_row rga3_core0 60 || rc=1
  expect_row rga3_core1 0 || rc=1
  expect_row rkvdec0 0 || rc=1

  # The MAINLINE spelling, locked. This kernel registers the encoder cores as
  # fdbd0000.rkvenc-core / fdbe0000.rkvenc-core; the vendor rkvenc0/rkvenc1
  # names do not exist on it, and a matcher written against them silently
  # reports "no encoder IRQ" on hardware that ran perfectly well.
  expect_row fdbd0000.rkvenc-core 1802 || rc=1
  expect_row fdbe0000.rkvenc-core 1802 || rc=1

  # The non-media lines must be filtered out entirely: a sampler that reported
  # arch_timer would drown the media rows it exists to surface.
  if printf '%s\n' "${rows}" | grep -q 'label=arch_timer\|label=dwmmc'; then
    harness_fail_msg "the IRQ filter admitted a non-media line"
    rc=1
  else
    printf 'assert filter excludes non-media IRQ lines ok\n'
  fi

  # The single-core signature is the load-bearing observation.
  local active
  active=$(printf '%s\n' "${rows}" | grep ' label=rkvenc1 ' |
    sed -n 's/.*active_cpus=\([0-9]*\).*/\1/p')
  [ "${active}" = "0" ] || {
    harness_fail_msg "rkvenc1 active_cpus=${active}, expected 0 in this fixture"
    rc=1
  }
  printf 'assert rkvenc1 active_cpus=0 (single-core dispatch signature) ok\n'

  # The SHIPPED 7.2 kernel registers the encoder cores under their MAINLINE
  # node names — `fdbd0000.rkvenc-core` and `fdbe0000.rkvenc-core` — not the
  # vendor `rkvenc0`/`rkvenc1` spellings the fixture above uses and the plan
  # assumes. Both must score, and a reader must never hard-code either, so the
  # mainline pair is asserted too and it carries the OPPOSITE signature: both
  # cores advance, which is the reading the single-core fixture cannot produce.
  printf -- '--- mainline label pair ---\n'
  local mrows
  mrows="$(delta_rows "${fixtures}/interrupts/rk3588-mainline-t0.txt" \
    "${fixtures}/interrupts/rk3588-mainline-t1.txt" "${IRQ_PATTERN}")"
  printf '%s\n' "${mrows}"
  local mlabel mwant
  for mlabel in fdbd0000.rkvenc-core:1800 fdbe0000.rkvenc-core:1000; do
    mwant=${mlabel##*:}
    got=$(printf '%s\n' "${mrows}" | grep " label=${mlabel%%:*} " |
      sed -n 's/.*total_delta=\([0-9-]*\).*/\1/p')
    [ "${got}" = "${mwant}" ] || {
      harness_fail_msg "${mlabel%%:*} total_delta=${got}, expected ${mwant}"
      rc=1
    }
    printf 'assert label=%s total_delta=%s ok\n' "${mlabel%%:*}" "${got}"
  done
  got=$(printf '%s\n' "${mrows}" | grep ' label=fdbe0000.rkvenc-core ' |
    sed -n 's/.*active_cpus=\([0-9]*\).*/\1/p')
  [ "${got}" = "2" ] || {
    harness_fail_msg "mainline second core active_cpus=${got}, expected 2"
    rc=1
  }
  printf 'assert mainline second core fired (dual-core signature) ok\n'

  for tag_file in "a:${fixtures}/interrupts/framerate-tracer-a.log" \
    "b:${fixtures}/interrupts/framerate-tracer-b.log"; do
    fps_summary "${tag_file%%:*}" "${tag_file#*:}" || rc=1
  done

  got=$(fps_summary a "${fixtures}/interrupts/framerate-tracer-a.log" |
    sed -n 's/.*mean=\([0-9.]*\).*/\1/p')
  [ "${got}" = "30.00" ] || {
    harness_fail_msg "tracer-a mean fps=${got}, expected 30.00"
    rc=1
  }
  got=$(fps_summary b "${fixtures}/interrupts/framerate-tracer-b.log" |
    sed -n 's/.*mean=\([0-9.]*\).*/\1/p')
  [ "${got}" = "15.00" ] || {
    harness_fail_msg "tracer-b mean fps=${got}, expected 15.00"
    rc=1
  }
  [ "${rc}" -ne 0 ] ||
    printf 'assert per-process fps attribution ok (a=30.00 b=15.00)\n'

  # The second accepted producer. Neither bench board ships the framerate
  # tracer, so fpsdisplaysink -v output is the fps source there; a parser that
  # only knew the tracer spelling scored those runs as samples=0.
  got=$(fps_summary fpsdisp "${fixtures}/interrupts/framerate-fpsdisplaysink.log" |
    sed -n 's/.*mean=\([0-9.]*\).*/\1/p')
  [ "${got}" = "25.00" ] || {
    harness_fail_msg "fpsdisplaysink fixture mean fps=${got}, expected 25.00"
    rc=1
  }
  [ "${rc}" -ne 0 ] ||
    printf 'assert fpsdisplaysink fps parsing ok (mean=25.00)\n'

  # The identity-chain deriver, both directions. The decode fixture carries
  # exactly 120 chain lines, so a 4 s window must read 30.00 fps and a log with
  # no chain line must report itself rather than average to zero.
  printf -- '--- identity-chain fps ---\n'
  local chainfix="${fixtures}/decode/autoplug-hardware.log"
  if [ -r "${chainfix}" ]; then
    got=$(fps_from_chain_log a "${chainfix}" 4 | sed -n 's/.*mean=\([0-9.]*\).*/\1/p')
    [ "${got}" = "30.00" ] || {
      harness_fail_msg "identity-chain fps=${got}, expected 30.00 for 120 frames in 4 s"
      rc=1
    }
    printf 'assert identity-chain fps=%s ok\n' "${got}"
    got=$(fps_from_chain_log b "${chainfix}" 8 | sed -n 's/.*mean=\([0-9.]*\).*/\1/p')
    [ "${got}" = "15.00" ] || {
      harness_fail_msg "identity-chain fps=${got}, expected 15.00 for 120 frames in 8 s"
      rc=1
    }
    printf 'assert identity-chain fps=%s ok\n' "${got}"
  else
    harness_fail_msg "decode fixture missing: ${chainfix}"
    rc=1
  fi
  local nochain
  nochain="$(mktemp)"
  printf 'no chain lines here\n' >"${nochain}"
  if fps_from_chain_log z "${nochain}" 4 >/dev/null 2>&1; then
    harness_fail_msg "a log with no chain line was accepted as a frame rate"
    rc=1
  else
    printf 'assert empty chain log is reported, not averaged ok\n'
  fi
  rm -f "${nochain}"

  # A tracer log with no framerate lines must be reported, never averaged to 0.
  local empty
  empty="$(mktemp)"
  printf 'no tracer lines here\n' >"${empty}"
  if fps_summary empty "${empty}" >/dev/null 2>&1; then
    harness_fail_msg "an empty tracer log was accepted as a measurement"
    rc=1
  else
    printf 'assert empty tracer log is reported, not averaged ok\n'
  fi
  rm -f "${empty}"

  [ "${rc}" -eq 0 ] || {
    harness_verdict FAIL "self-test"
    return $?
  }
  harness_verdict PASS "self-test: IRQ deltas and fps attribution match the fixtures"
}

usage() {
  sed -n '2,42p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --self-test)
        self_test
        exit $?
        ;;
      --replay)
        REPLAY_T0=${2:-}
        REPLAY_T1=${3:-}
        shift 3
        ;;
      --duration)
        DURATION=${2:-}
        shift 2
        ;;
      --interval)
        INTERVAL=${2:-}
        shift 2
        ;;
      --out)
        OUT_DIR=${2:-}
        shift 2
        ;;
      --pattern)
        IRQ_PATTERN=${2:-}
        shift 2
        ;;
      --fps-log)
        FPS_LOGS+=("${2:-}")
        shift 2
        ;;
      --chain-log)
        CHAIN_LOGS+=("${2:-}")
        shift 2
        ;;
      --score-only)
        SCORE_ONLY=1
        shift
        ;;
      -h | --help)
        usage
        exit "${HARNESS_USAGE}"
        ;;
      *)
        harness_fail_msg "unknown argument: $1"
        usage
        exit "${HARNESS_USAGE}"
        ;;
    esac
  done

  require_tools awk join sort || exit "${HARNESS_USAGE}"

  if [ "${SCORE_ONLY}" -eq 1 ]; then
    printf 'mode=score-only (no IRQ sampling; scoring the requested logs)\n'
  elif [ -n "${REPLAY_T0}" ]; then
    if ! [ -r "${REPLAY_T0}" ] || ! [ -r "${REPLAY_T1}" ]; then
      harness_fail_msg "--replay needs two readable /proc/interrupts snapshots"
      exit "${HARNESS_USAGE}"
    fi
    printf 'mode=replay t0=%s t1=%s pattern=%s\n' "${REPLAY_T0}" "${REPLAY_T1}" "${IRQ_PATTERN}"
    delta_rows "${REPLAY_T0}" "${REPLAY_T1}" "${IRQ_PATTERN}"
  else
    case "${DURATION}${INTERVAL}" in *[!0-9]*)
      harness_fail_msg "--duration and --interval must be integers"
      exit "${HARNESS_USAGE}"
      ;;
    esac
    [ -r /proc/interrupts ] || {
      harness_fail_msg "/proc/interrupts is not readable on this host"
      exit "${HARNESS_FAIL}"
    }
    [ -n "${OUT_DIR}" ] || OUT_DIR="$(harness_out_dir sample-cores)" || exit "${HARNESS_FAIL}"
    mkdir -p "${OUT_DIR}" || exit "${HARNESS_FAIL}"
    printf 'mode=live report_dir=%s\n' "${OUT_DIR}"
    sample_live "${OUT_DIR}" || {
      harness_verdict FAIL "sampling failed"
      exit $?
    }
  fi

  local spec rc=0 rest
  for spec in ${FPS_LOGS[@]+"${FPS_LOGS[@]}"}; do
    fps_summary "${spec%%:*}" "${spec#*:}" || rc=1
  done
  for spec in ${CHAIN_LOGS[@]+"${CHAIN_LOGS[@]}"}; do
    rest="${spec#*:}"
    fps_from_chain_log "${spec%%:*}" "${rest%:*}" "${rest##*:}" || rc=1
  done

  [ "${rc}" -eq 0 ] || {
    harness_verdict FAIL "a requested fps log produced no usable frame count"
    exit $?
  }
  harness_verdict PASS "per-core deltas emitted above"
  exit $?
}

main "$@"
