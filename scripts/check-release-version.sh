#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
export LC_ALL=C

check_version() {
  if [[ -z "$1" || "$1" == *$'\n'* || "$1" == *$'\r'* ||
        ! "$1" =~ ^[0123456789]{4}\.[0123456789]+\.[0123456789]+$ ]]; then
    printf '::error::version must be a single-line CalVer YYYY.MINOR.PATCH with no leading v or suffix\n' >&2
    return 1
  fi
}

if [[ "${1:-}" == --self-test ]]; then
  failures=0
  # UTF-8 bytes keep the Unicode fixtures intact under the C locale.
  for version in \
    2026.11.0 \
    2026.9.5 \
    $'\xd9\xa2\xd9\xa0\xd9\xa2\xd9\xa6.11.0' \
    $'\xef\xbc\x92\xef\xbc\x90\xef\xbc\x92\xef\xbc\x96.11.0' \
    $'2026.11.\xc2\xb2' \
    $'2026.11.0\ntag=vNOT-CALVER' \
    $'2026.11.0\nsha=8cdbdcb371197849b4ab25ee231a24b5f56bc2fe' \
    $'2026.11.0\n' \
    $'2026.11.0\r' \
    '' \
    v2026.11.0 \
    2026.11.0.1 \
    2026.11.0-rc1; do
    expected=1
    [[ "$version" != 2026.11.0 && "$version" != 2026.9.5 ]] || expected=0
    actual=0
    check_version "$version" >/dev/null 2>&1 || actual=$?
    if [[ "$actual" == "$expected" ]]; then
      printf 'PASS: %q exits %s\n' "$version" "$expected"
    else
      printf 'FAIL: %q expected %s, got %s\n' "$version" "$expected" "$actual" >&2
      failures=$((failures + 1))
    fi
  done
  [[ "$failures" == 0 ]]
else
  check_version "${VERSION:-}"
fi
