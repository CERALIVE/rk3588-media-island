#!/usr/bin/env bash
# check-action-pins.sh -- every `uses:` is pinned to the CURRENT latest major.
#
# The CeraLive CI/CD canon pins each action to its latest stable MAJOR and says
# to resolve that major live rather than from memory. This script is that
# resolution, executed: it reads every `uses:` in .github/workflows/, asks the
# GitHub releases API for each action's latest tag, and compares the majors.
#
# It is a DRIFT REPORT with teeth, not a version bumper. It never edits a
# workflow -- Dependabot owns the bump, a human owns the review, and a script
# that rewrote a pin would race both. What it prevents is the failure mode the
# canon exists for: a pin nobody re-checked, so CI proves a repository against a
# toolchain that has since moved.
#
# NETWORK IS REQUIRED, and its absence is a SKIP rather than a pass. A green
# result from an unreachable API would be the exact false-green the canon warns
# about, so an unresolvable action is reported and exits non-zero unless
# --allow-offline is passed.
#
# Usage:
#   scripts/check-action-pins.sh                 # resolve live and compare
#   scripts/check-action-pins.sh --allow-offline # report, do not fail, on API loss
#   scripts/check-action-pins.sh --self-test     # prove the comparison logic

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly WORKFLOW_DIR="${REPO_ROOT}/.github/workflows"

allow_offline=0
self_test=0

# major_of "v7.0.1" -> "v7"; "1.14.4+ceralive.1" -> "v1". Tag shapes vary across
# publishers, so the major is extracted rather than assumed to be the first
# character.
major_of() {
  local tag="${1#v}"
  printf 'v%s' "${tag%%.*}"
}

# A `uses:` reference splits into owner/repo and ref. A local (./...) or a
# docker:// reference has no release feed and is deliberately not compared.
collect_uses() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  grep -rhoE '^\s*(-\s*)?uses:\s*\S+' "$dir" 2>/dev/null |
    sed -E 's/^\s*(-\s*)?uses:\s*//' |
    grep -vE '^(\./|docker://)' |
    sort -u
}

run_check() {
  local -a stale=() unresolved=()
  local checked=0

  local reference
  while IFS= read -r reference; do
    [ -n "$reference" ] || continue
    local action="${reference%@*}"
    local pinned="${reference#*@}"
    # A sub-action (owner/repo/path@ref) releases from its top-level repository.
    local slug
    slug="$(printf '%s' "$action" | cut -d/ -f1,2)"

    local latest
    if ! latest="$(gh api "repos/${slug}/releases/latest" --jq .tag_name 2>/dev/null)" ||
      [ -z "$latest" ]; then
      unresolved+=("${reference} (no latest release from repos/${slug})")
      continue
    fi

    checked=$((checked + 1))
    local want have
    want="$(major_of "$latest")"
    have="$(major_of "$pinned")"
    if [ "$want" != "$have" ]; then
      stale+=("${reference} is pinned to ${have}; the current latest is ${latest} (${want})")
    else
      printf '  ok  %-46s %s (latest %s)\n' "$action" "$have" "$latest"
    fi
  done < <(collect_uses "$WORKFLOW_DIR")

  local rc=0
  if [ "${#stale[@]}" -gt 0 ]; then
    printf '\nFAIL: %d action pin(s) are behind the current latest major:\n' "${#stale[@]}"
    printf '  %s\n' "${stale[@]}"
    printf '\nBump the pin to the latest MAJOR (never a patch or minor); Dependabot\n'
    printf 'keeps it current from there.\n'
    rc=1
  fi

  if [ "${#unresolved[@]}" -gt 0 ]; then
    printf '\n%s: %d action(s) could not be resolved:\n' \
      "$([ "$allow_offline" -eq 1 ] && printf 'SKIPPED' || printf 'FAIL')" \
      "${#unresolved[@]}"
    printf '  %s\n' "${unresolved[@]}"
    printf '\nAn unresolvable action is NOT a pass -- a green run against an\n'
    printf 'unreachable API proves nothing. Re-run with network, or pass\n'
    printf -- '--allow-offline to downgrade this to a report.\n'
    [ "$allow_offline" -eq 1 ] || rc=1
  fi

  if [ "$rc" -eq 0 ] && [ "$checked" -gt 0 ]; then
    printf '\nOK: %d action pin(s) are at the current latest major.\n' "$checked"
  elif [ "$rc" -eq 0 ] && [ "$checked" -eq 0 ]; then
    printf 'OK: no comparable "uses:" references found under .github/workflows/.\n'
  fi
  return "$rc"
}

self_test_run() {
  local failures=0
  printf 'self_test=check-action-pins\n'

  check_case() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
      printf '  [ok] %s\n' "$name"
    else
      printf '  [FAIL] %s (expected %s, got %s)\n' "$name" "$expected" "$actual"
      failures=$((failures + 1))
    fi
  }

  check_case 'a v-prefixed tag yields its major' 'v7' "$(major_of v7.0.1)"
  check_case 'an unprefixed tag yields its major' 'v6' "$(major_of 6.1.0)"
  check_case 'a build-metadata tag yields its major' 'v1' "$(major_of 1.14.4+ceralive.1)"
  check_case 'a bare major is idempotent' 'v8' "$(major_of v8)"
  check_case 'a stale pin differs from the latest major' 'differ' \
    "$([ "$(major_of v4.2.2)" = "$(major_of v7.0.1)" ] && printf 'same' || printf 'differ')"
  check_case 'a current pin matches the latest major' 'same' \
    "$([ "$(major_of v7)" = "$(major_of v7.0.1)" ] && printf 'same' || printf 'differ')"

  local scratch
  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' RETURN
  mkdir -p "$scratch/wf"
  cat >"$scratch/wf/a.yml" <<'YAML'
jobs:
  one:
    steps:
      - uses: actions/checkout@v7
      - uses: actions/cache@v6
      - uses: ./.github/actions/local
      - uses: docker://alpine:3
YAML
  local collected
  collected="$(collect_uses "$scratch/wf" | tr '\n' ' ')"
  check_case 'local and docker references are excluded' \
    'actions/cache@v6 actions/checkout@v7 ' "$collected"

  local empty
  empty="$(collect_uses "$scratch/absent" | wc -l | tr -d ' ')"
  check_case 'an absent workflow directory yields nothing' '0' "$empty"

  if [ "$failures" -gt 0 ]; then
    printf 'FAIL: %d self-test case(s) failed\n' "$failures"
    return 1
  fi
  printf 'PASS: self-test\n'
  return 0
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow-offline) allow_offline=1 ;;
    --self-test) self_test=1 ;;
    -h | --help)
      sed -n '2,25p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done

if [ "$self_test" -eq 1 ]; then
  self_test_run
  exit $?
fi

if ! command -v gh >/dev/null 2>&1; then
  printf 'FAIL: gh is not installed; action pins cannot be resolved live.\n' >&2
  printf 'A pin checked from memory is exactly what this script replaces.\n' >&2
  exit 1
fi

run_check
