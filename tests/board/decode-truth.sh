#!/usr/bin/env bash
#
# decode-truth.sh — which decoder actually carries frames, per ingest kind.
#
# THE QUESTION IT ANSWERS (todo 3(a), A1). The engine's RK3588 graph templates
# name a decoder per source kind: `mppvideodec` for UVC-H.264/H.265 and for
# RTMP, `mppjpegdec` for USB-MJPEG, and `decodebin` for SRT. Whether those
# elements DECODE is a different question from whether they REGISTER, and only
# the first one matters to an operator. `gst-inspect-1.0 mppvideodec` exiting 0
# proves the plugin loaded; it proves nothing about the kernel having an MPP
# decoder client behind it.
#
# So this probe does not ask GStreamer what exists. It runs the ingest, counts
# the buffers that reached a sink, and names the factory that carried them.
#
# THE TWO CHAINS PER SOURCE KIND, AND WHY BOTH ARE NEEDED.
#
#   ENGINE CHAIN    the exact decoder element the engine's template hardcodes.
#                   If it cannot negotiate, the engine cannot serve that source
#                   kind at all — no autoplugger rescues a hardcoded element.
#   AUTOPLUG CHAIN  the same transport through `decodebin`. This names the
#                   factory that DOES carry frames on this kernel, which is the
#                   decoder truth the plan's A1 row is asking for, and it is
#                   also what the engine's SRT template really uses.
#
# Reporting only the first would say "nothing decodes", which is false.
# Reporting only the second would hide that the engine's own RTMP and UVC
# templates name an element that cannot run. The pair is the finding.
#
# THE VERDICT RULE IS THE PLAN'S, VERBATIM: a source kind reads SOFTWARE iff
# the factory that carried its frames is `avdec_*` or `jpegdec`. Anything else
# that carried frames is HARDWARE — including the mainline V4L2 stateless
# decoders, which are hardware even though they are not MPP. A kind that
# carried no frames at all is NONE, never SOFTWARE and never a pass.
#
# NO-DEVICE IS A RESULT, NOT A GAP. UVC-H.264 (an Osmo) and UVC-MJPEG (a RØDE)
# need hardware plugged into the board. When no UVC node is enumerated, the row
# says NO-DEVICE and carries the enumeration that proves it. That is an honest
# terminal state; a blank cell is not.
#
# CPU IS SAMPLED FROM /proc, BECAUSE pidstat IS NOT INSTALLED. The plan names
# `pidstat -t -p $(pidof cerastream) 1 10`; `sysstat` is absent from the shipped
# image and this harness may not install packages. utime+stime deltas out of
# /proc/<pid>/stat over a measured window are the same quantity pidstat prints,
# read from the same place, so the substitution costs nothing but has to be
# stated — it is recorded in every row as `cpu_source=proc-stat`.
#
# READ-ONLY. It runs pipelines and local publishers of its own, inside its own
# work directory. It controls no unit, loads no module, writes nothing under
# /sys, and never touches the running engine or the board's own ingest ports.
#
# Usage:
#   decode-truth.sh [--all] [--work DIR] [--seconds N]
#   decode-truth.sh --survey                 source-kind inventory only
#   decode-truth.sh --kind KIND              one of: uvc-h264 uvc-mjpeg rtmp srt
#                                            local-h264 local-h265 local-mjpeg
#   decode-truth.sh --self-test
#
# Output: one `decode_row=` line per source kind, plus free-form evidence.
#   decode_row=kind=<k> status=<S> engine_element=<e> engine_result=<R>
#              selected_factory=<f> decoder_class=<C> frames=<n>
#              cpu_pct=<x> cpu_source=proc-stat evidence=<path>
#
# Exit: 0 every requested kind produced a row, 1 a kind produced none,
#       2 usage, 77 the required tooling is absent (nothing was measured).

set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness-lib.sh
. "${HARNESS_DIR}/lib/harness-lib.sh"

