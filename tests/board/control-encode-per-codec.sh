#!/usr/bin/env bash
# Cold-boot, no-fault control encode. Hardware execution is board-gated.

set -uo pipefail

readonly EXIT_FAIL=1
readonly EXIT_USAGE=2
readonly EXIT_HARDWARE_GATED=77
readonly CODECS=(h265 h264 jpeg)

usage() {
  printf 'usage: %s [--self-test] [--out DIR]\n' "${0##*/}" >&2
}

encoder_for() {
  case "$1" in
    h265) printf '%s\n' mpph265enc ;;
    h264) printf '%s\n' mpph264enc ;;
    jpeg) printf '%s\n' mppjpegenc ;;
    *) return 1 ;;
  esac
}

suffix_for() {
  case "$1" in
    h265) printf '%s\n' h265 ;;
    h264) printf '%s\n' h264 ;;
    jpeg) printf '%s\n' jpg ;;
    *) return 1 ;;
  esac
}

run_encode() {
  local codec=$1 out=$2 encoder suffix
  encoder=$(encoder_for "${codec}") || return 1
  suffix=$(suffix_for "${codec}") || return 1

  gst-launch-1.0 -q -e videotestsrc num-buffers=60 \
    ! video/x-raw,format=NV12,width=1920,height=1080,framerate=30/1 \
    ! "${encoder}" ! filesink location="${out}/${codec}.${suffix}"
}

run_sequence() {
  local out=$1 codec

  for codec in "${CODECS[@]}"; do
    printf 'CONTROL_CODEC_BEGIN=%s\n' "${codec}"
    if ! run_encode "${codec}" "${out}"; then
      printf 'CONTROL_CODEC_FAIL=%s\n' "${codec}" >&2
      return "${EXIT_FAIL}"
    fi
    if [[ ! -s "${out}/${codec}.$(suffix_for "${codec}")" ]]; then
      printf 'CONTROL_CODEC_EMPTY=%s\n' "${codec}" >&2
      return "${EXIT_FAIL}"
    fi
    printf 'CONTROL_CODEC_PASS=%s\n' "${codec}"
  done
}

self_test() {
  local got expected codec
  got=$(printf '%s\n' "${CODECS[@]}")
  expected=$'h265\nh264\njpeg'
  if [[ "${got}" != "${expected}" ]]; then
    printf 'SELF_TEST_FAIL: codec order was:\n%s\n' "${got}" >&2
    return 1
  fi
  for codec in "${CODECS[@]}"; do
    encoder_for "${codec}" >/dev/null || return 1
    suffix_for "${codec}" >/dev/null || return 1
  done
  printf 'SELF_TEST_PASS: cold-boot control order is h265,h264,jpeg\n'
}

main() {
  local out='' self=0
  while (($#)); do
    case "$1" in
      --self-test) self=1; shift ;;
      --out)
        (($# >= 2)) || { usage; return "${EXIT_USAGE}"; }
        out=$2; shift 2 ;;
      *) usage; return "${EXIT_USAGE}" ;;
    esac
  done

  if ((self)); then
    self_test
    return
  fi
  if [[ ${CERALIVE_BOARD_TEST:-0} != 1 ]]; then
    printf 'HARDWARE_GATED: set CERALIVE_BOARD_TEST=1 on a freshly booted board\n' >&2
    return "${EXIT_HARDWARE_GATED}"
  fi
  [[ -n ${out} ]] || out=$(mktemp -d)
  mkdir -p "${out}"
  run_sequence "${out}"
}

main "$@"
