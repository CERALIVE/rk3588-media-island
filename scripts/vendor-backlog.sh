#!/usr/bin/env bash
set -euo pipefail

export GIT_MASTER=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_SHA="${BASE_SHA:-b4ef083dc0c3608e744deabb43dc6b781aadbe6e}"
VENDOR_BRANCH="${VENDOR_BRANCH:-develop-6.1}"
BACKLOG_DOC="${BACKLOG_DOC:-$ROOT/docs/VENDOR-BACKLOG.md}"
PATHS=(
  drivers/video/rockchip/mpp
  drivers/video/rockchip/rga3
  include/uapi/linux/rk-mpp.h
)

cleanup_dir=""
cleanup() {
  if [[ -n "$cleanup_dir" ]]; then
    rm -rf "$cleanup_dir"
  fi
}
trap cleanup EXIT

resolve_vendor_repo() {
  if [[ -n "${VENDOR_REPO:-}" ]]; then
    REPO="$VENDOR_REPO"
    return
  fi

  cleanup_dir="$(mktemp -d)"
  git clone --filter=blob:none --no-checkout --single-branch \
    --shallow-since=2025-12-25 \
    --branch "$VENDOR_BRANCH" https://github.com/rockchip-linux/kernel.git \
    "$cleanup_dir/kernel" >&2
  REPO="$cleanup_dir/kernel"
}

candidate_rows() {
  local repo="$1"
  git -C "$repo" log --reverse --format='%H|%as|%s' \
    "$BASE_SHA..$VENDOR_BRANCH" -- "${PATHS[@]}"
}

documented_shas() {
  sed -nE "s/^\\| \`([0-9a-f]{40})\` \\|.*$/\\1/p" "$BACKLOG_DOC"
}

verify_decisions() {
  local missing=0
  while IFS= read -r row; do
    if [[ "$row" != *'| PICK '* && "$row" != *'| SKIP:'* ]]; then
      printf 'ERROR: backlog row has no decision: %s\n' "$row" >&2
      missing=1
    fi
  done < <(sed -nE "/^\\| \`[0-9a-f]{40}\` \\|/p" "$BACKLOG_DOC")
  return "$missing"
}

verify_patch_ids() {
  local repo="$1"
  local donor_count=0
  local port_count=0
  local sha

  while IFS='|' read -r sha _; do
    git -C "$repo" show "$sha" | git patch-id --stable >/dev/null
    donor_count=$((donor_count + 1))
  done < <(candidate_rows "$repo")

  while IFS= read -r sha; do
    git -C "$ROOT" show "$sha" | git patch-id --stable >/dev/null
    port_count=$((port_count + 1))
  done < <(git -C "$ROOT" log --reverse --format='%H' \
    --grep='^port(yisding):')

  [[ "$port_count" -eq 97 ]] || {
    printf 'ERROR: expected 97 yisding members, found %d\n' "$port_count" >&2
    return 1
  }
  printf 'patch-id census: donor=%d yisding=%d\n' "$donor_count" "$port_count"
}

check_backlog() {
  local repo="$1"
  local candidates documented
  candidates="$(candidate_rows "$repo" | cut -d'|' -f1)"
  documented="$(documented_shas)"

  if [[ "$candidates" != "$documented" ]]; then
    printf 'ERROR: docs/VENDOR-BACKLOG.md is not exhaustive or is out of order\n' >&2
    diff -u <(printf '%s\n' "$candidates") <(printf '%s\n' "$documented") || true
    return 1
  fi
  verify_decisions
  verify_patch_ids "$repo"
  printf 'PASS: vendor backlog rows=%d base=%s tip=%s\n' \
    "$(printf '%s\n' "$candidates" | sed '/^$/d' | wc -l)" \
    "$BASE_SHA" "$(git -C "$repo" rev-parse "$VENDOR_BRANCH")"
}

self_test() {
  local fixture
  fixture="$(mktemp -d)"
  cleanup_dir="$fixture"
  git -C "$fixture" init -q
  git -C "$fixture" config user.name Fixture
  git -C "$fixture" config user.email fixture@example.invalid
  mkdir -p "$fixture/drivers/video/rockchip/rga3"
  printf 'base\n' >"$fixture/drivers/video/rockchip/rga3/fixture.c"
  git -C "$fixture" add .
  git -C "$fixture" commit -qm base
  local base
  base="$(git -C "$fixture" rev-parse HEAD)"
  printf 'change\n' >>"$fixture/drivers/video/rockchip/rga3/fixture.c"
  git -C "$fixture" commit -qam change

  printf '| SHA | Decision |\n|---|---|\n' >"$fixture/backlog.md"
  if BASE_SHA="$base" VENDOR_BRANCH=HEAD VENDOR_REPO="$fixture" \
    BACKLOG_DOC="$fixture/backlog.md" "$0" --check >/dev/null 2>&1; then
    printf 'FAIL: an unclassified synthetic commit was accepted\n' >&2
    return 1
  fi

  local sha
  sha="$(git -C "$fixture" rev-parse HEAD)"
  printf "| SHA | Decision |\n|---|---|\n| \`%s\` | PICK |\n" "$sha" \
    >"$fixture/backlog.md"
  BASE_SHA="$base"
  VENDOR_BRANCH=HEAD
  BACKLOG_DOC="$fixture/backlog.md"
  local actual documented
  actual="$(candidate_rows "$fixture" | cut -d'|' -f1)"
  documented="$(documented_shas)"
  [[ "$actual" == "$documented" ]]
  printf 'PASS: synthetic appended commit requires a decision row\n'
}

case "${1:---check}" in
  --check)
    resolve_vendor_repo
    check_backlog "$REPO"
    ;;
  --list)
    resolve_vendor_repo
    candidate_rows "$REPO"
    ;;
  --self-test)
    self_test
    ;;
  *)
    printf 'usage: %s [--check|--list|--self-test]\n' "$0" >&2
    exit 2
    ;;
esac