# Ports are deliberately NOT the device's own (1935 RTMP, 4000/4001 SRT/UDP).
# Publishing into the board's real ingest would change what the running engine
# is doing, which this harness is not allowed to do.
readonly PROBE_RTMP_PORT="${PROBE_RTMP_PORT:-11935}"
readonly PROBE_SRT_PORT="${PROBE_SRT_PORT:-14001}"

# A decoder factory, by name. The set is closed on purpose: an autoplugged
# graph creates queues, capsfilters and typefinds too, and only these names are
# candidates for "the element that carried the frames".
readonly DECODER_NAME_RE='^(mppvideodec|mppjpegdec|v4l2sl[a-z0-9]+dec|v4l2[a-z0-9]*dec|avdec_[a-z0-9_]+|jpegdec|openh264dec|libde265dec)$'

# The plan's rule, in one place: SOFTWARE iff avdec_* or jpegdec.
readonly SOFTWARE_FACTORY_RE='^(avdec_[a-z0-9_]+|jpegdec)$'

WORK=
SECONDS_PER_LEG=12
declare -a KINDS=()
SURVEY_ONLY=0

# ---------------------------------------------------------------------------
# Log scoring — pure, fixture-testable, no board required
# ---------------------------------------------------------------------------

# count_frames <log> — buffers that reached the probe point. `identity
# silent=false` under `gst-launch -v` prints one `last-message = chain` line per
# buffer, which is a count of frames that actually crossed the sink boundary
# rather than a claim about the pipeline reaching PLAYING.
count_frames() {
  grep -c 'last-message = chain' "$1" 2>/dev/null || true
}

# created_factories <log> — every element GStreamer instantiated, in order.
created_factories() {
  sed -n 's/.*creating element "\([^"]*\)".*/\1/p' "$1" 2>/dev/null
}

# selected_factory <log> — the decoder that carried the frames.
#
# WHY THE LAST ONE. `decodebin` tries candidates in rank order and instantiates
# the next only after the previous one failed to link or negotiate. The last
# decoder-class element it created is therefore the one left in the running
# graph. Paired with a non-zero frame count (which the caller always checks),
# that is decisive; on its own it would only be a guess, which is why no row is
# emitted with a factory but no frame count.
selected_factory() {
  created_factories "$1" | grep -E "${DECODER_NAME_RE}" | tail -1
}

# attempted_factories <log> — every decoder the graph tried, comma-joined. The
# ones before the last are the failures, and naming them is the evidence that
# the engine's hardcoded element was attempted and did not survive.
attempted_factories() {
  created_factories "$1" | grep -E "${DECODER_NAME_RE}" | paste -sd, - 2>/dev/null
}

# classify_factory <factory> — the plan's verdict rule and nothing else.
classify_factory() {
  local f=${1-}
  [ -n "${f}" ] || {
    printf 'NONE\n'
    return
  }
  if printf '%s' "${f}" | grep -Eq "${SOFTWARE_FACTORY_RE}"; then
    printf 'SOFTWARE\n'
  else
    printf 'HARDWARE\n'
  fi
}

# leg_result <log> <frames> — the terminal state of one pipeline run.
leg_result() {
  local log=$1 frames=$2
  if [ "${frames}" -gt 0 ]; then
    printf 'OK\n'
  elif grep -q 'not-negotiated' "${log}" 2>/dev/null; then
    printf 'NOT-NEGOTIATED\n'
  elif grep -q 'Resource not found' "${log}" 2>/dev/null; then
    printf 'NO-INPUT\n'
  elif grep -q '^ERROR' "${log}" 2>/dev/null; then
    printf 'ERROR\n'
  else
    printf 'NO-FRAMES\n'
  fi
}

