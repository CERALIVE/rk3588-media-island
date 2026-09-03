#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HARNESS_DIR}/lib/harness-lib.sh"

score_trace() {
	local trace=$1
	local line
	local task
	local core
	local cores
	local completed=0
	local invalid=0
	declare -A queued=()
	declare -A selected=()
	declare -A started=()
	declare -A finished=()
	declare -A completed_cores=()

	while IFS= read -r line; do
		if [[ $line =~ mpp_task_queued:.*session=[0-9]+[[:space:]]+task=([0-9]+) ]]; then
			[[ ${queued[${BASH_REMATCH[1]}]+present} ]] && invalid=1
			queued[${BASH_REMATCH[1]}]=1
		elif [[ $line =~ mpp_core_selected:.*task=([0-9]+)[[:space:]]+core=(-?[0-9]+) ]]; then
			[[ ${selected[${BASH_REMATCH[1]}]+present} ]] && invalid=1
			selected[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
		elif [[ $line =~ mpp_task_started:.*core=(-?[0-9]+)[[:space:]]+task=([0-9]+) ]]; then
			[[ ${started[${BASH_REMATCH[2]}]+present} ]] && invalid=1
			started[${BASH_REMATCH[2]}]=${BASH_REMATCH[1]}
		elif [[ $line =~ mpp_task_done:.*core=(-?[0-9]+)[[:space:]]+task=([0-9]+) ]]; then
			[[ ${finished[${BASH_REMATCH[2]}]+present} ]] && invalid=1
			finished[${BASH_REMATCH[2]}]=${BASH_REMATCH[1]}
		fi
	done <"$trace"
	if ((invalid)); then
		printf 'invalid_trace=duplicate-lifecycle-event\n'
		return "$HARNESS_FAIL"
	fi

	for task in "${!finished[@]}"; do
		[[ ${queued[$task]+present} && ${selected[$task]+present} &&
			${started[$task]+present} ]] || continue
		core=${selected[$task]}
		[[ ${started[$task]} == "$core" && ${finished[$task]} == "$core" ]] || continue
		completed_cores[$core]=1
		completed=$((completed + 1))
	done
	cores=$(printf '%s\n' "${!completed_cores[@]}" | sort -n | tr '\n' ',')
	cores=${cores%,}
	printf 'completed_cores=%s completed_tasks=%s\n' "$cores" "$completed"

	((completed >= 2 && ${#completed_cores[@]} >= 2))
}

self_test() {
	local fixture
	local tmp

	fixture="$(cd "${HARNESS_DIR}/../fixtures/telemetry" && pwd)/trace-dual-core.fixture"
	score_trace "$fixture" >/dev/null || {
		harness_fail_msg "two-core fixture did not pass"
		return "$HARNESS_FAIL"
	}
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' RETURN
	sed '/core=1/d' "$fixture" >"$tmp/one-core"
	if score_trace "$tmp/one-core" >/dev/null; then
		harness_fail_msg "single-core mutation passed"
		return "$HARNESS_FAIL"
	fi
	sed 's/mpp_task_done: core=1 task=42/mpp_task_done: core=0 task=42/' \
		"$fixture" >"$tmp/wrong-core"
	if score_trace "$tmp/wrong-core" >/dev/null; then
		harness_fail_msg "mismatched completion-core mutation passed"
		return "$HARNESS_FAIL"
	fi
	sed '/mpp_task_queued: session=4 task=42/d' "$fixture" >"$tmp/missing-queue"
	if score_trace "$tmp/missing-queue" >/dev/null; then
		harness_fail_msg "missing queued-event mutation passed"
		return "$HARNESS_FAIL"
	fi
	cp "$fixture" "$tmp/duplicate-event"
	sed -n '2p' "$fixture" >>"$tmp/duplicate-event"
	if score_trace "$tmp/duplicate-event" >/dev/null; then
		harness_fail_msg "duplicate lifecycle-event mutation passed"
		return "$HARNESS_FAIL"
	fi

	harness_verdict PASS "self-test requires two complete, core-consistent task lifecycles"
}

run_board() {
	local tracefs=/sys/kernel/tracing
	local trace
	local pids=()
	local i
	local rc=0

	[[ ${CERALIVE_BOARD_TEST:-0} == 1 ]] || {
		harness_verdict GATED "set CERALIVE_BOARD_TEST=1 on an island board"
		return $?
	}
	[[ -w "$tracefs/trace" ]] || {
		harness_verdict GATED "tracefs is unavailable or not writable"
		return $?
	}
	command -v gst-launch-1.0 >/dev/null || {
		harness_verdict GATED "gst-launch-1.0 is unavailable"
		return $?
	}
	for event in mpp_task_queued mpp_core_selected mpp_task_started mpp_task_done \
		mpp_task_error mpp_reset; do
		[[ -w "$tracefs/events/rockchip_mpp/$event/enable" ]] || {
			harness_verdict GATED "rockchip_mpp/$event is unavailable"
			return $?
		}
	done

	trace=$(mktemp) || {
		harness_verdict FAIL "could not allocate a trace snapshot"
		return $?
	}
	trap 'for event in mpp_task_queued mpp_core_selected mpp_task_started mpp_task_done mpp_task_error mpp_reset; do printf 0 | tee "$tracefs/events/rockchip_mpp/$event/enable" >/dev/null || true; done; rm -f "$trace"' RETURN
	if ! printf '\n' | tee "$tracefs/trace" >/dev/null; then
		harness_verdict FAIL "could not clear the trace buffer"
		return $?
	fi
	for event in mpp_task_queued mpp_core_selected mpp_task_started mpp_task_done \
		mpp_task_error mpp_reset; do
		if ! printf 1 | tee "$tracefs/events/rockchip_mpp/$event/enable" >/dev/null; then
			harness_verdict FAIL "could not enable rockchip_mpp/$event"
			return $?
		fi
	done

	for i in 1 2; do
		gst-launch-1.0 -q -e videotestsrc num-buffers=180 \
			! video/x-raw,format=NV12,width=3840,height=2160,framerate=30/1 \
			! mpph265enc ! fakesink sync=false &
		pids+=("$!")
	done
	for i in "${pids[@]}"; do
		wait "$i" || rc=1
	done
	if ! cp "$tracefs/trace" "$trace"; then
		harness_verdict FAIL "could not snapshot the trace buffer"
		return $?
	fi
	if ((rc)) || ! score_trace "$trace"; then
		harness_verdict FAIL "two concurrent encodes did not complete on two cores"
		return $?
	fi
	harness_verdict PASS "two concurrent encodes emitted completed work on two cores"
}

case ${1:-} in
--self-test) self_test ;;
"") run_board ;;
*)
	printf 'usage: %s [--self-test]\n' "$0" >&2
	exit "$HARNESS_USAGE"
	;;
esac
