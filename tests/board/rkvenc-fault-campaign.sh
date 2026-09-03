#!/usr/bin/env bash
# Score the canonical malformed-ioctl campaign without treating its known
# harness-only final failure as a driver regression.

set -uo pipefail

readonly EXIT_FAIL=1
readonly EXIT_USAGE=2
readonly EXIT_HARDWARE_GATED=77
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HERE
readonly EXPECTATIONS="${HERE}/../expected-errno.tsv"
readonly VALID_AFTER_REASON='the BASE-only request has no PIC class, so rkvenc_task_get_format() correctly returns EINVAL before dispatch'

usage() {
	printf 'usage: %s [--self-test] [--device PATH] [--debugfs PATH]\n' "${0##*/}" >&2
}

validate_table() {
	local expected actual
	expected=$'offset-size-wrap\tEINVAL\nundersized-word\tEINVAL\nunaligned-offset\tEINVAL\nclass-overrun\tEINVAL\ninvalid-metadata\tEINVAL\ntrans-table-odd-size\tEINVAL\nbad-user-pointer\tEFAULT\nsession-allocation-failure\tENOMEM\nvalid-after-failures\tOK'
	actual=$(while IFS=$'\t' read -r name errno _; do
		[[ ${name} == case || ${name} == \#* || -z ${name} ]] && continue
		printf '%s\t%s\n' "${name}" "${errno}"
	done <"${EXPECTATIONS}")
	[[ ${actual} == "${expected}" ]]
}

score_output() {
	local output=$1 case_name
	for case_name in offset-size-wrap undersized-word unaligned-offset class-overrun \
		invalid-metadata trans-table-odd-size bad-user-pointer; do
		grep -Eq "^[[:space:]]*ok[[:space:]]+${case_name}[[:space:]]+->" <<<"${output}" || return 1
	done
	grep -Eq '^[[:space:]]*FAIL valid-after-failures: expected OK, got EINVAL \(22\)$' <<<"${output}" || return 1
	printf 'EXPECTED_RED valid-after-failures: %s\n' "${VALID_AFTER_REASON}"
}

self_test() {
	local fixture bad
	validate_table || { printf 'SELF_TEST_FAIL: canonical errno rows drifted\n' >&2; return 1; }
	fixture=$'  ok   offset-size-wrap -> EINVAL\n  ok   undersized-word -> EINVAL\n  ok   unaligned-offset -> EINVAL\n  ok   class-overrun -> EINVAL\n  ok   invalid-metadata -> EINVAL\n  ok   trans-table-odd-size -> EINVAL\n  ok   bad-user-pointer -> EFAULT\n  FAIL valid-after-failures: expected OK, got EINVAL (22)'
	score_output "${fixture}" >/dev/null || return 1
	bad=${fixture/ok   class-overrun/FAIL class-overrun}
	if score_output "${bad}" >/dev/null 2>&1; then
		printf 'SELF_TEST_FAIL: a malformed-case regression was accepted\n' >&2
		return 1
	fi
	printf 'SELF_TEST_PASS: canonical errno table and expected-red harness reason are pinned\n'
}

main() {
	local self=0 device=/dev/mpp_service debugfs=/sys/kernel/debug/rkvenc-test output rc
	while (($#)); do
		case "$1" in
			--self-test) self=1; shift ;;
			--device) (($# >= 2)) || { usage; return "${EXIT_USAGE}"; }; device=$2; shift 2 ;;
			--debugfs) (($# >= 2)) || { usage; return "${EXIT_USAGE}"; }; debugfs=$2; shift 2 ;;
			*) usage; return "${EXIT_USAGE}" ;;
		esac
	done
	((self)) && { self_test; return; }
	[[ ${CERALIVE_BOARD_TEST:-0} == 1 ]] || {
		printf 'HARDWARE_GATED: set CERALIVE_BOARD_TEST=1 on a qualified board\n' >&2
		return "${EXIT_HARDWARE_GATED}"
	}
	validate_table || { printf 'FAIL: canonical errno rows drifted\n' >&2; return "${EXIT_FAIL}"; }
	: "${RKVENC_INVALID_IOCTL_BIN:?set RKVENC_INVALID_IOCTL_BIN to the board-built harness}"
	output=$("${RKVENC_INVALID_IOCTL_BIN}" --device "${device}" --debugfs "${debugfs}" \
		--expect-table "${EXPECTATIONS}" --all-malformed 2>&1)
	rc=$?
	printf '%s\n' "${output}"
	((rc != 0)) || { printf 'FAIL: --all-malformed unexpectedly hid the expected-red case\n' >&2; return "${EXIT_FAIL}"; }
	score_output "${output}" || return "${EXIT_FAIL}"
}

main "$@"
