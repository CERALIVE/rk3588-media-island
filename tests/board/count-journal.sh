#!/usr/bin/env bash
#
# count-journal.sh — the d2/d4 journal counters, generalised.
#
# WHERE THIS COMES FROM. gstreamer-rockchip's board drills already count two
# journal patterns in a measured window and fail the drill when either is
# non-zero:
#
#   gstreamer-rockchip/tests/board/d2-radxa-fork-ab.sh:45-48
#   gstreamer-rockchip/tests/board/d4-allocation-soak.sh:162-169
#       since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
#       rga_blit=$(journal_count "$since" 'RGA_BLIT fail')
#       rga_api=$(journal_count "$since" 'rga_api version')
#       [[ "$rga_blit" -eq 0 && "$rga_api" -eq 0 ]] || failed=1
#
# Those two patterns are hardcoded, the budget is always zero, and the window
# is always "since the drill started". Phase 0 needs the same idea with three
# things generalised: an arbitrary pattern set, a per-pattern BUDGET rather
# than an implicit zero, and the ability to count a captured log file so a
# measurement can be re-scored later without the board.
#
# WHY A BUDGET AND NOT A BOOLEAN. `rga_api version` is printed once per process
# on librga's first use, so "zero" is the right budget for a drill that must
# never enter librga — but a baseline measurement of the CURRENT stack expects
# a non-zero count and must record it rather than fail on it. A counter that
# can only assert zero cannot measure a baseline.
#
# NON-VACUITY IS THE POINT. A counter that silently returns 0 for everything
# looks green forever. --self-test therefore scores BOTH directions against
# committed fixtures: a clean log must report zero, and a log carrying real
# `RGA_BLIT fail` lines must report the exact count AND exit non-zero under a
# zero budget.
#
# READ-ONLY. Reads the journal (privileged READ via sudo -S when run against a
# board) or a file. Changes nothing.
#
# Usage:
#   count-journal.sh --log FILE [--pattern P]... [--expect 'P=MAX']...
#   count-journal.sh --board  [--since TS] [--pattern P]... [--expect 'P=MAX']...
#   count-journal.sh --self-test
#
#   --pattern P     count fixed-string P (repeatable). Default set below.
#   --expect 'P=N'  fail if P occurs more than N times (repeatable).
#   --since TS      journal window start; default: boot.
#
# Board mode needs CERALIVE_BOARD_TEST=1 plus BOARD_IP / BOARD_SSH_USER /
# BOARD_SSH_PASS, and exits 77 without them — an uncounted window is never a
# pass.
#
# Exit: 0 counted and every budget held, 1 a budget was exceeded, 2 usage,
#       77 board mode without a reachable board.

set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness-lib.sh
. "${HARNESS_DIR}/lib/harness-lib.sh"

# The Phase-0 default pattern set. Every one of these is a copy-census or
# encoder-health signal named by todo 3(b):
#   RGA_BLIT fail          librga's blit was refused -> a software copy followed
#   rga_api version        librga was ENTERED AT ALL (printed once per process)
#   gst_video_frame_copy   the plugin's software frame copy fallback
#   rkvenc                 any encoder driver line (faults, resets, timeouts)
#   RGA_MMU                the 32-bit RGA2 MMU refusing memory above 4 GiB
DEFAULT_PATTERNS=(
  'RGA_BLIT fail'
  'rga_api version'
  'gst_video_frame_copy'
  'rkvenc'
  'RGA_MMU'
)

MODE=
LOG_FILE=
SINCE=
declare -a PATTERNS=()
declare -a EXPECTS=()

# count_in_file <file> <pattern> — fixed-string count, never a regex, so a
# pattern containing a metacharacter counts what it says.
count_in_file() {
  local file=$1 pattern=$2
  grep -cF -- "${pattern}" "${file}" 2>/dev/null || true
}

# fetch_board_journal <dest> — a privileged READ of the journal window.
fetch_board_journal() {
  local dest=$1 since=$2 payload
  if [ -n "${since}" ]; then
    payload="journalctl --since '${since}' --no-pager -o cat"
  else
    payload="journalctl --boot --no-pager -o cat"
  fi
  board_run_sudo "${payload}" >"${dest}"
}

# score <file> — count every pattern, apply every budget, print one row each.
score() {
  local file=$1 pattern count budget spec failed=0

  for pattern in "${PATTERNS[@]}"; do
    count=$(count_in_file "${file}" "${pattern}")
    printf 'count pattern=%q occurrences=%s\n' "${pattern}" "${count}"
  done

  for spec in ${EXPECTS[@]+"${EXPECTS[@]}"}; do
    pattern=${spec%=*}
    budget=${spec##*=}
    case "${budget}" in '' | *[!0-9]*)
      harness_fail_msg "--expect budget must be an integer: ${spec}"
      return "${HARNESS_USAGE}"
      ;;
    esac
    count=$(count_in_file "${file}" "${pattern}")
    if [ "${count}" -gt "${budget}" ]; then
      printf 'BUDGET-EXCEEDED pattern=%q occurrences=%s budget=%s\n' \
        "${pattern}" "${count}" "${budget}"
      failed=1
    else
      printf 'budget-ok pattern=%q occurrences=%s budget=%s\n' \
        "${pattern}" "${count}" "${budget}"
    fi
  done

  return "${failed}"
}