# cpu_pct_from_stat <stat-t0> <stat-t1> <window-s> [clk-tck]
#
# /proc/<pid>/stat's comm field can contain spaces and parentheses, so the
# fields are counted from AFTER the final ')' — the only parse of that file
# that is correct for every process name. utime is field 12 and stime is 13 of
# that remainder.
cpu_pct_from_stat() {
  local t0=$1 t1=$2 window=$3 hz=${4:-}
  [ -n "${hz}" ] || hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
  local u0 s0 u1 s1
  # shellcheck disable=SC2046  # word splitting into positional args is the point
  set -- $(sed 's/^.*) //' "${t0}" 2>/dev/null)
  u0=${12:-}
  s0=${13:-}
  # shellcheck disable=SC2046
  set -- $(sed 's/^.*) //' "${t1}" 2>/dev/null)
  u1=${12:-}
  s1=${13:-}
  if [ -z "${u0}" ] || [ -z "${u1}" ]; then
    printf 'unavailable\n'
    return 1
  fi
  awk -v d="$((u1 - u0 + s1 - s0))" -v hz="${hz}" -v w="${window}" \
    'BEGIN { printf "%.1f\n", (w > 0 ? d / hz / w * 100 : 0) }'
}

# ---------------------------------------------------------------------------
# Board legs
# ---------------------------------------------------------------------------

# run_traced <log> <cpu-out-prefix> <seconds> <pipeline...>
#
# Backgrounds a pipeline WITHOUT a `timeout` wrapper, on purpose: `timeout`
# forks, so $! would name the wrapper and every CPU sample would read the
# wrapper's idle stat instead of the pipeline's. The watchdog is a separate
# subshell that interrupts the real pid.
run_traced() {
  local log=$1 cpu_prefix=$2 secs=$3
  shift 3
  local pid guard rc=0 half
  GST_DEBUG=GST_ELEMENT_FACTORY:4 gst-launch-1.0 -v -e "$@" >"${log}" 2>&1 &
  pid=$!
  (
    sleep "${secs}"
    kill -INT "${pid}" 2>/dev/null
    sleep 3
    kill -KILL "${pid}" 2>/dev/null
  ) &
  guard=$!

  half=$((secs / 3))
  [ "${half}" -ge 2 ] || half=2
  sleep 2
  if [ -r "/proc/${pid}/stat" ]; then
    cp "/proc/${pid}/stat" "${cpu_prefix}.stat0" 2>/dev/null
    sleep "${half}"
    [ -r "/proc/${pid}/stat" ] && cp "/proc/${pid}/stat" "${cpu_prefix}.stat1" 2>/dev/null
    printf '%s\n' "${half}" >"${cpu_prefix}.window"
  fi

  wait "${pid}" 2>/dev/null || rc=$?
  kill "${guard}" 2>/dev/null
  wait "${guard}" 2>/dev/null
  return "${rc}"
}

cpu_for_prefix() {
  local prefix=$1 window
  if [ -r "${prefix}.stat0" ] && [ -r "${prefix}.stat1" ] && [ -r "${prefix}.window" ]; then
    window=$(cat "${prefix}.window")
    cpu_pct_from_stat "${prefix}.stat0" "${prefix}.stat1" "${window}" || printf 'unavailable\n'
  else
    printf 'unavailable\n'
  fi
}

emit_row() {
  printf 'decode_row=kind=%s status=%s engine_element=%s engine_result=%s attempted=%s selected_factory=%s decoder_class=%s frames=%s cpu_pct=%s cpu_source=proc-stat evidence=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}"
}

