#!/usr/bin/env bash
#
# copy-census.sh — one classified row per RK3588 graph shape.
#
# THE QUESTION IT ANSWERS (todo 3(b), A11). Every buffer boundary in an RK3588
# graph either imports a dma-buf or copies it. The census is the DENOMINATOR
# the island's RGA work closes against, so "how many copies" is not enough on
# its own: each one has to carry a class that says whether closing it is even
# in scope.
#
#   REQUIRED   inherent to the shape. A system-memory source has to be staged
#              into a dma-buf before an encoder can see it; no driver removes
#              that.
#   AVOIDABLE  both sides could have imported and one of them did not. This is
#              the class the island is expected to shrink.
#   TEMPORARY  the copy exists only because a capability is missing from the
#              CURRENT stack. The live example is librga with no /dev/rga: the
#              accelerated blit is refused, so the plugin copies in software.
#              The island's RGA flip restores the device and the copy goes.
#   BUG        the copy accompanies a refusal from hardware that IS present.
#
# WHY THE CLASSIFIER TAKES ONLY MEASURED FACTS. Everything above is decided by
# `classify_boundary` from six inputs, five of which are counted by other
# probes in this harness and one of which (`--source-memory`) is a property of
# the pipeline the caller wrote, not a judgement about it. That is deliberate:
# a census whose classes came from prose would be unfalsifiable, and the whole
# point of this row is that a later reader can re-derive it.
#
# EVIDENCE PER ROW, FROM THREE PLACES.
#   fd-trace.sh    dma-buf inode churn and element attribution for the window
#   the pipeline's own GST_DEBUG log   gst_video_frame_copy / rga_api version
#   dmesg          RGA_BLIT fail / RGA_MMU / rkvenc lines in the same window
#
# dmesg rather than the journal on purpose: the copy signals that matter here
# are kernel messages, the shipped image lets an unprivileged operator read the
# kernel ring buffer, and the journal needs a privilege this harness would
# rather not take for a read it can get honestly.
#
# AN UNREACHABLE SHAPE IS A ROW, NOT AN OMISSION. `--unreachable` writes a row
# whose class is UNREACHABLE and whose reason is the evidence. A shape that
# silently vanishes from the table makes the denominator wrong.
#
# READ-ONLY. Runs the caller's pipeline and optional publisher inside its own
# work directory, reads /proc and the kernel ring buffer. No unit is
# controlled, no module is loaded, nothing under /sys is written.
#
# Usage:
#   copy-census.sh --shape NAME --pipeline 'PIPE' --source-memory sysmem|dmabuf
#                  [--publisher 'CMD'] [--seconds N] [--work DIR]
#   copy-census.sh --shape NAME --unreachable 'REASON'
#   copy-census.sh --self-test
#
# Output: one `census_row=` line per invocation, plus the raw evidence.
#   census_row=shape=<s> boundary=<b> class=<C> software_copies=<n>
#              new_inodes=<n> fds_crossing=<n> rga_blit_fail=<n>
#              rga_api_version=<n> rga_chardev=<present|absent>
#              source_memory=<m> frames=<n> evidence=<path> reason=<text>
#
# Exit: 0 a row was emitted, 1 the shape was requested but produced nothing,
#       2 usage.

set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness-lib.sh
. "${HARNESS_DIR}/lib/harness-lib.sh"

SHAPE=
PIPELINE=
PUBLISHER=
SOURCE_MEMORY=sysmem
UNREACHABLE=
SECONDS_TO_RUN=10
WORK=

# ---------------------------------------------------------------------------
# The classifier — pure, and the only place a class is decided
# ---------------------------------------------------------------------------