self_test() {
  local fixtures clean dirty rc=0 count out

  fixtures="$(harness_fixtures_dir)" || {
    harness_fail_msg "fixture tree not found"
    return "${HARNESS_FAIL}"
  }
  clean="${fixtures}/journal/clean.log"
  dirty="${fixtures}/journal/rga-blit-fail.log"
  if ! [ -r "${clean}" ] || ! [ -r "${dirty}" ]; then
    harness_fail_msg "journal fixtures missing under ${fixtures}/journal"
    return "${HARNESS_FAIL}"
  fi

  printf 'self_test=count-journal\n'
  PATTERNS=("${DEFAULT_PATTERNS[@]}")

  # --- direction 1: a clean window must report zero for the copy signals ---
  EXPECTS=('RGA_BLIT fail=0' 'rga_api version=0' 'gst_video_frame_copy=0')
  printf -- '--- clean fixture ---\n'
  if ! out=$(score "${clean}"); then
    printf '%s\n' "${out}"
    harness_fail_msg "the clean fixture tripped a zero budget"
    rc=1
  else
    printf '%s\n' "${out}"
  fi

  # --- direction 2: a dirty window must report the EXACT count and fail ----
  printf -- '--- rga-blit-fail fixture ---\n'
  count=$(count_in_file "${dirty}" 'RGA_BLIT fail')
  if [ "${count}" -ne 5 ]; then
    harness_fail_msg "expected 5 'RGA_BLIT fail' lines in the fixture, counted ${count}"
    rc=1
  fi
  if out=$(score "${dirty}"); then
    printf '%s\n' "${out}"
    harness_fail_msg "the dirty fixture did NOT trip a zero budget; the counter is vacuous"
    rc=1
  else
    printf '%s\n' "${out}"
    printf 'non_vacuity=ok dirty fixture reported %s and exited non-zero\n' "${count}"
  fi

  # --- direction 3: a budget that accommodates the count must pass ---------
  EXPECTS=('RGA_BLIT fail=5')
  if out=$(score "${dirty}"); then
    printf '%s\n' "${out}"
    printf 'budget_semantics=ok a budget of 5 accepts exactly 5 occurrences\n'
  else
    printf '%s\n' "${out}"
    harness_fail_msg "a budget equal to the count was rejected"
    rc=1
  fi

  [ "${rc}" -eq 0 ] || {
    harness_verdict FAIL "self-test"
    return $?
  }
  harness_verdict PASS "self-test: clean=0, dirty counted and failed closed"
}

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --self-test)
        self_test
        exit $?
        ;;
      --log)
        MODE=log
        LOG_FILE=${2:-}
        shift 2
        ;;
      --board)
        MODE=board
        shift
        ;;
      --since)
        SINCE=${2:-}
        shift 2
        ;;
      --pattern)
        PATTERNS+=("${2:-}")
        shift 2
        ;;
      --expect)
        EXPECTS+=("${2:-}")
        shift 2
        ;;
      -h | --help)
        usage
        exit "${HARNESS_USAGE}"
        ;;
      *)
        harness_fail_msg "unknown argument: $1"
        usage
        exit "${HARNESS_USAGE}"
        ;;
    esac
  done

  [ "${#PATTERNS[@]}" -gt 0 ] || PATTERNS=("${DEFAULT_PATTERNS[@]}")

  case "${MODE}" in
    log)
      [ -r "${LOG_FILE}" ] || {
        harness_fail_msg "--log file not readable: ${LOG_FILE}"
        exit "${HARNESS_USAGE}"
      }
      printf 'source=file path=%s\n' "${LOG_FILE}"
      score "${LOG_FILE}"
      local rc=$?
      [ "${rc}" -eq 0 ] || {
        harness_verdict FAIL "a budget was exceeded"
        exit $?
      }
      harness_verdict PASS "every budget held"
      exit $?
      ;;
    board)
      board_available || {
        harness_verdict GATED "board mode needs CERALIVE_BOARD_TEST=1 and BOARD_IP/BOARD_SSH_USER/BOARD_SSH_PASS"
        exit $?
      }
      local tmp
      tmp="$(mktemp)" || exit "${HARNESS_FAIL}"
      # shellcheck disable=SC2064
      trap "rm -f '${tmp}'" EXIT
      printf 'source=board host=%s since=%s\n' "${BOARD_IP}" "${SINCE:-boot}"
      fetch_board_journal "${tmp}" "${SINCE}" || {
        harness_fail_msg "could not read the board journal"
        harness_verdict FAIL "journal unavailable"
        exit $?
      }
      printf 'journal_lines=%s\n' "$(wc -l <"${tmp}")"
      score "${tmp}"
      local rc=$?
      [ "${rc}" -eq 0 ] || {
        harness_verdict FAIL "a budget was exceeded"
        exit $?
      }
      harness_verdict PASS "every budget held"
      exit $?
      ;;
    *)
      harness_fail_msg "one of --log, --board or --self-test is required"
      usage
      exit "${HARNESS_USAGE}"
      ;;
  esac
}

main "$@"
