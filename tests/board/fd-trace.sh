#!/usr/bin/env bash
#
# fd-trace.sh — dma-buf identity across element boundaries.
#
# THE QUESTION IT ANSWERS. The copy census (todo 3(b)) has to classify every
# buffer boundary in an RK3588 graph as REQUIRED / AVOIDABLE / TEMPORARY / BUG.
# "Is this boundary zero-copy?" is decidable, and it does not need guesswork:
#
#   * IF a buffer crosses a boundary by IMPORT, both sides reference the SAME
#     dma-buf. Two file descriptors onto one dma-buf share an INODE, so inode
#     identity — not fd number, which is per-process and reused — is the oracle.
#   * IF a boundary COPIES, a second dma-buf is allocated and a NEW inode
#     appears, once per frame, for as long as the pipeline runs.
#
# So the measurement is: watch the process's dma-buf inode set over a window.
# A pooled, zero-copy path holds a small fixed set and allocates nothing new
# after warm-up; a per-frame copy path grows the set monotonically. That growth
# rate IS the copy count, and it is visible with no instrumentation inside
# GStreamer at all.
#
# THE GST_MEMORY LOG IS THE SECOND, ATTRIBUTING HALF. The inode set says HOW
# MANY copies happen; it does not say WHICH element made them. `GST_DEBUG=
# GST_MEMORY:7` names the element beside each memory operation, so pairing
# (element, fd) from the log with (fd, inode) from /proc/<pid>/fd attributes a
# boundary to a specific element. An fd touched by more than one element is a
# buffer that CROSSED; an element that allocates a fresh fd per frame while its
# upstream already had one is the copy.
#
# WHY BOTH HALVES ARE REQUIRED. The log alone can be misread: fd numbers are
# recycled, so the same number can name two different buffers minutes apart. The
# inode map alone cannot attribute. Neither is sufficient; the pair is.
#
# READ-ONLY. It reads /proc/<pid>/fd and log files, and (in --launch mode) runs
# a pipeline the caller supplied. It changes no unit, no module, and nothing
# under /sys.
#
# Usage:
#   fd-trace.sh --pid PID [--samples N] [--interval S] [--out DIR]
#   fd-trace.sh --snapshot FILE                  score one captured fd map
#   fd-trace.sh --diff MAP0 MAP1                 buffer churn between two maps
#   fd-trace.sh --gst-log FILE                   element<->fd attribution
#   fd-trace.sh --launch 'PIPELINE' [--seconds N] run + trace in one step
#                               [--gst-debug SPEC]
#   fd-trace.sh --self-test
#
# --gst-debug overrides the launch-mode debug spec. The default is the minimum
# this probe needs (GST_MEMORY:7); the copy census widens it so the plugin's own
# copy and RGA lines land in the same log as the memory events they explain.
#
# The captured fd-map format (also what --pid writes) is one line per fd:
#   fd=<n> target=<readlink> inode=<ino> size=<bytes>
#
# Exit: 0 traced, 1 failed, 2 usage.

set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness-lib.sh
. "${HARNESS_DIR}/lib/harness-lib.sh"

# A dma-buf fd's symlink target. Modern kernels name it "/dmabuf:"; older ones
# expose it as an anon inode. Both spellings are matched, and nothing else is:
# /dev/dma_heap/* is the ALLOCATOR, not a buffer, and must never be counted.
readonly DMABUF_TARGET_RE='(^/dmabuf|anon_inode:[^ ]*dmabuf)'

PID=
SAMPLES=2
INTERVAL=2
OUT_DIR=
SNAPSHOT=
DIFF_A=
DIFF_B=
GST_LOG=
LAUNCH=
SECONDS_TO_RUN=10
GST_DEBUG_SPEC='GST_MEMORY:7'

# ---------------------------------------------------------------------------
# fd map capture + scoring
# ---------------------------------------------------------------------------

capture_fdmap() {
  local pid=$1 fd n target inode size
  printf 'pid=%s\n' "${pid}"
  for fd in /proc/"${pid}"/fd/*; do
    [ -e "${fd}" ] || continue
    n=${fd##*/}
    target=$(readlink "${fd}" 2>/dev/null) || target=unknown
    inode=$(stat -L -c '%i' "${fd}" 2>/dev/null) || inode=0
    size=$(stat -L -c '%s' "${fd}" 2>/dev/null) || size=0
    printf 'fd=%s target=%s inode=%s size=%s\n' "${n}" "${target}" "${inode}" "${size}"
  done
}

