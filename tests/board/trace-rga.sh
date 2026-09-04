#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HARNESS_DIR}/lib/harness-lib.sh"

score_trace() {
	local trace=$1
	local line
	local request
	local scheduler
	local completed=0
	local invalid=0
	declare -A queued=()
	declare -A selected=()
	declare -A started=()
	declare -A finished=()

	while IFS= read -r line; do
		if [[ $line =~ rga_req_queued:.*request=([0-9]+) ]]; then
			[[ ${queued[${BASH_REMATCH[1]}]+present} ]] && invalid=1
			queued[${BASH_REMATCH[1]}]=1
		elif [[ $line =~ rga_core_selected:.*request=([0-9]+)[[:space:]]+scheduler=(-?[0-9]+) ]]; then
			[[ ${selected[${BASH_REMATCH[1]}]+present} ]] && invalid=1
			selected[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
		elif [[ $line =~ rga_job_started:.*scheduler=(-?[0-9]+)[[:space:]]+request=([0-9]+) ]]; then
			[[ ${started[${BASH_REMATCH[2]}]+present} ]] && invalid=1
			started[${BASH_REMATCH[2]}]=${BASH_REMATCH[1]}
		elif [[ $line =~ rga_job_done:.*scheduler=(-?[0-9]+)[[:space:]]+request=([0-9]+) ]]; then
			[[ ${finished[${BASH_REMATCH[2]}]+present} ]] && invalid=1
			finished[${BASH_REMATCH[2]}]=${BASH_REMATCH[1]}
		fi
	done <"$trace"

	if ((invalid)); then
		printf 'invalid_trace=duplicate-lifecycle-event\n'
		return "$HARNESS_FAIL"
	fi
	for request in "${!finished[@]}"; do
		[[ ${queued[$request]+present} && ${selected[$request]+present} &&
			${started[$request]+present} ]] || continue
		scheduler=${selected[$request]}
		[[ ${started[$request]} == "$scheduler" &&
			${finished[$request]} == "$scheduler" ]] || continue
		completed=$((completed + 1))
	done

	printf 'completed_requests=%d\n' "$completed"
	((completed >= 1))
}

self_test() {
	local fixture
	local tmp

	fixture="$(cd "${HARNESS_DIR}/../fixtures/telemetry" && pwd)/trace-rga.fixture"
	score_trace "$fixture" >/dev/null || {
		harness_fail_msg "complete RGA fixture did not pass"
		return "$HARNESS_FAIL"
	}
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' RETURN
	sed '/rga_job_started:/d' "$fixture" >"$tmp/missing-start"
	if score_trace "$tmp/missing-start" >/dev/null; then
		harness_fail_msg "missing started-event mutation passed"
		return "$HARNESS_FAIL"
	fi
	sed 's/rga_job_done: scheduler=2/rga_job_done: scheduler=1/' \
		"$fixture" >"$tmp/wrong-scheduler"
	if score_trace "$tmp/wrong-scheduler" >/dev/null; then
		harness_fail_msg "mismatched scheduler mutation passed"
		return "$HARNESS_FAIL"
	fi
	cp "$fixture" "$tmp/duplicate-event"
	sed -n '2p' "$fixture" >>"$tmp/duplicate-event"
	if score_trace "$tmp/duplicate-event" >/dev/null; then
		harness_fail_msg "duplicate lifecycle-event mutation passed"
		return "$HARNESS_FAIL"
	fi

	harness_verdict PASS "self-test requires one complete, scheduler-consistent RGA lifecycle"
}

run_board() {
	local tracefs=/sys/kernel/tracing
	local probe="${HARNESS_DIR}/build/probe-rga-uapi"
	local trace
	local probe_log
	local event
	local rc
	local events=(rga_req_queued rga_core_selected rga_job_started rga_job_done \
		rga_job_timeout rga_reset)

	[[ ${CERALIVE_BOARD_TEST:-0} == 1 ]] || {
		harness_verdict GATED "set CERALIVE_BOARD_TEST=1 on an island board"
		return $?
	}
	[[ -w "$tracefs/trace" ]] || {
		harness_verdict GATED "tracefs is unavailable or not writable"
		return $?
	}
	[[ -x "$probe" ]] || {
		harness_verdict GATED "build probe-rga-uapi with make -C tests/board"
		return $?
	}
	for event in "${events[@]}"; do
		[[ -w "$tracefs/events/rockchip_rga/$event/enable" ]] || {
			harness_verdict GATED "rockchip_rga/$event is unavailable"
			return $?
		}
	done

	trace=$(mktemp) || {
		harness_verdict FAIL "could not allocate a trace snapshot"
		return $?
	}
	probe_log=$(mktemp) || {
		rm -f "$trace"
		harness_verdict FAIL "could not allocate a probe log"
		return $?
	}
	trap 'for event in rga_req_queued rga_core_selected rga_job_started rga_job_done rga_job_timeout rga_reset; do printf 0 | tee "$tracefs/events/rockchip_rga/$event/enable" >/dev/null || true; done; rm -f "$trace" "$probe_log"' RETURN
	if ! printf '\n' | tee "$tracefs/trace" >/dev/null; then
		harness_verdict FAIL "could not clear the trace buffer"
		return $?
	fi
	for event in "${events[@]}"; do
		if ! printf 1 | tee "$tracefs/events/rockchip_rga/$event/enable" >/dev/null; then
			harness_verdict FAIL "could not enable rockchip_rga/$event"
			return $?
		fi
	done

	"$probe" >"$probe_log" 2>&1
	rc=$?
	while IFS= read -r line; do
		printf 'probe: %s\n' "$line"
	done <"$probe_log"
	if ((rc == HARNESS_GATED)); then
		harness_verdict GATED "probe-rga-uapi could not reach island RGA hardware"
		return $?
	fi
	if ((rc)); then
		harness_verdict FAIL "probe-rga-uapi failed"
		return $?
	fi
	if ! cp "$tracefs/trace" "$trace"; then
		harness_verdict FAIL "could not snapshot the trace buffer"
		return $?
	fi
	if ! score_trace "$trace"; then
		harness_verdict FAIL "RGA blit did not emit a complete lifecycle"
		return $?
	fi
	harness_verdict PASS "RGA blit emitted queued, selected, started, and completed events"
}

case ${1:-} in
--self-test) self_test ;;
"") run_board ;;
*)
	printf 'usage: %s [--self-test]\n' "$0" >&2
	exit "$HARNESS_USAGE"
	;;
esac
