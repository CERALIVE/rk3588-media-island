#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

readonly EXPECTED_NODES=(
  '/mpp-srv|rockchip,mpp-service|service'
  '/rkvenc-ccu|rockchip,rkv-encoder-v2-ccu|coordinator'
  '/rkvenc-core@fdbd0000|rockchip,rkv-encoder-v2-core|client'
  '/rkvenc-core@fdbe0000|rockchip,rkv-encoder-v2-core|client'
  '/rkvdec-ccu@fdc30000|rockchip,rkv-decoder-v2-ccu|coordinator'
  '/video-codec@fdc38000|rockchip,rkv-decoder-v2|client'
  '/video-codec@fdc40000|rockchip,rkv-decoder-v2|client'
  '/jpegd@fdb90000|rockchip,rkv-jpeg-decoder-v1|client'
)

readonly ISLAND_RGA_NODES=(
  '/rga@fdb60000|rockchip,rga3_core0'
  '/rga@fdb70000|rockchip,rga3_core1'
  '/rga@fdb80000|rockchip,rga2_core0'
)

check_dtb() {
  local dtb=$1
  local entry path compatible kind actual
  local failures=0

  for entry in "${EXPECTED_NODES[@]}"; do
    IFS='|' read -r path compatible kind <<<"$entry"
    if ! actual=$(fdtget -t s "$dtb" "$path" compatible 2>/dev/null); then
      printf 'FAIL: %s: missing %s compatible\n' "$dtb" "$path" >&2
      failures=$((failures + 1))
      continue
    fi
    if [[ $actual != "$compatible" ]]; then
      printf 'FAIL: %s: %s compatible is [%s], expected sole [%s]\n' \
        "$dtb" "$path" "$actual" "$compatible" >&2
      failures=$((failures + 1))
    fi
    if [[ $kind == client ]] &&
      ! fdtget "$dtb" "$path" rockchip,skip-pmu-idle-request >/dev/null 2>&1; then
      printf 'FAIL: %s: %s lacks rockchip,skip-pmu-idle-request\n' \
        "$dtb" "$path" >&2
      failures=$((failures + 1))
    fi
  done

  for entry in "${ISLAND_RGA_NODES[@]}"; do
    IFS='|' read -r path compatible <<<"$entry"
    if ! actual=$(fdtget -t s "$dtb" "$path" compatible 2>/dev/null); then
      printf 'FAIL: %s: missing island-RGA node %s\n' "$dtb" "$path" >&2
      failures=$((failures + 1))
      continue
    fi
    if [[ $actual != "$compatible" ]]; then
      printf 'FAIL: %s: %s compatible is [%s], expected sole [%s]\n' \
        "$dtb" "$path" "$actual" "$compatible" >&2
      failures=$((failures + 1))
    fi
  done

  ((failures == 0))
}

self_test() {
  local scratch good_dts good_dtb bad_dts bad_dtb entry path compatible kind
  scratch=$(mktemp -d)
  trap 'rm -rf "$scratch"' RETURN
  good_dts=$scratch/good.dts
  good_dtb=$scratch/good.dtb
  bad_dts=$scratch/bad.dts
  bad_dtb=$scratch/bad.dtb

  {
    printf '/dts-v1/;\n/ {\n'
    for entry in "${EXPECTED_NODES[@]}"; do
      IFS='|' read -r path compatible kind <<<"$entry"
      printf '  %s { compatible = "%s";' "${path#/}" "$compatible"
      [[ $kind != client ]] || printf ' rockchip,skip-pmu-idle-request;'
      printf ' };\n'
    done
    for entry in "${ISLAND_RGA_NODES[@]}"; do
      IFS='|' read -r path compatible <<<"$entry"
      printf '  %s { compatible = ' "${path#/}"
      if [[ $compatible == *' '* ]]; then
        printf '"%s", "%s"' "${compatible%% *}" "${compatible#* }"
      else
        printf '"%s"' "$compatible"
      fi
      printf '; };\n'
    done
    printf '};\n'
  } >"$good_dts"

  dtc -q -I dts -O dtb -o "$good_dtb" "$good_dts"
  check_dtb "$good_dtb"

  python3 - "$good_dts" "$bad_dts" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
Path(sys.argv[2]).write_text(
    source.replace(" rockchip,skip-pmu-idle-request;", "", 1),
    encoding="utf-8",
)
PY
  dtc -q -I dts -O dtb -o "$bad_dtb" "$bad_dts"
  if check_dtb "$bad_dtb" >/dev/null 2>&1; then
    printf 'FAIL: missing skip-PMU property mutation passed\n' >&2
    return 1
  fi

  printf 'PASS: DTB ownership checker accepts the contract and rejects a missing skip-PMU property\n'
}

case ${1:-} in
  --self-test)
    self_test
    ;;
  '')
    printf 'usage: %s ROCK_5B_PLUS_DTB ORANGEPI_5_PLUS_DTB\n' "$0" >&2
    exit 2
    ;;
  *)
    if (($# != 2)); then
      printf 'usage: %s ROCK_5B_PLUS_DTB ORANGEPI_5_PLUS_DTB\n' "$0" >&2
      exit 2
    fi
    command -v fdtget >/dev/null || {
      printf 'FAIL: fdtget is required\n' >&2
      exit 1
    }
    check_dtb "$1"
    check_dtb "$2"
    printf 'PASS: both RK3588 board DTBs satisfy MPP and RGA island ownership\n'
    ;;
esac