# dmabuf_lines <map> — the dma-buf rows only.
dmabuf_lines() {
  awk -v re="${DMABUF_TARGET_RE}" '
    /^fd=/ {
      target = ""; inode = ""; size = ""
      for (i = 1; i <= NF; i++) {
        split($i, kv, "=")
        if (kv[1] == "target") target = substr($i, 8)
        else if (kv[1] == "inode") inode = kv[2]
        else if (kv[1] == "size") size = kv[2]
        else if (kv[1] == "fd") fd = kv[2]
      }
      if (target ~ re) printf "%s %s %s\n", fd, inode, size
    }
  ' "$1"
}

summarize_map() {
  local map=$1 label=$2 total distinct bytes
  total=$(dmabuf_lines "${map}" | wc -l)
  distinct=$(dmabuf_lines "${map}" | awk '{print $2}' | sort -u | wc -l)
  bytes=$(dmabuf_lines "${map}" | awk '{s += $3} END {printf "%d", s + 0}')
  printf 'map=%s dmabuf_fds=%s distinct_inodes=%s total_bytes=%s\n' \
    "${label}" "${total}" "${distinct}" "${bytes}"
  # More fds than inodes means at least one dma-buf is referenced twice in the
  # same process: an in-process import, i.e. a boundary that did NOT copy.
  if [ "${total}" -gt "${distinct}" ]; then
    printf 'map=%s shared_inodes=%s (a dma-buf is referenced by more than one fd)\n' \
      "${label}" "$((total - distinct))"
  fi
}

# diff_maps <a> <b> — buffer churn. `new_inodes` is the allocation count in the
# window and is the direct copy signal.
diff_maps() {
  local a=$1 b=$2 new retired
  new=$(comm -13 \
    <(dmabuf_lines "${a}" | awk '{print $2}' | sort -u) \
    <(dmabuf_lines "${b}" | awk '{print $2}' | sort -u) | wc -l)
  retired=$(comm -23 \
    <(dmabuf_lines "${a}" | awk '{print $2}' | sort -u) \
    <(dmabuf_lines "${b}" | awk '{print $2}' | sort -u) | wc -l)
  printf 'churn new_inodes=%s retired_inodes=%s\n' "${new}" "${retired}"
  if [ "${new}" -eq 0 ]; then
    printf 'churn_reading=POOL-STABLE no dma-buf was allocated in this window\n'
  else
    printf 'churn_reading=ALLOCATING %s new dma-buf(s) in this window\n' "${new}"
  fi
}

# ---------------------------------------------------------------------------
# GST_MEMORY:7 attribution
# ---------------------------------------------------------------------------
#
# Each line carries an element (or element:pad) inside angle brackets and, when
# the operation concerns a dma-buf, an "fd <n>" or "fd:<n>" token. Pairing them
# tells us which elements touched which descriptor.
gst_log_pairs() {
  awk '
    {
      el = ""; fd = ""
      if (match($0, /<[^<>]+>/)) {
        el = substr($0, RSTART + 1, RLENGTH - 2)
        sub(/:.*$/, "", el)
      }
      if (match($0, /fd[ :=]+[0-9]+/)) {
        t = substr($0, RSTART, RLENGTH)
        gsub(/[^0-9]/, "", t)
        fd = t
      }
      # An allocator naming the fd it just created is not a boundary crossing;
      # counting it would make every freshly allocated copy destination look
      # "shared" and destroy the signal this whole measurement rests on.
      if (el ~ /allocator/) next
      if (el != "" && fd != "") print fd, el
    }
  ' "$1" | sort -u
}

attribute_gst_log() {
  local log=$1 pairs
  pairs="$(gst_log_pairs "${log}")"
  printf '%s\n' "${pairs}" | awk '
    { elements[$1] = elements[$1] (elements[$1] == "" ? "" : ",") $2; n[$1]++ }
    END {
      for (fd in elements)
        printf "fd=%s elements=%s crossed=%s\n", fd, elements[fd],
               (n[fd] > 1 ? "yes" : "no")
    }
  ' | sort -t= -k2 -n

  local copies
  copies=$(grep -cE 'gst_video_frame_copy|import refused' "${log}" || true)
  printf 'software_copy_lines=%s\n' "${copies}"
  local crossed
  crossed=$(printf '%s\n' "${pairs}" | awk '{n[$1]++} END {c=0; for (f in n) if (n[f] > 1) c++; print c}')
  printf 'fds_crossing_an_element_boundary=%s\n' "${crossed}"
  if [ "${copies}" -gt 0 ]; then
    printf 'attribution_reading=COPY-PRESENT the log names %s software-copy event(s)\n' "${copies}"
  else
    printf 'attribution_reading=IMPORT-ONLY the log names no software copy\n'
  fi
}

# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------
#
# Scores both directions against committed fixtures, because a tracer that
# reported "zero copies" for everything would look green forever:
#
#   zero-copy log  -> no software-copy line, one fd crossing two elements
#   copy log       -> three software-copy events, no fd shared across elements
#   fd map t0->t1  -> two new dma-buf inodes appear (the copies' destinations)
self_test() {
  local fixtures rc=0 got

  fixtures="$(harness_fixtures_dir)" || {
    harness_fail_msg "fixture tree not found"
    return "${HARNESS_FAIL}"
  }
  local zc="${fixtures}/gst-memory/zero-copy.gstmemory.log"
  local cp="${fixtures}/gst-memory/copy.gstmemory.log"
  local m0="${fixtures}/gst-memory/fdmap-t0.txt"
  local m1="${fixtures}/gst-memory/fdmap-t1.txt"
  local f
  for f in "${zc}" "${cp}" "${m0}" "${m1}"; do
    [ -r "${f}" ] || {
      harness_fail_msg "fixture missing: ${f}"
      return "${HARNESS_FAIL}"
    }
  done

  printf 'self_test=fd-trace\n'

  printf -- '--- zero-copy log ---\n'
  local zc_out
  zc_out="$(attribute_gst_log "${zc}")"
  printf '%s\n' "${zc_out}"
  got=$(printf '%s\n' "${zc_out}" | sed -n 's/^software_copy_lines=//p')
  [ "${got}" = "0" ] || {
    harness_fail_msg "zero-copy fixture reported ${got} software-copy lines, expected 0"
    rc=1
  }
  got=$(printf '%s\n' "${zc_out}" | sed -n 's/^fds_crossing_an_element_boundary=//p')
  [ "${got}" = "2" ] || {
    harness_fail_msg "zero-copy fixture reported ${got} crossing fds, expected 2"
    rc=1
  }

  printf -- '--- copy log ---\n'
  local cp_out
  cp_out="$(attribute_gst_log "${cp}")"
  printf '%s\n' "${cp_out}"
  got=$(printf '%s\n' "${cp_out}" | sed -n 's/^software_copy_lines=//p')
  [ "${got}" = "4" ] || {
    harness_fail_msg "copy fixture reported ${got} software-copy lines, expected 4"
    rc=1
  }
  got=$(printf '%s\n' "${cp_out}" | sed -n 's/^fds_crossing_an_element_boundary=//p')
  [ "${got}" = "0" ] || {
    harness_fail_msg "copy fixture reported ${got} crossing fds, expected 0"
    rc=1
  }
  if ! printf '%s\n' "${cp_out}" | grep -q 'attribution_reading=COPY-PRESENT'; then
    harness_fail_msg "the copy fixture did not read as COPY-PRESENT; the tracer is vacuous"
    rc=1
  fi

  printf -- '--- fd maps ---\n'
  summarize_map "${m0}" t0
  summarize_map "${m1}" t1
  local churn
  churn="$(diff_maps "${m0}" "${m1}")"
  printf '%s\n' "${churn}"
  got=$(printf '%s\n' "${churn}" | sed -n 's/^churn new_inodes=\([0-9]*\).*/\1/p')
  [ "${got}" = "2" ] || {
    harness_fail_msg "fd-map churn reported ${got} new inodes, expected 2"
    rc=1
  }
  if ! printf '%s\n' "${churn}" | grep -q 'churn_reading=ALLOCATING'; then
    harness_fail_msg "a window that allocated two dma-bufs did not read as ALLOCATING"
    rc=1
  fi
  churn="$(diff_maps "${m0}" "${m0}")"
  printf '%s\n' "${churn}"
  if ! printf '%s\n' "${churn}" | grep -q 'churn_reading=POOL-STABLE'; then
    harness_fail_msg "an unchanged window did not read as POOL-STABLE"
    rc=1
  fi

  # The map parser must not mistake a device node for a dma-buf.
  got=$(dmabuf_lines "${m0}" | wc -l)
  [ "${got}" = "4" ] || {
    harness_fail_msg "t0 dma-buf row count is ${got}, expected 4 (device nodes must not match)"
    rc=1
  }
  printf 'assert device nodes and pipes are excluded from the dma-buf set ok\n'

  [ "${rc}" -eq 0 ] || {
    harness_verdict FAIL "self-test"
    return $?
  }
  harness_verdict PASS "self-test: both directions scored as expected"
}