# classify_boundary <rga_chardev> <software_copies> <new_inodes>
#                   <fds_crossing> <rga_blit_fail> <source_memory>
classify_boundary() {
  local chardev=$1 copies=$2 new_inodes=$3 crossing=$4 blit_fail=$5 memory=$6

  if [ "${blit_fail}" -gt 0 ]; then
    printf 'BUG|a blit was attempted and refused by hardware that is present\n'
    return
  fi
  if [ "${copies}" -gt 0 ]; then
    if [ "${chardev}" = absent ]; then
      printf 'TEMPORARY|librga has no /dev/rga on this stack, so the accelerated blit is unavailable and the copy is done in software; the RGA flip removes it\n'
    else
      printf 'AVOIDABLE|both sides can import a dma-buf and one of them copied anyway\n'
    fi
    return
  fi
  if [ "${new_inodes}" -gt 0 ]; then
    if [ "${memory}" = sysmem ]; then
      printf 'REQUIRED|a system-memory source must be staged into a dma-buf before the encoder can import it\n'
      return
    fi
    printf 'AVOIDABLE|the window allocated fresh dma-bufs although the source already produced them\n'
    return
  fi
  if [ "${crossing}" -gt 0 ]; then
    printf 'NO-COPY|a dma-buf crossed the boundary by import and the pool was stable\n'
    return
  fi
  printf 'NO-COPY|no allocation and no software copy was observed in the window\n'
}

