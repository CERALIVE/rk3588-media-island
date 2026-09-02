#!/usr/bin/env bash
#
# encode-psnr-oracle.sh — decide CLEAN vs DIRTY for the RK3588 hardware encoder,
# from the PSNR distribution of repeated fixed-QP encodes of one fixed fixture.
#
# THE DEFECT THIS EXISTS TO MEASURE. yisding's forward-port carries an
# intermittent RKVENC2 encode-corruption finding (findings/2026-08-16-…): at a
# fixed QP the encoder occasionally emits a bitstream whose decode is visibly
# wrong, and the signature is BIMODAL — most runs land around 25 dB against the
# source with occasional ~44 dB islands, rather than a uniform slight
# degradation. CeraLive's own 0001 lineage is the same mpp_rkvenc2.c, so
# whether the SHIPPED image is already dirty is the denominator every later
# island comparison is read against. That is what this script answers.
#
# THE ALGORITHM (todo 3(e); the shape is fixed, not tunable):
#   1. assert the fixture's SHA-256 — an unverified fixture makes every number
#      below meaningless, so a mismatch is fatal before anything is encoded;
#   2. encode it N times (default 20) per codec at FIXED QP through the
#      hardware encoder: rc-mode=fixqp qp-init=26 qp-min=26 qp-max=26 gop=30;
#   3. decode each run and compute PER-FRAME PSNR against the same fixture;
#   4. verdict, from the PSNR DISTRIBUTION ONLY:
#        CLEAN  every run's mean >= 35 dB AND <= 2 frames < 35 dB in every run
#        DIRTY  any run's mean < 35 dB OR > 2 frames < 35 dB in any run
#
# WHY MD5 SPREAD IS RECORDED BUT NEVER DECIDES. A hardware encoder at fixed QP
# is not contractually byte-deterministic, so differing MD5s across runs are
# DIAGNOSTIC: they corroborate a DIRTY verdict when coupled to degraded PSNR,
# and on their own they mean nothing. The shipped-image control row establishes
# empirically whether our lineage happens to be byte-stable; only if that
# control shows N/N identical MD5s may a later island run treat MD5 spread as a
# secondary finding.
#
# WHY THE FIXTURE IS A FILE AND NOT `videotestsrc`. The defect is
# content-sensitive. A live pattern source would vary the input between runs and
# between boards, which destroys the comparison the whole ledger rests on. The
# fixture is generated ONCE (see tests/fixtures/oracle/README.md) and its
# checksum travels with it.
#
# DECODER NOTE. Scoring decodes with ffmpeg, i.e. libavcodec — the same decoder
# `avdec_h264`/`avdec_h265` wrap. The presence of those GStreamer factories is
# recorded separately in the report so the board's decoder inventory is on the
# record too, but the numbers come from libavcodec either way.
#
# READ-ONLY. Encodes into a report directory, reads a fixture, and touches
# nothing else. No unit state, no module, no /sys.
#
# Usage:
#   encode-psnr-oracle.sh [--codec h264|h265|both] [--runs N] [--out DIR]
#   encode-psnr-oracle.sh --self-test
#
# Exit: 0 ran (verdicts in the report), 1 failed, 2 usage, 77 hardware-gated.

set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness-lib.sh
. "${HARNESS_DIR}/lib/harness-lib.sh"

readonly FIXTURE_NAME="testsrc2-640x360-30fps-60f.nv12"
readonly FIXTURE_W=640
readonly FIXTURE_H=360
readonly FIXTURE_FPS=30
readonly FIXTURE_FRAMES=60

# The verdict thresholds. These are the contract, not tuning knobs.
readonly PSNR_FLOOR_DB=35
readonly MAX_LOW_FRAMES=2

CODEC=both
RUNS=20
OUT_DIR=

# ---------------------------------------------------------------------------
# Scoring — shared by the board legs and the self-test
# ---------------------------------------------------------------------------