usage() {
  sed -n '2,53p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

trace_pid() {
  local pid=$1 out=$2 i map prev
  [ -d "/proc/${pid}" ] || {
    harness_fail_msg "no such process: ${pid}"
    return 1
  }
  printf 'pid=%s samples=%s interval_s=%s\n' "${pid}" "${SAMPLES}" "${INTERVAL}"
  prev=
  for ((i = 0; i < SAMPLES; i++)); do
    map="$(printf '%s/fdmap-%04d.txt' "${out}" "${i}")"
    capture_fdmap "${pid}" >"${map}" || return 1
    summarize_map "${map}" "t${i}"
    [ -z "${prev}" ] || diff_maps "${prev}" "${map}"
    prev="${map}"
    [ "$((i + 1))" -lt "${SAMPLES}" ] && sleep "${INTERVAL}"
  done
  printf -- '--- window total ---\n'
  diff_maps "${out}/fdmap-0000.txt" "${prev}"
}

run_launch() {
  local pipeline=$1 out=$2 pid rc
  require_tools gst-launch-1.0 || return 1
  printf 'launch=%s seconds=%s\n' "${pipeline}" "${SECONDS_TO_RUN}"
  # Unquoted on purpose: the caller passes a whole pipeline description as one
  # string and it MUST word-split into argv. Quoting it hands gst-launch a
  # single argument and the pipeline never builds.
  # shellcheck disable=SC2086
  GST_DEBUG="${GST_DEBUG_SPEC}" gst-launch-1.0 -e ${pipeline} \
    >"${out}/launch.gstmemory.log" 2>&1 &
  pid=$!
  sleep 1
  if kill -0 "${pid}" 2>/dev/null; then
    SAMPLES=2 INTERVAL="${SECONDS_TO_RUN}" trace_pid "${pid}" "${out}"
    rc=$?
  else
    harness_fail_msg "the pipeline exited before it could be traced"
    rc=1
  fi
  kill -INT "${pid}" 2>/dev/null
  wait "${pid}" 2>/dev/null
  printf -- '--- attribution from GST_MEMORY:7 ---\n'
  attribute_gst_log "${out}/launch.gstmemory.log"
  return "${rc}"
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --self-test)
        self_test
        exit $?
        ;;
      --pid)
        PID=${2:-}
        shift 2
        ;;
      --samples)
        SAMPLES=${2:-}
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
      --snapshot)
        SNAPSHOT=${2:-}
        shift 2
        ;;
      --diff)
        DIFF_A=${2:-}
        DIFF_B=${3:-}
        shift 3
        ;;
      --gst-log)
        GST_LOG=${2:-}
        shift 2
        ;;
      --launch)
        LAUNCH=${2:-}
        shift 2
        ;;
      --seconds)
        SECONDS_TO_RUN=${2:-}
        shift 2
        ;;
      --gst-debug)
        GST_DEBUG_SPEC=${2:-}
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

  require_tools awk sort comm || exit "${HARNESS_USAGE}"

  if [ -n "${SNAPSHOT}" ]; then
    [ -r "${SNAPSHOT}" ] || {
      harness_fail_msg "--snapshot not readable: ${SNAPSHOT}"
      exit "${HARNESS_USAGE}"
    }
    summarize_map "${SNAPSHOT}" "$(basename "${SNAPSHOT}")"
    harness_verdict PASS "snapshot scored"
    exit $?
  fi

  if [ -n "${DIFF_A}" ]; then
    if ! [ -r "${DIFF_A}" ] || ! [ -r "${DIFF_B}" ]; then
      harness_fail_msg "--diff needs two readable fd maps"
      exit "${HARNESS_USAGE}"
    fi
    summarize_map "${DIFF_A}" a
    summarize_map "${DIFF_B}" b
    diff_maps "${DIFF_A}" "${DIFF_B}"
    harness_verdict PASS "churn scored"
    exit $?
  fi

  if [ -n "${GST_LOG}" ]; then
    [ -r "${GST_LOG}" ] || {
      harness_fail_msg "--gst-log not readable: ${GST_LOG}"
      exit "${HARNESS_USAGE}"
    }
    attribute_gst_log "${GST_LOG}"
    harness_verdict PASS "attribution scored"
    exit $?
  fi

  [ -n "${OUT_DIR}" ] || OUT_DIR="$(harness_out_dir fd-trace)" || exit "${HARNESS_FAIL}"
  mkdir -p "${OUT_DIR}" || exit "${HARNESS_FAIL}"
  printf 'report_dir=%s\n' "${OUT_DIR}"

  if [ -n "${LAUNCH}" ]; then
    run_launch "${LAUNCH}" "${OUT_DIR}" || {
      harness_verdict FAIL "launch trace failed"
      exit $?
    }
    harness_verdict PASS "launch traced"
    exit $?
  fi

  if [ -n "${PID}" ]; then
    trace_pid "${PID}" "${OUT_DIR}" || {
      harness_verdict FAIL "pid trace failed"
      exit $?
    }
    harness_verdict PASS "pid traced"
    exit $?
  fi

  harness_fail_msg "one of --pid, --launch, --snapshot, --diff, --gst-log or --self-test is required"
  usage
  exit "${HARNESS_USAGE}"
}

main "$@"