# classify_launch_failure <launch-log-text> <pipeline>
#
# The backticks below are markdown code fences in the reason text a reader sees,
# not command substitution; SC2016 cannot tell the difference.
# shellcheck disable=SC2016
classify_launch_failure() {
  local log=$1 pipeline=$2 el
  if printf '%s\n' "${log}" | grep -qE 'no property|could not set property'; then
    el="$(printf '%s\n' "${log}" | sed -n 's/.*no property "\([^"]*\)".*/\1/p' | head -1)"
    printf 'BLOCKED-PLUGIN-ABI|the installed MPP plugin has no property `%s`; this board ships a different gstreamer1.0-rockchip build and the pipeline was rejected before it ran\n' \
      "${el:-<unnamed>}"
    return
  fi
  if printf '%s\n' "${log}" | grep -q 'not-negotiated'; then
    if printf '%s\n' "${pipeline}" | grep -qE 'mppvideodec|mppjpegdec'; then
      el="$(printf '%s\n' "${pipeline}" | grep -oE 'mppvideodec|mppjpegdec' | head -1)"
      printf 'BLOCKED-NO-MPP-DECODER|`%s` is registered but negotiated nothing (not-negotiated): the kernel MPP service exposes no decoder client, so this decode boundary cannot be entered on the shipped stack\n' \
        "${el}"
      return
    fi
    printf 'BLOCKED-NOT-NEGOTIATED|the pipeline failed caps negotiation before any buffer crossed a boundary\n'
    return
  fi
  if printf '%s\n' "${log}" | grep -q 'no element'; then
    printf 'BLOCKED-MISSING-ELEMENT|an element named in this shape is not installed on this board\n'
    return
  fi
  printf 'NOT-RUN|the shape produced no dma-buf trace and named no cause (see the raw log)\n'
}

emit_census_row() {
  printf 'census_row=shape=%s boundary=%s class=%s software_copies=%s new_inodes=%s fds_crossing=%s rga_blit_fail=%s rga_api_version=%s rga_chardev=%s source_memory=%s frames=%s evidence=%s reason=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}" "${13}"
}

# ---------------------------------------------------------------------------
# Evidence collection
# ---------------------------------------------------------------------------

rga_chardev_state() { [ -e /dev/rga ] && printf 'present\n' || printf 'absent\n'; }

# dmesg_window <before-file> <after-file> <pattern> — occurrences that appeared
# BETWEEN the two captures. Counting the whole ring buffer would attribute
# every boot-time line to this measurement.
dmesg_window() {
  local before=$1 after=$2 pattern=$3 b a
  b=$(grep -cF -- "${pattern}" "${before}" 2>/dev/null || true)
  a=$(grep -cF -- "${pattern}" "${after}" 2>/dev/null || true)
  local d=$((a - b))
  [ "${d}" -ge 0 ] || d=0
  printf '%s\n' "${d}"
}

count_in() { grep -cF -- "$2" "$1" 2>/dev/null || true; }

run_shape() {
  local work=$1 pub_pid='' rc=0
  local trace_log="${work}/fd-trace.txt"

  dmesg >"${work}/dmesg-before.txt" 2>/dev/null || : >"${work}/dmesg-before.txt"

  if [ -n "${PUBLISHER}" ]; then
    printf 'publisher=%s\n' "${PUBLISHER}"
    # Word-splitting is wrong for a whole command line, so the publisher runs
    # through a shell. Its stdin is closed: this script is frequently delivered
    # over `ssh … bash -s`, and an ffmpeg publisher that reads stdin eats the
    # rest of the script.
    ( eval "${PUBLISHER}" ) </dev/null >"${work}/publisher.log" 2>&1 &
    pub_pid=$!
    sleep 3
  fi

  # fd-trace owns the launch: it captures the GST_MEMORY log and both fd maps,
  # which is exactly the evidence pair this row needs.
  "${HARNESS_DIR}/fd-trace.sh" --launch "${PIPELINE}" --seconds "${SECONDS_TO_RUN}" \
    --out "${work}" --gst-debug 'GST_MEMORY:7,mppenc:5,mppvideodec:4' \
    >"${trace_log}" 2>&1 || rc=1

  if [ -n "${pub_pid}" ]; then
    kill "${pub_pid}" 2>/dev/null
    wait "${pub_pid}" 2>/dev/null
  fi

  dmesg >"${work}/dmesg-after.txt" 2>/dev/null || : >"${work}/dmesg-after.txt"
  return "${rc}"
}

score_shape() {
  local work=$1
  local trace_log="${work}/fd-trace.txt"
  local gst_log="${work}/launch.gstmemory.log"
  local copies new_inodes crossing blit_fail api_version chardev frames class reason boundary

  copies=$(sed -n 's/^software_copy_lines=//p' "${trace_log}" | tail -1)
  [ -n "${copies}" ] || copies=0
  crossing=$(sed -n 's/^fds_crossing_an_element_boundary=//p' "${trace_log}" | tail -1)
  [ -n "${crossing}" ] || crossing=0
  new_inodes=$(sed -n 's/^churn new_inodes=\([0-9]*\).*/\1/p' "${trace_log}" | tail -1)
  [ -n "${new_inodes}" ] || new_inodes=0

  # librga announces itself once per process the first time it is entered, so a
  # non-zero count here means the graph went through librga at all.
  api_version=$(count_in "${gst_log}" 'rga_api version')
  blit_fail=$(dmesg_window "${work}/dmesg-before.txt" "${work}/dmesg-after.txt" 'RGA_BLIT fail')
  # A userspace-visible refusal counts too: librga prints it on the process's
  # own stderr, which is captured in the pipeline log.
  local blit_fail_user
  blit_fail_user=$(count_in "${gst_log}" 'RGA_BLIT fail')
  blit_fail=$((blit_fail + blit_fail_user))

  chardev=$(rga_chardev_state)
  frames=$(grep -c 'chain' "${gst_log}" 2>/dev/null || true)

  local verdict launched=yes
  if grep -q 'the pipeline exited before it could be traced' "${trace_log}" 2>/dev/null ||
    grep -qE '^ERROR|erroneous pipeline' "${gst_log}" 2>/dev/null; then
    launched=no
  fi
  if [ "${launched}" = no ]; then
    verdict="$(classify_launch_failure "$(cat "${trace_log}" "${gst_log}" 2>/dev/null)" "${PIPELINE}")"
    copies=n/a; new_inodes=n/a; crossing=n/a
  else
    verdict="$(classify_boundary "${chardev}" "${copies}" "${new_inodes}" \
      "${crossing}" "${blit_fail}" "${SOURCE_MEMORY}")"
  fi
  class="${verdict%%|*}"
  reason="${verdict#*|}"
  boundary=whole-graph-window

  printf -- '--- fd-trace ---\n'
  cat "${trace_log}"
  printf -- '--- kernel-ring delta in the window ---\n'
  local p
  for p in 'RGA_BLIT fail' 'RGA_MMU' 'rkvenc' 'rga'; do
    printf 'dmesg_delta pattern=%q occurrences=%s\n' "${p}" \
      "$(dmesg_window "${work}/dmesg-before.txt" "${work}/dmesg-after.txt" "${p}")"
  done
  printf 'pipeline_log_counts gst_video_frame_copy=%s rga_api_version=%s\n' \
    "$(count_in "${gst_log}" 'gst_video_frame_copy')" "${api_version}"

  emit_census_row "${SHAPE}" "${boundary}" "${class}" "${copies}" "${new_inodes}" \
    "${crossing}" "${blit_fail}" "${api_version}" "${chardev}" "${SOURCE_MEMORY}" \
    "${frames}" "${work}" "${reason}"
}

# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------
#
# The classifier is the whole risk surface here, so every class is exercised —
# including the two that are easy to conflate (TEMPORARY vs AVOIDABLE differ
# ONLY by whether the RGA character device exists) and the one that must win
# over all of them (BUG). A classifier that collapsed to a single answer would
# fail on the second assertion.
self_test() {
  local rc=0 got

  printf 'self_test=copy-census\n'

  expect() {
    local what=$1 want=$2 have=$3
    if [ "${want}" = "${have}" ]; then
      printf 'assert %s=%s ok\n' "${what}" "${have}"
    else
      harness_fail_msg "${what}=${have}, expected ${want}"
      rc=1
    fi
  }
  class_of() { classify_boundary "$@" | cut -d'|' -f1; }

  #        chardev  copies new  cross blit  memory
  expect bug "BUG" "$(class_of present 3 4 0 2 dmabuf)"
  expect bug.wins-over-copies "BUG" "$(class_of absent 9 9 9 1 sysmem)"
  expect temporary "TEMPORARY" "$(class_of absent 13497 6 0 0 dmabuf)"
  expect avoidable.copying "AVOIDABLE" "$(class_of present 12 6 0 0 dmabuf)"
  expect required.sysmem "REQUIRED" "$(class_of absent 0 6 0 0 sysmem)"
  expect avoidable.alloc "AVOIDABLE" "$(class_of absent 0 6 0 0 dmabuf)"
  expect nocopy.import "NO-COPY" "$(class_of absent 0 0 4 0 dmabuf)"
  expect nocopy.quiet "NO-COPY" "$(class_of present 0 0 0 0 sysmem)"

  # A shape that did not launch must name WHY, and must never score as a clean
  # boundary. All five terminal causes are locked.
  fail_of() { classify_launch_failure "$1" "$2" | cut -d'|' -f1; }
  expect blocked.abi BLOCKED-PLUGIN-ABI \
    "$(fail_of 'WARNING: erroneous pipeline: no property "bitrate" in element "mpph264enc0"' 'mpph264enc bitrate=8000000')"
  expect blocked.mpp BLOCKED-NO-MPP-DECODER \
    "$(fail_of 'streaming stopped, reason not-negotiated (-4)' 'filesrc ! jpegparse ! mppjpegdec ! mpph264enc')"
  expect blocked.negotiation BLOCKED-NOT-NEGOTIATED \
    "$(fail_of 'streaming stopped, reason not-negotiated (-4)' 'videotestsrc ! mpph264enc')"
  expect blocked.element BLOCKED-MISSING-ELEMENT \
    "$(fail_of 'no element "nosuchelement"' 'nosuchelement ! fakesink')"
  expect blocked.unknown NOT-RUN \
    "$(fail_of 'nothing informative here' 'videotestsrc ! fakesink')"
  got=$(classify_launch_failure 'streaming stopped, reason not-negotiated (-4)' 'filesrc ! jpegparse ! mppjpegdec ! mpph264enc' | cut -d'|' -f2)
  printf '%s\n' "${got}" | grep -q 'mppjpegdec' || {
    harness_fail_msg "the MPP-decoder reason does not name the element that failed"
    rc=1
  }
  printf 'assert blocked reason names the failing element ok\n'

  # The reason text must never be empty: a class with no reason is not evidence.
  got=$(classify_boundary absent 5 0 0 0 dmabuf | cut -d'|' -f2)
  if [ -n "${got}" ]; then
    printf 'assert reason-present ok\n'
  else
    harness_fail_msg "a class was returned with no reason"
    rc=1
  fi

  # The unreachable row must carry the class UNREACHABLE and the reason, and
  # must never render a copy count that would read as a measurement.
  got=$(SHAPE=hdmi-4k60-encode emit_census_row hdmi-4k60-encode 'n/a' UNREACHABLE \
    n/a n/a n/a n/a n/a n/a n/a n/a '' 'no 4K59.94 signal' |
    sed -n 's/.*class=\([A-Z-]*\).*/\1/p')
  expect unreachable.class UNREACHABLE "${got}"

  # The dmesg window must be a DELTA, not a total: a pattern already present
  # before the window may not be attributed to it.
  local work
  work="$(mktemp -d)" || return "${HARNESS_FAIL}"
  # shellcheck disable=SC2064
  trap "rm -rf '${work}'" RETURN
  printf 'boot line\nRGA_BLIT fail 1\nRGA_BLIT fail 2\n' >"${work}/before.txt"
  printf 'boot line\nRGA_BLIT fail 1\nRGA_BLIT fail 2\nRGA_BLIT fail 3\n' >"${work}/after.txt"
  expect dmesg.delta 1 "$(dmesg_window "${work}/before.txt" "${work}/after.txt" 'RGA_BLIT fail')"
  expect dmesg.no-change 0 "$(dmesg_window "${work}/before.txt" "${work}/before.txt" 'RGA_BLIT fail')"
  # A ring buffer that wrapped (fewer lines after than before) must clamp to 0
  # rather than report a negative "count".
  expect dmesg.wrapped 0 "$(dmesg_window "${work}/after.txt" "${work}/before.txt" 'RGA_BLIT fail')"

  [ "${rc}" -eq 0 ] || {
    harness_verdict FAIL "self-test"
    return $?
  }
  harness_verdict PASS "self-test: every class reachable, BUG wins, dmesg window is a delta"
}

usage() {
  sed -n '2,62p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --self-test)
        self_test
        exit $?
        ;;
      --shape)
        SHAPE=${2:-}
        shift 2
        ;;
      --pipeline)
        PIPELINE=${2:-}
        shift 2
        ;;
      --publisher)
        PUBLISHER=${2:-}
        shift 2
        ;;
      --source-memory)
        SOURCE_MEMORY=${2:-}
        shift 2
        ;;
      --unreachable)
        UNREACHABLE=${2:-}
        shift 2
        ;;
      --seconds)
        SECONDS_TO_RUN=${2:-}
        shift 2
        ;;
      --work)
        WORK=${2:-}
        shift 2
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

  [ -n "${SHAPE}" ] || {
    harness_fail_msg "--shape is required"
    usage
    exit "${HARNESS_USAGE}"
  }

  if [ -n "${UNREACHABLE}" ]; then
    emit_census_row "${SHAPE}" 'n/a' UNREACHABLE n/a n/a n/a n/a n/a \
      "$(rga_chardev_state)" "${SOURCE_MEMORY}" 0 'n/a' "${UNREACHABLE}"
    harness_verdict PASS "unreachable shape recorded with its reason"
    exit $?
  fi

  [ -n "${PIPELINE}" ] || {
    harness_fail_msg "--pipeline or --unreachable is required"
    usage
    exit "${HARNESS_USAGE}"
  }
  case "${SOURCE_MEMORY}" in sysmem | dmabuf) ;; *)
    harness_fail_msg "--source-memory must be sysmem or dmabuf"
    exit "${HARNESS_USAGE}"
    ;;
  esac

  require_tools gst-launch-1.0 awk sed || exit "${HARNESS_USAGE}"

  [ -n "${WORK}" ] || WORK="$(harness_out_dir "copy-census-${SHAPE}")" || exit "${HARNESS_FAIL}"
  mkdir -p "${WORK}" || exit "${HARNESS_FAIL}"
  printf 'shape=%s work_dir=%s seconds=%s source_memory=%s\n' \
    "${SHAPE}" "${WORK}" "${SECONDS_TO_RUN}" "${SOURCE_MEMORY}"

  run_shape "${WORK}"
  score_shape "${WORK}"
  harness_verdict PASS "census row emitted for ${SHAPE}"
  exit $?
}

main "$@"