# make_fixture_clips — build the local decode inputs once, in the work dir.
# `-nostdin` is NOT optional: this script is frequently invoked through
# `ssh … bash -s`, where the shell script itself is on stdin, and an ffmpeg
# that reads stdin swallows the rest of the script. That failure mode is silent
# and looks like a syntax error several lines later.
make_fixture_clips() {
  local work=$1 w=1920 h=1080
  printf 'fixture_clip_resolution=%sx%s\n' "${w}" "${h}"

  ffmpeg -nostdin -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=${w}x${h}:rate=30:duration=6" \
    -c:v libx264 -preset ultrafast -g 30 -pix_fmt yuv420p \
    -f h264 "${work}/clip.h264" </dev/null >"${work}/mk-h264.log" 2>&1
  printf 'fixture_h264=%s\n' "$([ -s "${work}/clip.h264" ] && echo ok || echo failed)"

  ffmpeg -nostdin -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=${w}x${h}:rate=30:duration=6" \
    -c:v mjpeg -q:v 3 -pix_fmt yuvj420p \
    -f mjpeg "${work}/clip.mjpg" </dev/null >"${work}/mk-mjpeg.log" 2>&1
  printf 'fixture_mjpeg=%s\n' "$([ -s "${work}/clip.mjpg" ] && echo ok || echo failed)"

  # H.265: software first so the decode input does not depend on the very
  # hardware block under test. If libx265 is unusable, fall back to the MPP
  # encoder and SAY SO — the fixture's provenance is part of the evidence.
  ffmpeg -nostdin -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=${w}x${h}:rate=30:duration=6" \
    -c:v libx265 -preset ultrafast -pix_fmt yuv420p \
    -f hevc "${work}/clip.h265" </dev/null >"${work}/mk-h265.log" 2>&1
  if [ -s "${work}/clip.h265" ]; then
    printf 'fixture_h265=ok encoder=libx265\n'
  else
    gst-launch-1.0 -e videotestsrc num-buffers=180 \
      ! "video/x-raw,format=NV12,width=${w},height=${h},framerate=30/1" \
      ! mpph265enc ! h265parse ! filesink location="${work}/clip.h265" \
      >"${work}/mk-h265-mpp.log" 2>&1
    printf 'fixture_h265=%s encoder=mpph265enc\n' \
      "$([ -s "${work}/clip.h265" ] && echo ok || echo failed)"
  fi
}

# --- source-kind survey ----------------------------------------------------

survey() {
  local uvc_nodes=0 node driver card

  printf -- '--- v4l2 node inventory ---\n'
  for node in /dev/video[0-9]*; do
    [ -e "${node}" ] || continue
    driver=$(v4l2-ctl -d "${node}" --info 2>/dev/null | sed -n 's/.*Driver name *: *//p' | head -1)
    card=$(v4l2-ctl -d "${node}" --info 2>/dev/null | sed -n 's/.*Card type *: *//p' | head -1)
    printf 'node=%s driver=%s card=%s\n' "${node}" "${driver:-unknown}" "${card:-unknown}"
    case "${driver}" in uvcvideo) uvc_nodes=$((uvc_nodes + 1)) ;; esac
  done
  printf 'uvc_nodes=%s\n' "${uvc_nodes}"

  printf -- '--- engine-named source elements ---\n'
  local f
  for f in libuvch264src v4l2src rtmpsrc udpsrc srtsrc mppvideodec mppjpegdec decodebin; do
    if gst-inspect-1.0 "${f}" >/dev/null 2>&1; then
      printf 'element=%s registered=yes rc=0\n' "${f}"
    else
      printf 'element=%s registered=no rc=%s\n' "${f}" "$?"
    fi
  done
  printf 'uvc_device_count=%s\n' "${uvc_nodes}"
  return 0
}

# uvc_row <kind> <engine element> — the NO-DEVICE terminal state.
uvc_row() {
  local kind=$1 element=$2 evidence=$3 uvc_nodes=$4
  if [ "${uvc_nodes}" -gt 0 ]; then
    printf 'uvc_present=%s but this probe does not auto-select a camera; run --kind %s with the device attached\n' \
      "${uvc_nodes}" "${kind}"
    emit_row "${kind}" PRESENT-NOT-PROBED "${element}" NOT-RUN '' '' NONE 0 unavailable "${evidence}"
    return 0
  fi
  emit_row "${kind}" NO-DEVICE "${element}" NOT-RUN '' '' NONE 0 unavailable "${evidence}"
}

# --- one ingest leg --------------------------------------------------------

