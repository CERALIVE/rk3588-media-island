#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only

set -uo pipefail

EXIT_FAIL=1
EXIT_USAGE=2
EXIT_GATED=77

check_root() {
  local root=$1
  local failures=0
  local path
  local required=(
    proc/mpp_service/supports-device
    proc/mpp_service/load
    proc/mpp_service/sessions-summary
    proc/rkrga/load
  )

  for path in "${required[@]}"; do
    if [[ -r "$root/$path" ]]; then
      printf 'telemetry.%s=readable\n' "$path"
    else
      printf 'telemetry.%s=missing\n' "$path"
      failures=$((failures + 1))
    fi
  done

  if ((failures)); then
    printf 'VERDICT: FAIL (%d required telemetry files missing)\n' "$failures"
    return "$EXIT_FAIL"
  fi
  printf 'VERDICT: PASS (all required telemetry files readable)\n'
}

self_test() {
  local tmp

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/proc/mpp_service" "$tmp/proc/rkrga"
  : >"$tmp/proc/mpp_service/supports-device"
  : >"$tmp/proc/mpp_service/load"
  : >"$tmp/proc/mpp_service/sessions-summary"
  : >"$tmp/proc/rkrga/load"

  check_root "$tmp" || return "$EXIT_FAIL"
  rm "$tmp/proc/rkrga/load"
  if check_root "$tmp" >/dev/null; then
    printf 'VERDICT: FAIL (missing RGA load file was accepted)\n'
    return "$EXIT_FAIL"
  fi
  printf 'VERDICT: PASS (self-test discriminates complete and missing surfaces)\n'
}

case ${1-} in
  --self-test)
    self_test
    ;;
  "")
    if [[ ! -e /dev/mpp_service || ! -e /dev/rga ]]; then
      printf 'VERDICT: GATED (island MPP/RGA device nodes are not both present)\n'
      exit "$EXIT_GATED"
    fi
    check_root / || exit "$EXIT_FAIL"
    ;;
  *)
    printf 'usage: %s [--self-test]\n' "$0" >&2
    exit "$EXIT_USAGE"
    ;;
esac
