#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
root=$(realpath -- "$(dirname -- "${BASH_SOURCE[0]}")/..")
python3 "$root/docs/repro/rga-import-order.py"
python3 "$root/docs/repro/rga-table-lifetime.py"
python3 "$root/docs/repro/rga-commit-lifetime.py"
python3 "$root/docs/repro/rga-routing.py"
mkdir -p "$root/test-results"
work=$(mktemp -d "$root/test-results/rga-user-stage.XXXXXX")
trap 'rm -rf "$work"' EXIT
cc -std=gnu11 -Wall -Wextra -Werror -Wno-sign-compare \
  -I"$root/drivers/video/rockchip/rga3/include" \
  "$root/docs/repro/rga-user-stage.c" -o "$work/test"
"$work/test"