# leg_local <kind> <clip> <parser> <engine element> <work>
leg_local() {
  local kind=$1 clip=$2 parser=$3 engine_el=$4 work=$5
  local eng_log="${work}/${kind}-engine.log" auto_log="${work}/${kind}-autoplug.log"
  local eng_frames auto_frames eng_result factory class cpu

  if [ ! -s "${clip}" ]; then
    emit_row "${kind}" NO-FIXTURE "${engine_el}" NOT-RUN '' '' NONE 0 unavailable "${work}"
    return 1
  fi

  run_traced "${eng_log}" "${work}/${kind}-engine" "${SECONDS_PER_LEG}" \
    filesrc location="${clip}" ! "${parser}" ! "${engine_el}" \
    ! identity name=p silent=false ! fakesink sync=false
  eng_frames=$(count_frames "${eng_log}")
  eng_result=$(leg_result "${eng_log}" "${eng_frames}")

  run_traced "${auto_log}" "${work}/${kind}-autoplug" "${SECONDS_PER_LEG}" \
    filesrc location="${clip}" ! "${parser}" ! decodebin \
    ! identity name=p silent=false ! fakesink sync=true
  auto_frames=$(count_frames "${auto_log}")
  factory=$(selected_factory "${auto_log}")
  [ "${auto_frames}" -gt 0 ] || factory=
  class=$(classify_factory "${factory}")
  cpu=$(cpu_for_prefix "${work}/${kind}-autoplug")

  emit_row "${kind}" MEASURED "${engine_el}" "${eng_result}" \
    "$(attempted_factories "${auto_log}")" "${factory:-none}" "${class}" \
    "${auto_frames}" "${cpu}" "${auto_log}"
}

# leg_rtmp — a real local RTMP publisher. ffmpeg serves the stream with
# `-listen 1` and the pipeline plays it, which exercises rtmpsrc/flvdemux
# exactly as the engine's rk_rtmp template does, on a port the device does not
# use.
leg_rtmp() {
  local work=$1
  local clip="${work}/clip.h264"
  local eng_log="${work}/rtmp-engine.log" auto_log="${work}/rtmp-autoplug.log"
  local url="rtmp://127.0.0.1:${PROBE_RTMP_PORT}/publish/live"
  local ff eng_frames auto_frames eng_result factory class cpu

  ffmpeg -nostdin -hide_banner -loglevel warning -re \
    -f lavfi -i "testsrc2=size=1920x1080:rate=30" \
    -c:v libx264 -preset ultrafast -tune zerolatency -g 30 -pix_fmt yuv420p \
    -t $((SECONDS_PER_LEG + 8)) -f flv -listen 1 "${url}" \
    </dev/null >"${work}/rtmp-publisher-engine.log" 2>&1 &
  ff=$!
  sleep 3
  run_traced "${eng_log}" "${work}/rtmp-engine" "${SECONDS_PER_LEG}" \
    rtmpsrc location="${url}" ! flvdemux name=d d.video ! queue ! h264parse \
    ! mppvideodec ! identity name=p silent=false ! fakesink sync=false
  kill "${ff}" 2>/dev/null
  wait "${ff}" 2>/dev/null
  eng_frames=$(count_frames "${eng_log}")
  eng_result=$(leg_result "${eng_log}" "${eng_frames}")

  ffmpeg -nostdin -hide_banner -loglevel warning -re \
    -f lavfi -i "testsrc2=size=1920x1080:rate=30" \
    -c:v libx264 -preset ultrafast -tune zerolatency -g 30 -pix_fmt yuv420p \
    -t $((SECONDS_PER_LEG + 8)) -f flv -listen 1 "${url}" \
    </dev/null >"${work}/rtmp-publisher-autoplug.log" 2>&1 &
  ff=$!
  sleep 3
  run_traced "${auto_log}" "${work}/rtmp-autoplug" "${SECONDS_PER_LEG}" \
    rtmpsrc location="${url}" ! flvdemux name=d d.video ! queue ! h264parse \
    ! decodebin ! identity name=p silent=false ! fakesink sync=true
  kill "${ff}" 2>/dev/null
  wait "${ff}" 2>/dev/null
  auto_frames=$(count_frames "${auto_log}")
  factory=$(selected_factory "${auto_log}")
  [ "${auto_frames}" -gt 0 ] || factory=
  class=$(classify_factory "${factory}")
  cpu=$(cpu_for_prefix "${work}/rtmp-autoplug")

  printf 'rtmp_publisher=ffmpeg -listen 1 %s (local, port %s)\n' "${url}" "${PROBE_RTMP_PORT}"
  emit_row rtmp MEASURED mppvideodec "${eng_result}" \
    "$(attempted_factories "${auto_log}")" "${factory:-none}" "${class}" \
    "${auto_frames}" "${cpu}" "${auto_log}"
  # A clip is not needed for this leg, but a missing one upstream would be a
  # silent gap in the local legs, so it is asserted here too.
  [ -s "${clip}" ] || printf 'note=local h264 fixture missing; the RTMP leg does not use it\n'
}

