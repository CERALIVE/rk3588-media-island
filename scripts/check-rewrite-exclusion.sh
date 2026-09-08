#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Independent assertion over generated patch targets; never imports the generator.
set -uo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

check_targets() {
  local dir=$1 patch rc=0
  [[ -f "$dir/series" ]] || return 1
  while IFS= read -r patch; do
    [[ -n "$patch" ]] || continue
    [[ -f "$dir/$patch" ]] || return 1
    if ! awk '
      /^diff --git / {
        if ($3 ~ /island\/comparison\/|mpp[-_]rewrite|rga[-_]rewrite/ ||
            $4 ~ /island\/comparison\/|mpp[-_]rewrite|rga[-_]rewrite/)
          bad = 1
      }
      END { exit bad ? 1 : 0 }
    ' "$dir/$patch"; then
      printf 'FAIL: comparison target in %s\n' "$patch" >&2
      rc=1
    fi
  done < "$dir/series"
  return "$rc"
}

self_test() (
  local work before after target rc=0
  work=$(mktemp -d) || exit 1
  trap 'rm -rf -- "$work"' EXIT
  mkdir -p "$work/scripts" "$work/drivers/video/rockchip/mpp" || exit 1
  cp "$root/scripts/build-series.py" "$work/scripts/" || exit 1
  printf 'int production_probe(void);\n' > "$work/drivers/video/rockchip/mpp/probe.c"
  python3 "$work/scripts/build-series.py" >/dev/null || exit 1
  before=$(sha256sum "$work/patches/"*.patch) || exit 1
  mkdir -p "$work/island/comparison/rewrite/mpp-rewrite" || exit 1
  printf 'int comparison_only(void);\n' > "$work/island/comparison/rewrite/mpp-rewrite/mpp_rewrite.c"
  printf 'config ROCKCHIP_MPP_REWRITE\n' > "$work/island/comparison/rewrite/mpp-rewrite/Kconfig"
  python3 "$work/scripts/build-series.py" >/dev/null || exit 1
  after=$(sha256sum "$work/patches/"*.patch) || exit 1
  [[ "$before" == "$after" ]] || exit 1
  check_targets "$work/patches" || exit 1
  printf 'PASS: real generator output unchanged by comparison source\n'

  printf 'injected.patch\n' > "$work/patches/series"
  for target in island/comparison/rewrite/probe.c drivers/video/rockchip/mpp-rewrite/probe.c \
    drivers/video/rockchip/rga-rewrite/probe.c drivers/video/rockchip/mpp/mpp_rewrite.c \
    drivers/video/rockchip/rga3/rga_rewrite.c; do
    printf 'diff --git a/%s b/%s\n' "$target" "$target" > "$work/patches/injected.patch"
    if check_targets "$work/patches" >/dev/null 2>&1; then
      printf 'FAIL: accepted %s\n' "$target" >&2
      rc=1
    fi
  done
  [[ "$rc" == 0 ]] && printf 'PASS: every injected rewrite target rejected\n'
  exit "$rc"
)

case ${1:-} in
  --self-test) self_test ;;
  '') check_targets "$root/patches" && printf 'PASS: production series has no rewrite targets\n' ;;
  *) printf 'usage: %s [--self-test]\n' "$0" >&2; exit 2 ;;
esac
