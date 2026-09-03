#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only

set -uo pipefail

EXIT_FAIL=1
EXIT_USAGE=2
EXIT_GATED=77

check_session_stats() {
  local root=$1
  local subsystem=$2
  local needs_client=$3
  local base="$root/sys/kernel/debug/$subsystem/sessions"
  local session_dir
  local stats
  local found=0
  local failures=0
  local valid
  local lines=()

  for session_dir in "$base"/*; do
    [[ -d "$session_dir" ]] || continue
    found=1
    stats="$session_dir/stats"
    if [[ ! -r "$stats" ]]; then
      printf 'telemetry.%s/stats=missing\n' "${session_dir#"$root/"}"
      failures=$((failures + 1))
      continue
    fi
    mapfile -t lines <"$stats"
    valid=1
    if ((needs_client)); then
      if ((${#lines[@]} != 3)) ||
        [[ ! ${lines[0]} =~ ^client:[[:space:]]+[0-9]+$ ]] ||
        [[ ! ${lines[1]} =~ ^tasks:[[:space:]]+[0-9]+$ ]] ||
        [[ ! ${lines[2]} =~ ^bytes:[[:space:]]+[0-9]+$ ]]; then
        valid=0
      fi
    elif ((${#lines[@]} != 2)) ||
      [[ ! ${lines[0]} =~ ^tasks:[[:space:]]+[0-9]+$ ]] ||
      [[ ! ${lines[1]} =~ ^bytes:[[:space:]]+[0-9]+$ ]]; then
      valid=0
    fi
    if ((valid)); then
      printf 'telemetry.%s=fdinfo-readable\n' "${stats#"$root/"}"
    else
      printf 'telemetry.%s=invalid\n' "${stats#"$root/"}"
      failures=$((failures + 1))
    fi
  done

  if ((!found)); then
    printf 'telemetry.%s/sessions=idle-no-session-files\n' "$subsystem"
  fi
  ((failures == 0))
}

check_root() {
  local root=$1
  local failures=0
  local path
  local required_files=(
    proc/mpp_service/supports-device
    proc/mpp_service/load
    proc/mpp_service/sessions-summary
    proc/rkrga/load
    sys/kernel/debug/rockchip-mpp/queue_depth
    sys/kernel/debug/rockchip-rga/queue_depth
  )
  local required_dirs=(
    sys/kernel/debug/rockchip-mpp/cores
    sys/kernel/debug/rockchip-mpp/sessions
    sys/kernel/debug/rockchip-rga/cores
    sys/kernel/debug/rockchip-rga/sessions
  )

  for path in "${required_files[@]}"; do
    if [[ -f "$root/$path" && -r "$root/$path" ]]; then
      printf 'telemetry.%s=readable\n' "$path"
    else
      printf 'telemetry.%s=missing\n' "$path"
      failures=$((failures + 1))
    fi
  done
  for path in "${required_dirs[@]}"; do
    if [[ -d "$root/$path" && -r "$root/$path" ]]; then
      printf 'telemetry.%s=readable-directory\n' "$path"
    else
      printf 'telemetry.%s=missing-directory\n' "$path"
      failures=$((failures + 1))
    fi
  done

  check_session_stats "$root" rockchip-mpp 1 || failures=$((failures + 1))
  check_session_stats "$root" rockchip-rga 0 || failures=$((failures + 1))

  if ((failures)); then
    printf 'VERDICT: FAIL (%d required telemetry checks failed)\n' "$failures"
    return "$EXIT_FAIL"
  fi
  printf 'VERDICT: PASS (all required telemetry files readable)\n'
}

self_test() {
  local tmp

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/proc/mpp_service" "$tmp/proc/rkrga" \
    "$tmp/sys/kernel/debug/rockchip-mpp/cores" \
    "$tmp/sys/kernel/debug/rockchip-mpp/sessions/123-1" \
    "$tmp/sys/kernel/debug/rockchip-rga/cores" \
    "$tmp/sys/kernel/debug/rockchip-rga/sessions/123-1"
  : >"$tmp/proc/mpp_service/supports-device"
  : >"$tmp/proc/mpp_service/load"
  : >"$tmp/proc/mpp_service/sessions-summary"
  : >"$tmp/proc/rkrga/load"
  : >"$tmp/sys/kernel/debug/rockchip-mpp/queue_depth"
  : >"$tmp/sys/kernel/debug/rockchip-rga/queue_depth"
  printf 'client:\t16\ntasks:\t7\nbytes:\t1048576\n' \
    >"$tmp/sys/kernel/debug/rockchip-mpp/sessions/123-1/stats"
  printf 'tasks:\t3\nbytes:\t4096\n' \
    >"$tmp/sys/kernel/debug/rockchip-rga/sessions/123-1/stats"

  check_root "$tmp" || return "$EXIT_FAIL"
  rm "$tmp/proc/rkrga/load"
  mkdir "$tmp/proc/rkrga/load"
  if check_root "$tmp" >/dev/null; then
    printf 'VERDICT: FAIL (directory in place of RGA load file was accepted)\n'
    return "$EXIT_FAIL"
  fi
  rmdir "$tmp/proc/rkrga/load"
  : >"$tmp/proc/rkrga/load"
  rm "$tmp/sys/kernel/debug/rockchip-mpp/sessions/123-1/stats"
  if check_root "$tmp" >/dev/null; then
    printf 'VERDICT: FAIL (missing MPP session stats file was accepted)\n'
    return "$EXIT_FAIL"
  fi
  printf 'client:\t16\ntasks:\tnot-a-number\nbytes:\t1048576\n' \
    >"$tmp/sys/kernel/debug/rockchip-mpp/sessions/123-1/stats"
  if check_root "$tmp" >/dev/null; then
    printf 'VERDICT: FAIL (malformed MPP session stats were accepted)\n'
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
