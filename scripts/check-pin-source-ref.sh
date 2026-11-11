#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

check_pin_source_ref() {
  local consumer_ref="${CONSUMER_PIN_REF:-main}"
  if [[ "${GITHUB_REF:-}" == refs/heads/main || "${GITHUB_BASE_REF:-}" == main ]] &&
    [[ "$consumer_ref" != main ]]; then
    printf '::error::CONSUMER_PIN_REF must be main on main or a PR targeting main (got %s).\n' \
      "$consumer_ref" >&2
    return 1
  fi
  printf 'ok: consumer pin ref %s\n' "$consumer_ref"
}

self_test() {
  local failures=0
  check_case() {
    local name="$1" ref="$2" base="$3" consumer="$4" expected="$5" actual=0 output
    output="$(
      export GITHUB_REF="$ref" GITHUB_BASE_REF="$base" CONSUMER_PIN_REF="$consumer"
      if [[ -z "$consumer" ]]; then unset CONSUMER_PIN_REF; fi
      check_pin_source_ref 2>&1
    )" || actual=$?
    if [[ "$actual" == "$expected" ]]; then
      printf 'PASS %s (exit %s)\n' "$name" "$actual"
    else
      printf 'FAIL %s: expected exit %s, got %s\n%s\n' "$name" "$expected" "$actual" "$output"
      failures=$((failures + 1))
    fi
  }

  check_case main-main refs/heads/main '' main 0
  check_case main-candidate refs/heads/main '' rebase/v7.4 1
  check_case release-candidate refs/heads/release/linux-7.4 '' rebase/v7.4 0
  check_case pr-to-main-candidate refs/pull/1/merge main rebase/v7.4 1
  check_case main-missing-key refs/heads/main '' '' 0
  [[ "$failures" == 0 ]]
}

case "${1:-}" in
  --self-test) self_test ;;
  '') check_pin_source_ref ;;
  *) printf 'usage: check-pin-source-ref.sh [--self-test]\n' >&2; exit 2 ;;
esac