# score_stream <bitstream> <fixture> <workdir> <tag>
# Prints: "<mean_psnr> <frames_scored> <frames_below_floor>"
# Writes the per-frame stats to <workdir>/<tag>.psnr.
score_stream() {
  local stream=$1 fixture=$2 work=$3 tag=$4 stats
  stats="${work}/${tag}.psnr"

  if ! ffmpeg -hide_banner -loglevel error -y \
    -i "${stream}" \
    -f rawvideo -pix_fmt nv12 -s "${FIXTURE_W}x${FIXTURE_H}" -r "${FIXTURE_FPS}" -i "${fixture}" \
    -lavfi "[0:v][1:v]psnr=stats_file=${stats}" -f null - \
    >"${work}/${tag}.ffmpeg.log" 2>&1; then
    harness_fail_msg "psnr scoring failed for ${tag}; see ${work}/${tag}.ffmpeg.log"
    return 1
  fi
  [ -s "${stats}" ] || {
    harness_fail_msg "psnr produced no per-frame stats for ${tag}"
    return 1
  }

  awk -v floor="${PSNR_FLOOR_DB}" '
    {
      # ffmpeg emits "n:<i> mse_avg:<x> ... psnr_avg:<y> psnr_y:<z> ...".
      # "inf" appears for a bit-exact frame and is treated as the best case.
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^psnr_avg:/) {
          split($i, kv, ":")
          v = (kv[2] == "inf") ? 999 : kv[2] + 0
          sum += v; n++
          if (v < floor) low++
        }
      }
    }
    END {
      if (n == 0) { print "0 0 0"; exit }
      printf "%.3f %d %d\n", sum / n, n, low + 0
    }
  ' "${stats}"
}

# classify_runs <runs-file>
# runs-file: one "<mean> <frames> <low>" line per run.
# Prints CLEAN or DIRTY plus the reason.
classify_runs() {
  awk -v floor="${PSNR_FLOOR_DB}" -v maxlow="${MAX_LOW_FRAMES}" '
    { mean[NR] = $1; frames[NR] = $2; low[NR] = $3 }
    END {
      verdict = "CLEAN"; reason = "all runs mean >= floor and low-frame count within budget"
      for (i = 1; i <= NR; i++) {
        if (mean[i] + 0 < floor) {
          verdict = "DIRTY"
          reason = sprintf("run %d mean %.3f dB is below the %d dB floor", i, mean[i], floor)
          break
        }
        if (low[i] + 0 > maxlow) {
          verdict = "DIRTY"
          reason = sprintf("run %d has %d frames below %d dB (budget %d)", i, low[i], floor, maxlow)
          break
        }
      }
      if (NR == 0) { verdict = "DIRTY"; reason = "no runs were scored" }
      printf "%s|%s\n", verdict, reason
    }
  ' "$1"
}

# ---------------------------------------------------------------------------
# Board leg
# ---------------------------------------------------------------------------

encoder_for() { case "$1" in h265) echo mpph265enc ;; *) echo mpph264enc ;; esac; }
parser_for() { case "$1" in h265) echo h265parse ;; *) echo h264parse ;; esac; }
decoder_factory_for() { case "$1" in h265) echo avdec_h265 ;; *) echo avdec_h264 ;; esac; }

# encode_command <codec> <fixture> <output> — the exact command, printed into
# the report so every number is reproducible by hand.
encode_command() {
  local codec=$1 fixture=$2 out=$3
  printf '%s' "gst-launch-1.0 -e filesrc location=${fixture} \
! rawvideoparse format=nv12 width=${FIXTURE_W} height=${FIXTURE_H} framerate=${FIXTURE_FPS}/1 \
! $(encoder_for "${codec}") rc-mode=fixqp qp-init=26 qp-min=26 qp-max=26 gop=30 \
! $(parser_for "${codec}") ! filesink location=${out}"
}

run_codec() {
  local codec=$1 fixture=$2 out=$3 runs_file scored=0 i cmd stream mean frames low md5 size
  runs_file="${out}/${codec}.runs"
  : >"${runs_file}"

  printf 'codec=%s encoder=%s decoder_factory=%s runs=%d\n' \
    "${codec}" "$(encoder_for "${codec}")" "$(decoder_factory_for "${codec}")" "${RUNS}"
  printf 'encode_command=%s\n' "$(encode_command "${codec}" "${fixture}" "${out}/<run>.bs")"
  printf 'decoder_factory_present=%s\n' \
    "$(gst-inspect-1.0 "$(decoder_factory_for "${codec}")" >/dev/null 2>&1 && echo yes || echo no)"

  for ((i = 1; i <= RUNS; i++)); do
    stream="${out}/${codec}-run${i}.bs"
    cmd="$(encode_command "${codec}" "${fixture}" "${stream}")"
    if ! eval "${cmd}" >"${out}/${codec}-run${i}.gst.log" 2>&1; then
      printf 'run=%d codec=%s encode=failed log=%s\n' "${i}" "${codec}" \
        "${out}/${codec}-run${i}.gst.log"
      continue
    fi
    [ -s "${stream}" ] || {
      printf 'run=%d codec=%s encode=empty\n' "${i}" "${codec}"
      continue
    }
    md5=$(md5sum "${stream}" | awk '{print $1}')
    size=$(wc -c <"${stream}")
    read -r mean frames low < <(score_stream "${stream}" "${fixture}" "${out}" "${codec}-run${i}") || {
      printf 'run=%d codec=%s score=failed\n' "${i}" "${codec}"
      continue
    }
    printf 'run=%d codec=%s mean_psnr_db=%s frames=%s frames_below_%d_db=%s md5=%s bytes=%s\n' \
      "${i}" "${codec}" "${mean}" "${frames}" "${PSNR_FLOOR_DB}" "${low}" "${md5}" "${size}"
    printf '%s %s %s\n' "${mean}" "${frames}" "${low}" >>"${runs_file}"
    scored=$((scored + 1))
  done

  local distinct
  distinct=$(for f in "${out}/${codec}-run"*.bs; do
    [ -e "${f}" ] && md5sum "${f}"
  done | awk '{print $1}' | sort -u | wc -l)
  printf 'codec=%s distinct_md5=%s scored_runs=%s\n' "${codec}" "${distinct}" "${scored}"

  if [ "${scored}" -eq 0 ]; then
    printf 'codec=%s VERDICT=INCONCLUSIVE reason=no run produced a scorable bitstream\n' "${codec}"
    return 1
  fi

  local classified verdict reason
  classified="$(classify_runs "${runs_file}")"
  verdict="${classified%%|*}"
  reason="${classified#*|}"
  printf 'codec=%s VERDICT=%s reason=%s\n' "${codec}" "${verdict}" "${reason}"
  return 0
}

# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------
#
# The self-test proves the ORACLE, not the hardware. It builds two software
# streams from the same fixture with ffmpeg's libx264 at the same fixed QP:
#
#   known-good  a straight fixed-QP encode                 -> must score CLEAN
#   smeared     the same encode of a temporally smeared     -> must score DIRTY
#               source (tmix over 8 frames), which reproduces the bimodal
#               signature of the real defect: a long low-PSNR body with a
#               high-PSNR island at the head, where the smear window has not
#               filled yet
#
# A scoring bug that made everything look clean would fail the DIRTY leg; one
# that made everything look dirty would fail the CLEAN leg. Both directions are
# required, which is what stops the oracle from being vacuous.
self_test() {
  local fixtures fixture work rc=0 mean frames low classified verdict

  require_tools ffmpeg awk sha256sum md5sum || return "${HARNESS_FAIL}"
  fixtures="$(harness_fixtures_dir)" || {
    harness_fail_msg "fixture tree not found"
    return "${HARNESS_FAIL}"
  }
  fixture="${fixtures}/oracle/${FIXTURE_NAME}"
  assert_sha256 "${fixture}" "${fixture}.sha256" || return "${HARNESS_FAIL}"

  work="$(mktemp -d)" || return "${HARNESS_FAIL}"
  # shellcheck disable=SC2064
  trap "rm -rf '${work}'" RETURN

  printf 'self_test=encode-psnr-oracle\n'
  printf 'psnr_floor_db=%d max_low_frames=%d\n' "${PSNR_FLOOR_DB}" "${MAX_LOW_FRAMES}"

  if ! ffmpeg -hide_banner -loglevel error -y \
    -f rawvideo -pix_fmt nv12 -s "${FIXTURE_W}x${FIXTURE_H}" -r "${FIXTURE_FPS}" -i "${fixture}" \
    -c:v libx264 -qp 26 -g 30 -bf 0 -f h264 "${work}/known-good.h264" 2>"${work}/enc-good.log"; then
    harness_fail_msg "self-test could not build the known-good stream (libx264 unavailable?)"
    cat "${work}/enc-good.log" >&2
    return "${HARNESS_FAIL}"
  fi

  if ! ffmpeg -hide_banner -loglevel error -y \
    -f rawvideo -pix_fmt nv12 -s "${FIXTURE_W}x${FIXTURE_H}" -r "${FIXTURE_FPS}" -i "${fixture}" \
    -vf "tmix=frames=8:weights='1 1 1 1 1 1 1 1'" \
    -c:v libx264 -qp 26 -g 30 -bf 0 -f h264 "${work}/smeared.h264" 2>"${work}/enc-smear.log"; then
    harness_fail_msg "self-test could not build the smeared stream"
    cat "${work}/enc-smear.log" >&2
    return "${HARNESS_FAIL}"
  fi

  # --- known-good must be CLEAN -------------------------------------------
  read -r mean frames low < <(score_stream "${work}/known-good.h264" "${fixture}" "${work}" "known-good") ||
    return "${HARNESS_FAIL}"
  printf 'known_good mean_psnr_db=%s frames=%s frames_below_%d_db=%s\n' \
    "${mean}" "${frames}" "${PSNR_FLOOR_DB}" "${low}"
  [ "${frames}" -eq "${FIXTURE_FRAMES}" ] || {
    harness_fail_msg "known-good scored ${frames} frames, expected ${FIXTURE_FRAMES}"
    rc=1
  }
  printf '%s %s %s\n' "${mean}" "${frames}" "${low}" >"${work}/known-good.runs"
  classified="$(classify_runs "${work}/known-good.runs")"
  verdict="${classified%%|*}"
  printf 'known_good VERDICT=%s reason=%s\n' "${verdict}" "${classified#*|}"
  [ "${verdict}" = CLEAN ] || {
    harness_fail_msg "the known-good fixture scored ${verdict}; the oracle is too strict"
    rc=1
  }

  # --- smeared must be DIRTY ----------------------------------------------
  read -r mean frames low < <(score_stream "${work}/smeared.h264" "${fixture}" "${work}" "smeared") ||
    return "${HARNESS_FAIL}"
  printf 'smeared mean_psnr_db=%s frames=%s frames_below_%d_db=%s\n' \
    "${mean}" "${frames}" "${PSNR_FLOOR_DB}" "${low}"
  printf '%s %s %s\n' "${mean}" "${frames}" "${low}" >"${work}/smeared.runs"
  classified="$(classify_runs "${work}/smeared.runs")"
  verdict="${classified%%|*}"
  printf 'smeared VERDICT=%s reason=%s\n' "${verdict}" "${classified#*|}"
  [ "${verdict}" = DIRTY ] || {
    harness_fail_msg "the synthetically smeared fixture scored ${verdict}; the oracle is vacuous"
    rc=1
  }

  [ "${rc}" -eq 0 ] || {
    harness_verdict FAIL "self-test"
    return $?
  }
  harness_verdict PASS "self-test: known-good CLEAN, smeared DIRTY"
}

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

