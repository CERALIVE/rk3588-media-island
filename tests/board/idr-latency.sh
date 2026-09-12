#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export PYTHONDONTWRITEBYTECODE=1
case ${1:-} in
--self-test)
  [[ $# == 1 ]] || exit 2
  exec python3 "$HERE/lib/test_idr_latency.py"
  ;;
--request)
  [[ $# == 3 ]] || exit 2
  [[ ${CERALIVE_BOARD_TEST:-0} == 1 ]] || { printf 'hardware-gated: set CERALIVE_BOARD_TEST=1 under the board lock\n' >&2; exit 77; }
  exec python3 "$HERE/lib/idr_rpc.py" "$2" "$3"
  ;;
--score)
  [[ $# == 5 ]] || exit 2
  exec python3 "$HERE/lib/idr_latency.py" "$2" "$3" "$4" "$5"
  ;;
*)
  printf 'usage: %s --self-test | --request SOCKET REQUESTS.tsv | --score STREAM.ts INPUT.tsv REQUESTS.tsv PTS_OFFSET_90K\n' "$0" >&2
  exit 2
  ;;
esac