# leg_srt — a real local SRT publisher. The engine's rk_srt template runs
# `udpsrc ! decodebin`, so the autoplug half is the engine's literal decode
# path; the transport here is genuine SRT rather than the plain UDP the device
# is fed by its own receiver, which is the stronger test of the two.
leg_srt() {
  local work=$1
  local auto_log="${work}/srt-autoplug.log" eng_log="${work}/srt-engine.log"
  local listen="srt://0.0.0.0:${PROBE_SRT_PORT}?mode=listener"
  local caller="srt://127.0.0.1:${PROBE_SRT_PORT}?mode=caller"
  local ff auto_frames eng_frames eng_result factory class cpu

  run_traced "${eng_log}" "${work}/srt-engine" "$((SECONDS_PER_LEG + 6))" \
    srtsrc uri="${listen}" ! tsdemux ! h264parse ! mppvideodec \
    ! identity name=p silent=false ! fakesink sync=false &
  local eng_pid=$!
  sleep 3
  ffmpeg -nostdin -hide_banner -loglevel warning -re \
    -f lavfi -i "testsrc2=size=1920x1080:rate=30" \
    -c:v libx264 -preset ultrafast -tune zerolatency -g 30 -pix_fmt yuv420p \
    -t "${SECONDS_PER_LEG}" -f mpegts "${caller}" \
    </dev/null >"${work}/srt-publisher-engine.log" 2>&1
  wait "${eng_pid}" 2>/dev/null
  eng_frames=$(count_frames "${eng_log}")
  eng_result=$(leg_result "${eng_log}" "${eng_frames}")

  run_traced "${auto_log}" "${work}/srt-autoplug" "$((SECONDS_PER_LEG + 6))" \
    srtsrc uri="${listen}" ! tsdemux ! h264parse ! decodebin \
    ! identity name=p silent=false ! fakesink sync=true &
  local auto_pid=$!
  sleep 3
  ffmpeg -nostdin -hide_banner -loglevel warning -re \
    -f lavfi -i "testsrc2=size=1920x1080:rate=30" \
    -c:v libx264 -preset ultrafast -tune zerolatency -g 30 -pix_fmt yuv420p \
    -t "${SECONDS_PER_LEG}" -f mpegts "${caller}" \
    </dev/null >"${work}/srt-publisher-autoplug.log" 2>&1
  ff=$?
  wait "${auto_pid}" 2>/dev/null
  auto_frames=$(count_frames "${auto_log}")
  factory=$(selected_factory "${auto_log}")
  [ "${auto_frames}" -gt 0 ] || factory=
  class=$(classify_factory "${factory}")
  cpu=$(cpu_for_prefix "${work}/srt-autoplug")

  printf 'srt_publisher=ffmpeg -f mpegts %s (local, port %s, publisher_rc=%s)\n' \
    "${caller}" "${PROBE_SRT_PORT}" "${ff}"
  # The engine's rk_srt template autoplugs, so `decodebin` IS its element and
  # the autoplug result is its result. The explicit mppvideodec run beside it
  # answers a different question -- whether the MPP decoder could have served
  # this transport at all -- and is reported as its own line rather than folded
  # into the row, because conflating them would misname the engine's chain.
  printf 'srt_explicit_mppvideodec_result=%s frames=%s\n' "${eng_result}" "${eng_frames}"
  emit_row srt MEASURED decodebin \
    "$(leg_result "${auto_log}" "${auto_frames}")" \
    "$(attempted_factories "${auto_log}")" "${factory:-none}" \
    "${class}" "${auto_frames}" "${cpu}" "${auto_log}"
}

# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------
#
# Scores committed fixtures in BOTH directions, because a probe that answered
# "hardware" for everything would look green forever:
#
#   autoplug-hardware.log  mppvideodec attempted, v4l2slh264dec carried 120
#                          frames -> selected=v4l2slh264dec, class=HARDWARE
#   autoplug-software.log  mppvideodec attempted, avdec_h265 carried 120
#                          frames -> selected=avdec_h265, class=SOFTWARE
#   autoplug-mjpeg.log     mppjpegdec attempted, jpegdec carried the frames
#                          -> class=SOFTWARE (the rule's second limb)
#   engine-failed.log      the hardcoded element negotiated nothing
#                          -> frames=0, result=NOT-NEGOTIATED, class=NONE
#   proc-stat-t0/t1        a known utime/stime delta -> an exact CPU percentage
self_test() {
  local fixtures rc=0 got dir

  fixtures="$(harness_fixtures_dir)" || {
    harness_fail_msg "fixture tree not found"
    return "${HARNESS_FAIL}"
  }
  dir="${fixtures}/decode"
  local f
  for f in autoplug-hardware.log autoplug-software.log autoplug-mjpeg.log \
    engine-failed.log proc-stat-t0.txt proc-stat-t1.txt; do
    [ -r "${dir}/${f}" ] || {
      harness_fail_msg "fixture missing: ${dir}/${f}"
      return "${HARNESS_FAIL}"
    }
  done

  printf 'self_test=decode-truth\n'

  expect() {
    local what=$1 want=$2 have=$3
    if [ "${want}" = "${have}" ]; then
      printf 'assert %s=%s ok\n' "${what}" "${have}"
    else
      harness_fail_msg "${what}=${have}, expected ${want}"
      rc=1
    fi
  }

  # --- hardware direction --------------------------------------------------
  got=$(count_frames "${dir}/autoplug-hardware.log")
  expect hardware.frames 120 "${got}"
  got=$(selected_factory "${dir}/autoplug-hardware.log")
  expect hardware.selected v4l2slh264dec "${got}"
  expect hardware.class HARDWARE "$(classify_factory "${got}")"
  expect hardware.attempted "mppvideodec,v4l2slh264dec" \
    "$(attempted_factories "${dir}/autoplug-hardware.log")"
  expect hardware.result OK \
    "$(leg_result "${dir}/autoplug-hardware.log" 120)"

  # --- software direction --------------------------------------------------
  got=$(selected_factory "${dir}/autoplug-software.log")
  expect software.selected avdec_h265 "${got}"
  expect software.class SOFTWARE "$(classify_factory "${got}")"
  got=$(selected_factory "${dir}/autoplug-mjpeg.log")
  expect mjpeg.selected jpegdec "${got}"
  expect mjpeg.class SOFTWARE "$(classify_factory "${got}")"

  # --- the failing engine chain -------------------------------------------
  got=$(count_frames "${dir}/engine-failed.log")
  expect engine.frames 0 "${got}"
  expect engine.result NOT-NEGOTIATED \
    "$(leg_result "${dir}/engine-failed.log" 0)"
  expect engine.class NONE "$(classify_factory "")"

  # --- the CPU sampler -----------------------------------------------------
  # The fixtures encode utime 100 -> 400 and stime 50 -> 200, i.e. 450 ticks
  # over a 3 s window at 100 Hz = 150.0 %. A process name containing a space
  # and a ')' is used deliberately: the naive `awk '{print $14}'` parse gets
  # this wrong, and a wrong CPU number is worse than none.
  got=$(cpu_pct_from_stat "${dir}/proc-stat-t0.txt" "${dir}/proc-stat-t1.txt" 3 100)
  expect cpu.pct 150.0 "${got}"

  # Non-vacuity: an unreadable pair must report `unavailable`, never 0.0.
  got=$(cpu_pct_from_stat /nonexistent-t0 /nonexistent-t1 3 100 || true)
  expect cpu.missing unavailable "${got}"

  # The row composer must never emit a passing class for an unmeasured kind.
  got=$(uvc_row uvc-h264 mppvideodec /tmp/none 0 | sed -n 's/.*decoder_class=\([A-Z]*\).*/\1/p')
  expect uvc.class NONE "${got}"
  got=$(uvc_row uvc-h264 mppvideodec /tmp/none 0 | sed -n 's/.*status=\([A-Z-]*\).*/\1/p')
  expect uvc.status NO-DEVICE "${got}"

  [ "${rc}" -eq 0 ] || {
    harness_verdict FAIL "self-test"
    return $?
  }
  harness_verdict PASS "self-test: hardware, software and failed-chain fixtures all scored"
}