main() {
  local fixtures fixture rc=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --self-test)
        self_test
        exit $?
        ;;
      --codec)
        CODEC=${2:-}
        shift 2
        ;;
      --runs)
        RUNS=${2:-}
        shift 2
        ;;
      --out)
        OUT_DIR=${2:-}
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

  case "${CODEC}" in h264 | h265 | both) ;; *)
    harness_fail_msg "--codec must be h264, h265 or both"
    exit "${HARNESS_USAGE}"
    ;;
  esac
  case "${RUNS}" in '' | *[!0-9]*)
    harness_fail_msg "--runs must be a positive integer"
    exit "${HARNESS_USAGE}"
    ;;
  esac

  require_tools gst-launch-1.0 gst-inspect-1.0 ffmpeg awk md5sum sha256sum ||
    exit "${HARNESS_USAGE}"

  fixtures="$(harness_fixtures_dir)" || {
    harness_fail_msg "fixture tree not found"
    exit "${HARNESS_USAGE}"
  }
  fixture="${fixtures}/oracle/${FIXTURE_NAME}"
  assert_sha256 "${fixture}" "${fixture}.sha256" || exit "${HARNESS_FAIL}"

  local -a codecs=()
  case "${CODEC}" in
    both) codecs=(h264 h265) ;;
    *) codecs=("${CODEC}") ;;
  esac

  # Hardware gate: absent encoder means nothing was measured. 77, never 0.
  local codec missing=0
  for codec in "${codecs[@]}"; do
    gst-inspect-1.0 "$(encoder_for "${codec}")" >/dev/null 2>&1 || {
      printf 'encoder_absent=%s\n' "$(encoder_for "${codec}")"
      missing=$((missing + 1))
    }
  done
  if [ "${missing}" -eq "${#codecs[@]}" ]; then
    harness_verdict GATED "no MPP encoder on this host; run this on the board"
    exit $?
  fi

  [ -n "${OUT_DIR}" ] || OUT_DIR="$(harness_out_dir encode-psnr-oracle)" || exit "${HARNESS_FAIL}"
  mkdir -p "${OUT_DIR}" || exit "${HARNESS_FAIL}"
  printf 'report_dir=%s\n' "${OUT_DIR}"
  printf 'fixture=%s\n' "${fixture}"

  for codec in "${codecs[@]}"; do
    gst-inspect-1.0 "$(encoder_for "${codec}")" >/dev/null 2>&1 || continue
    run_codec "${codec}" "${fixture}" "${OUT_DIR}" || rc=1
  done

  [ "${rc}" -eq 0 ] || {
    harness_verdict FAIL "at least one codec produced no scorable run"
    exit $?
  }
  harness_verdict PASS "verdict rows written to ${OUT_DIR}"
  exit $?
}

main "$@"
