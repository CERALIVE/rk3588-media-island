#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -uo pipefail

readonly FRAMES=600 WIDTH=360 HEIGHT=640 PSNR_FLOOR=35
FFMPEG=${FFMPEG:-ffmpeg}
FFPROBE=${FFPROBE:-ffprobe}
INPUT='' INPUT_SHA='' OUT=''

usage() {
  printf '%s\n' 'rga-psnr-oracle.sh --input FILE --sha256 SHA256 --out NEW-DIR' \
    'rga-psnr-oracle.sh --self-test' \
    'Run locally on the locked board with CERALIVE_BOARD_TEST=1.' \
    'FFMPEG must provide h264_rkmpp, hevc_rkmpp and vpp_rkrga.' \
    'Input: checksum-pinned 1920x1080 H.264 with at least 600 frames.' \
    'Exit: 0 CLEAN, 1 DIRTY/incomplete, 2 usage, 77 hardware-gated.'
}

score_raw() (
  local reference=$1 actual=$2 work=$3 expected=$((WIDTH * HEIGHT * 3 * FRAMES / 2)) value count
  for file in "$reference" "$actual"; do
    if [[ ! -f "$file" ]] || [[ $(wc -c < "$file") -ne "$expected" ]]; then
      printf 'VERDICT=INCOMPLETE reason=raw-frame-count expected_frames=%s\n' "$FRAMES"
      exit 1
    fi
  done
  mkdir -p -- "$work" || exit 1
  cd -- "$work" || exit 1
  if ! "$FFMPEG" -nostdin -hide_banner -loglevel info -filter_complex_threads 1 \
    -f rawvideo -pixel_format yuv420p -video_size "${WIDTH}x${HEIGHT}" -framerate 30 -i "$reference" \
    -f rawvideo -pixel_format yuv420p -video_size "${WIDTH}x${HEIGHT}" -framerate 30 -i "$actual" \
    -lavfi 'psnr=stats_file=psnr.stats' -f null - >score.log 2>&1; then
    printf 'VERDICT=INCOMPLETE reason=scoring-command\n'
    exit 1
  fi
  count=$(awk '$1 == "n:" NR { n++ } END { print n+0 }' psnr.stats)
  [[ "$count" -eq "$FRAMES" ]] || {
    printf 'VERDICT=INCOMPLETE reason=psnr-frame-count\n'; exit 1;
  }
  value=$(awk '/PSNR / { for (i=1;i<=NF;i++) if ($i ~ /^average:/) { split($i,a,":"); print a[2] } }' score.log)
  if [[ "$value" != inf && ! "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf 'VERDICT=INCOMPLETE reason=invalid-psnr\n'; exit 1
  fi
  printf 'frames=%s mean_psnr_db=%s floor_db=%s\n' "$count" "$value" "$PSNR_FLOOR"
  if [[ "$value" == inf ]] || awk -v p="$value" -v floor="$PSNR_FLOOR" 'BEGIN { exit p >= floor ? 0 : 1 }'; then
    printf 'VERDICT=CLEAN\n'
  else
    printf 'VERDICT=DIRTY\n'
    exit 1
  fi
)

self_test() (
  local work result rc
  work=$(mktemp -d) || exit 1
  trap 'rm -rf -- "$work"' EXIT
  "$FFMPEG" -nostdin -v error -f lavfi -i "testsrc2=size=${WIDTH}x${HEIGHT}:rate=30" \
    -frames:v "$FRAMES" -pix_fmt yuv420p -f rawvideo "$work/reference.yuv" || exit 1
  "$FFMPEG" -nostdin -v error -f lavfi -i "color=black:size=${WIDTH}x${HEIGHT}:rate=30" \
    -frames:v "$FRAMES" -pix_fmt yuv420p -f rawvideo "$work/bad.yuv" || exit 1
  result=$(score_raw "$work/reference.yuv" "$work/reference.yuv" "$work/good") || exit 1
  [[ "$result" == *VERDICT=CLEAN* && "$result" == *mean_psnr_db=inf* ]] || exit 1
  printf 'PASS: identical 600-frame input scores CLEAN/inf\n'
  result=$(score_raw "$work/reference.yuv" "$work/bad.yuv" "$work/bad"); rc=$?
  [[ "$rc" == 1 && "$result" == *VERDICT=DIRTY* ]] || exit 1
  printf 'PASS: corrupted 600-frame output scores DIRTY\n'
  truncate -s "$((WIDTH * HEIGHT * 3 * (FRAMES - 1) / 2))" "$work/bad.yuv" || exit 1
  result=$(score_raw "$work/reference.yuv" "$work/bad.yuv" "$work/short"); rc=$?
  [[ "$rc" == 1 && "$result" == *VERDICT=INCOMPLETE* ]] || exit 1
  printf 'PASS: truncated output rejected before scoring\n'
  truncate -s "$((WIDTH * HEIGHT * 3 * (FRAMES + 1) / 2))" "$work/bad.yuv" || exit 1
  result=$(score_raw "$work/reference.yuv" "$work/bad.yuv" "$work/long"); rc=$?
  [[ "$rc" == 1 && "$result" == *VERDICT=INCOMPLETE* ]] || exit 1
  printf 'PASS: extra frame rejected before scoring\n'
)

run_command() {
  local log=$1
  shift
  printf '%q ' "$@"; printf '\n'
  timeout --kill-after=10 300 "$@" > "$log" 2>&1
}

run_board() {
  local actual_sha depth rc=0 filter input_shape
  [[ ${CERALIVE_BOARD_TEST:-0} == 1 ]] || return 77
  [[ -f "$INPUT" && "$INPUT_SHA" =~ ^[0-9a-f]{64}$ && -n "$OUT" && ! -e "$OUT" ]] || return 2
  actual_sha=$(sha256sum -- "$INPUT") || return 1
  [[ ${actual_sha%% *} == "$INPUT_SHA" ]] || { printf 'FAIL: input checksum\n'; return 1; }
  input_shape=$("$FFPROBE" -v error -select_streams v:0 \
    -show_entries stream=codec_name,width,height -of csv=p=0 "$INPUT") || return 1
  [[ "$input_shape" == h264,1920,1080 ]] || { printf 'FAIL: input codec/geometry\n'; return 1; }
  INPUT=$(realpath -- "$INPUT") || return 1
  mkdir -p -- "$OUT" || return 1
  OUT=$(realpath -- "$OUT") || return 1
  printf 'input_sha256=%s frames=%s\n' "$INPUT_SHA" "$FRAMES"
  uname -a
  "$FFMPEG" -version || return 1
  run_command "$OUT/reference.log" "$FFMPEG" -nostdin -hide_banner -loglevel info \
    -c:v h264 -i "$INPUT" -vf 'crop=960:540:160:90,scale=640:360:flags=bicubic,transpose=1' \
    -frames:v "$FRAMES" -pix_fmt yuv420p -fps_mode passthrough -f rawvideo "$OUT/reference.yuv" || return 1
  for depth in 2 0; do
    printf 'async_depth=%s\n' "$depth"
    filter="vpp_rkrga=cw=960:ch=540:cx=160:cy=90:w=640:h=360:format=nv12:transpose=clock:core=rga3_core0:async_depth=$depth"
    if ! run_command "$OUT/depth-$depth.encode.log" "$FFMPEG" -nostdin -hide_banner -loglevel info \
      -hwaccel rkmpp -hwaccel_output_format drm_prime -c:v h264_rkmpp -i "$INPUT" \
      -vf "$filter" -frames:v "$FRAMES" -c:v hevc_rkmpp -b:v 3M \
      -fps_mode passthrough -f hevc "$OUT/depth-$depth.hevc"; then
      printf 'async_depth=%s VERDICT=INCOMPLETE reason=vpp-or-encode\n' "$depth"; rc=1; continue
    fi
    if ! run_command "$OUT/depth-$depth.decode.log" "$FFMPEG" -nostdin -hide_banner -loglevel info \
      -c:v hevc -i "$OUT/depth-$depth.hevc" -pix_fmt yuv420p -fps_mode passthrough \
      -f rawvideo "$OUT/depth-$depth.yuv"; then
      printf 'async_depth=%s VERDICT=INCOMPLETE reason=decode\n' "$depth"; rc=1; continue
    fi
    score_raw "$OUT/reference.yuv" "$OUT/depth-$depth.yuv" "$OUT/depth-$depth" || rc=1
  done
  return "$rc"
}

case ${1:-} in
  --self-test) self_test; exit $? ;;
  --help|-h) usage; exit 0 ;;
esac
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || { usage >&2; exit 2; }
  case $1 in
    --input) INPUT=$2 ;;
    --sha256) INPUT_SHA=$2 ;;
    --out) OUT=$2 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift 2
done
run_board