usage() {
  sed -n '2,66p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --self-test)
        self_test
        exit $?
        ;;
      --survey)
        SURVEY_ONLY=1
        shift
        ;;
      --all)
        KINDS=(uvc-h264 uvc-mjpeg rtmp srt local-h264 local-h265 local-mjpeg)
        shift
        ;;
      --kind)
        KINDS+=("${2:-}")
        shift 2
        ;;
      --work)
        WORK=${2:-}
        shift 2
        ;;
      --seconds)
        SECONDS_PER_LEG=${2:-}
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

  require_tools gst-launch-1.0 gst-inspect-1.0 v4l2-ctl awk sed || {
    harness_verdict GATED "the decode-truth probe needs GStreamer and v4l2-ctl on this host"
    exit $?
  }

  local survey_out uvc_nodes
  survey_out="$(survey)"
  printf '%s\n' "${survey_out}"
  uvc_nodes=$(printf '%s\n' "${survey_out}" | sed -n 's/^uvc_device_count=//p' | tail -1)
  [ -n "${uvc_nodes}" ] || uvc_nodes=0

  if [ "${SURVEY_ONLY}" -eq 1 ]; then
    harness_verdict PASS "survey only"
    exit $?
  fi

  [ "${#KINDS[@]}" -gt 0 ] || KINDS=(uvc-h264 uvc-mjpeg rtmp srt local-h264 local-h265 local-mjpeg)

  [ -n "${WORK}" ] || WORK="$(harness_out_dir decode-truth)" || exit "${HARNESS_FAIL}"
  mkdir -p "${WORK}" || exit "${HARNESS_FAIL}"
  printf 'work_dir=%s seconds_per_leg=%s\n' "${WORK}" "${SECONDS_PER_LEG}"

  require_tools ffmpeg || {
    harness_verdict GATED "no ffmpeg on this host; the ingest legs cannot be published"
    exit $?
  }
  make_fixture_clips "${WORK}"

  local kind rc=0
  for kind in "${KINDS[@]}"; do
    printf -- '--- leg %s ---\n' "${kind}"
    case "${kind}" in
      uvc-h264) uvc_row uvc-h264 mppvideodec "${WORK}" "${uvc_nodes}" || rc=1 ;;
      uvc-mjpeg) uvc_row uvc-mjpeg mppjpegdec "${WORK}" "${uvc_nodes}" || rc=1 ;;
      rtmp) leg_rtmp "${WORK}" || rc=1 ;;
      srt) leg_srt "${WORK}" || rc=1 ;;
      local-h264) leg_local local-h264 "${WORK}/clip.h264" h264parse mppvideodec "${WORK}" || rc=1 ;;
      local-h265) leg_local local-h265 "${WORK}/clip.h265" h265parse mppvideodec "${WORK}" || rc=1 ;;
      local-mjpeg) leg_local local-mjpeg "${WORK}/clip.mjpg" jpegparse mppjpegdec "${WORK}" || rc=1 ;;
      *)
        harness_fail_msg "unknown kind: ${kind}"
        rc=1
        ;;
    esac
  done

  [ "${rc}" -eq 0 ] || {
    harness_verdict FAIL "at least one source kind produced no row"
    exit $?
  }
  harness_verdict PASS "one decode_row per requested source kind"
  exit $?
}

main "$@"
