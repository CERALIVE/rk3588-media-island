#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

check_ref() {
  if [[ "$1" != refs/heads/release/linux-7.4 ]]; then
    printf '::error::release dispatched from %s; only refs/heads/release/linux-7.4 releases\n' "$1" >&2
    return 1
  fi
}

if [[ "${1:-}" == --self-test ]]; then
  failures=0
  for ref in \
    refs/heads/release/linux-7.4 \
    refs/heads/main \
    refs/heads/release/linux-7.4x \
    refs/tags/v1 \
    refs/heads/release/linux-7.5; do
    expected=1
    [[ "$ref" != refs/heads/release/linux-7.4 ]] || expected=0
    actual=0
    check_ref "$ref" >/dev/null 2>&1 || actual=$?
    if [[ "$actual" == "$expected" ]]; then
      printf 'PASS: %s exits %s\n' "$ref" "$expected"
    else
      printf 'FAIL: %s expected %s, got %s\n' "$ref" "$expected" "$actual" >&2
      failures=$((failures + 1))
    fi
  done
  [[ "$failures" == 0 ]]
else
  check_ref "${GITHUB_REF:-}"
fi
