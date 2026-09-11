#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -uo pipefail

readonly FAIL=1 USAGE=2 GATED=77
readonly MPP_DEBUG=/sys/kernel/debug/rockchip-mpp
readonly FAULT_DEBUG=/sys/kernel/debug/rkvenc-test
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly HERE
readonly ROWS=(invalid-descriptor malformed-ioctls invalid-dimensions unsupported-format
	dmabuf-vanishing sigkill-mid-encode gstreamer-crash irq-timeout iommu-fault
	hardware-hang reset-failure teardown-active concurrent-destruction rapid-cycles
	concurrent-destroy-loops libmpp-4k5994-h265)
readonly RGA_ROWS=(rga-irq-timeout rga-iommu-fault rga-hardware-hang rga-reset-failure)

# The exact debugfs entry set the fault seam publishes: eight one-shot knobs,
# their eight consumed counters, the selector and the delay pair. Held as ONE
# array so scripts/check-fault-seam-contract.sh can read it as data rather than
# re-deriving the list and agreeing with itself.
readonly FAULT_SEAM_ENTRIES=(
	delay_consumed
	delay_task_completion_ms
	fail_ccu_attach_once
	fail_ccu_attach_once_consumed
	fail_clock_enable_once
	fail_clock_enable_once_consumed
	fail_irq_request_once
	fail_irq_request_once_consumed
	fail_reset_once
	fail_reset_once_consumed
	fail_service_attach_once
	fail_service_attach_once_consumed
	fail_session_alloc_once
	fail_session_alloc_once_consumed
	hang_task_once
	hang_task_once_consumed
	inject_iommu_fault_once
	inject_iommu_fault_once_consumed
	target_session_pid
)
readonly FAULT_SEAM_IDLE=(inject_iommu_fault_idle_ms inject_iommu_fault_idle_consumed
	inject_iommu_fault_idle_fired inject_iommu_fault_idle_state)

# A journal line matching this set means the kernel's state is no longer
# trustworthy evidence, so the campaign stops. It is a strict subset of the
# per-row bad-line screen below: a lone WARNING: fails its row without
# condemning every row after it.
readonly FATAL_SIGNATURES='KASAN:|BUG:|Oops|possible recursive locking|inconsistent lock state'
readonly JOURNAL_BAD_SIGNATURES='WARNING:|BUG:|KASAN:|possible recursive locking|inconsistent lock state|Oops'

OUT=
ROW=all
PROBE_MPP=
PROBE_RGA=
INVALID_IOCTL=
HEALTHY_PID=
HEALTHY_LOG=
IDLE_BASELINE=
ROW_SINCE=0

DRIVER=auto
SESSIONS_DIR=
PROBE_EXPECT=()
REQUIRED_CONFIGS=()
FATAL=

# healthy_stop deadlines, in 0.1 s polls: 15 s after TERM, 5 s after KILL.
# Not readonly so --self-test can shorten them; nothing else writes them.
HEALTHY_TERM_POLLS=150
HEALTHY_KILL_POLLS=50
HEALTHY_WEDGED=

SCORE_GAPS=
SCORE_REASON=
SCORE_RESET_DELTA=
SCORE_FPS=

usage() {
	printf 'usage: %s [--out DIR] [--row NAME|all] [--probe-mpp FILE] [--invalid-ioctl FILE]\n' "$0" >&2
	printf '       %*s [--driver island|auto|island-rga] [--probe-rga FILE]\n' "${#0}" '' >&2
	printf '       %s --self-test\n' "$0" >&2
}

select_driver() {
	case "$DRIVER" in
	island) ;;
	auto) [[ -d $MPP_DEBUG ]] || { printf 'matrix verdict=GATED reason=no-island-telemetry\n'; return "$GATED"; } ;;
	*) usage; return "$USAGE" ;;
	esac
	DRIVER=island
	SESSIONS_DIR="$MPP_DEBUG/sessions"
	PROBE_EXPECT=(--expect-island)
	REQUIRED_CONFIGS=(CONFIG_KASAN=y CONFIG_PROVE_LOCKING=y
		CONFIG_ROCKCHIP_MPP_CERALIVE_TEST=y)
}

require_configs() {
	local cfg
	for cfg in "${REQUIRED_CONFIGS[@]}"; do
		zgrep -qx "$cfg" /proc/config.gz || return "$GATED"
	done
}

# seam_inventory — the fault root must publish exactly the expected set. A
# missing knob would otherwise surface as a row that quietly never armed.
seam_inventory() {
	local expected actual
	expected=$({
		printf '%s\n' "${FAULT_SEAM_ENTRIES[@]}"
		if [[ -e $FAULT_DEBUG/inject_iommu_fault_idle_ms ]]; then
			printf '%s\n' "${FAULT_SEAM_IDLE[@]}"
		fi
	} | LC_ALL=C sort)
	actual=$(find "$FAULT_DEBUG" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | LC_ALL=C sort)
	[[ $expected == "$actual" ]]
}

snapshot_island() {
	local dest=$1 core metric counter
	{
		for core in "$MPP_DEBUG"/cores/*; do
			[[ -d $core ]] || continue
			for metric in busy busy_ns tasks errors resets; do
				[[ -r $core/$metric ]] || return "$GATED"
				printf '%s %s %s\n' "$(basename "$core")" "$metric" "$(<"$core/$metric")"
			done
		done
		printf 'global queue_depth %s\n' "$(<"$MPP_DEBUG/queue_depth")"
		printf 'global dmabufs %s\n' "$(awk '/^Total [0-9]+ objects/{print $2}' /sys/kernel/debug/dma_buf/bufinfo)"
		printf 'global iommu_maps %s\n' "$(grep -c '^ *[0-9][0-9]*: 0x' /proc/mpp_service/sessions-summary || true)"
		for counter in "$FAULT_DEBUG"/*consumed; do
			[[ -r $counter ]] && printf 'fault %s %s\n' "$(basename "$counter")" "$(<"$counter")"
		done
	} >"$dest"
}

snapshot() { snapshot_island "$1"; }

metric_sum() {
	awk -v metric="$2" '$2==metric{sum+=$3}END{print sum+0}' "$1"
}

global_metric() {
	awk -v metric="$2" '$1=="global"&&$2==metric{print $3}' "$1"
}

# metric_gap — the GAP label for a metric this profile cannot report, or
# nothing. Any row carrying one gaps the whole metric out; a partially
# reported metric would be worse than an unreported one.
metric_gap() {
	awk -v metric="$2" '$2==metric && $3 ~ /^GAP:/ {print $3; exit}' "$1"
}

gap_add() {
	SCORE_GAPS=${SCORE_GAPS:+$SCORE_GAPS,}$1
}

# field_state — the verdict line reports what was actually asserted. A metric
# that gapped out reads `gap`, never the literal that claims it was checked.
field_state() {
	case ",$SCORE_GAPS," in
	*",$1=GAP:"*) printf 'gap' ;;
	*) printf '%s' "$2" ;;
	esac
}

frames() {
	grep -c 'last-message = chain' "$HEALTHY_LOG" 2>/dev/null || true
}

sample_fps() {
	local before after
	before=$(frames)
	sleep 5
	after=$(frames)
	awk -v n="$((after - before))" 'BEGIN{printf "%.3f",n/5}'
}

healthy_start() {
	HEALTHY_LOG="$OUT/healthy-$1.log"
	gst-launch-1.0 -v videotestsrc is-live=true pattern=smpte \
		! video/x-raw,format=NV12,width=1920,height=1080,framerate=30/1 \
		! queue max-size-buffers=4 leaky=downstream ! mpph264enc \
		! identity silent=false ! fakesink sync=false >"$HEALTHY_LOG" 2>&1 &
	HEALTHY_PID=$!
	HEALTHY_WEDGED=
	sleep 3
	kill -0 "$HEALTHY_PID" 2>/dev/null
}

# healthy_stop — PARENT-OWNED reaping, deliberately without a subprocess around
# `wait`. The competing encode is this shell's child, so a `wait` wrapped in an
# external `timeout` runs in a process that does not own it: that wrapper
# returns 0 while the child is still alive, which reads as a clean stop and is
# not one.
#
# Aliveness is therefore decided by kill -0 BEFORE any wait. An unreapable
# child would block `wait` forever, so on that branch the function never calls
# it: it reports the wedge, RETAINS HEALTHY_PID so the trap and the operator
# can still see the process, and returns non-zero.
healthy_stop() {
	local pid=${HEALTHY_PID:-} i
	[[ -n $pid ]] || return 0
	[[ $HEALTHY_WEDGED == "$pid" ]] && return "$FAIL"

	kill -TERM "$pid" 2>/dev/null || true
	for ((i = 0; i < HEALTHY_TERM_POLLS; i++)); do
		kill -0 "$pid" 2>/dev/null || break
		sleep 0.1
	done
	if kill -0 "$pid" 2>/dev/null; then
		kill -KILL "$pid" 2>/dev/null || true
		for ((i = 0; i < HEALTHY_KILL_POLLS; i++)); do
			kill -0 "$pid" 2>/dev/null || break
			sleep 0.1
		done
	fi
	if kill -0 "$pid" 2>/dev/null; then
		HEALTHY_WEDGED=$pid
		printf 'healthy-wedge pid=%s\n' "$pid"
		return "$FAIL"
	fi

	wait "$pid" 2>/dev/null || true
	HEALTHY_PID=
}

fault_pipeline() {
	gst-launch-1.0 -v videotestsrc is-live=true pattern=ball \
		! video/x-raw,format=NV12,width=1280,height=720,framerate=30/1 \
		! mpph264enc ! identity silent=false ! fakesink sync=false
}

fault_pipeline_timeout() {
	timeout 10 gst-launch-1.0 -v videotestsrc is-live=true pattern=ball \
		! video/x-raw,format=NV12,width=1280,height=720,framerate=30/1 \
		! mpph264enc ! identity silent=false ! fakesink sync=false
}

wait_frames_then_signal() {
	local signal=$1 log=$2 pid i
	(
		exec gst-launch-1.0 -v videotestsrc is-live=true pattern=ball \
			! video/x-raw,format=NV12,width=1280,height=720,framerate=30/1 \
			! mpph264enc ! identity silent=false ! fakesink sync=false
	) >"$log" 2>&1 & pid=$!
	for i in $(seq 1 100); do
		(( $(grep -c 'last-message = chain' "$log" 2>/dev/null || true) >= 100 )) && break
		sleep 0.05
	done
	kill "-$signal" "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
}

arm() {
	printf '%s\n' "$2" >"$FAULT_DEBUG/$1"
}

targeted_fault() {
	local knob=$1 log=$2 pid session_pid='' i tid
	(
		exec gst-launch-1.0 -v videotestsrc is-live=true pattern=ball \
			! video/x-raw,format=NV12,width=1280,height=720,framerate=30/1 \
			! mpph264enc ! identity silent=false ! fakesink sync=false
	) >"$log" 2>&1 & pid=$!
	for i in $(seq 1 100); do
		for tid in /proc/"$pid"/task/*; do
			[[ -d $tid ]] || continue
			set -- "$SESSIONS_DIR"/"${tid##*/}"-*
			[[ -d $1 ]] && { session_pid=${tid##*/}; break 2; }
		done
		sleep 0.05
	done
	[[ -n $session_pid ]] || { kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; return "$GATED"; }
	arm target_session_pid "$session_pid"
	arm "$knob" 1
	sleep 5
	kill -TERM "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
}

stimulate() {
	local name=$1 i a b rc=0
	case "$name" in
	invalid-descriptor|malformed-ioctls)
		CERALIVE_BOARD_TEST=1 RKVENC_INVALID_IOCTL_BIN="$INVALID_IOCTL" \
			"$HERE/rkvenc-fault-campaign.sh" --device /dev/mpp_service --debugfs "$FAULT_DEBUG" >"$OUT/$name.stimulus" 2>&1 || rc=$?
		((rc == 0)) || return "$FAIL"
		;;
	invalid-dimensions)
		if gst-launch-1.0 videotestsrc num-buffers=1 ! video/x-raw,format=NV12,width=0,height=1080 ! mpph264enc ! fakesink >"$OUT/$name.stimulus" 2>&1; then return "$FAIL"; fi
		grep -Eq 'invalid|not negotiated|could not link' "$OUT/$name.stimulus" || return "$FAIL"
		;;
	unsupported-format)
		if gst-launch-1.0 videotestsrc num-buffers=1 ! video/x-raw,format=GRAY8,width=1280,height=720 ! mpph264enc ! fakesink >"$OUT/$name.stimulus" 2>&1; then return "$FAIL"; fi
		grep -Eq 'not negotiated|could not link' "$OUT/$name.stimulus" || return "$FAIL"
		;;
	dmabuf-vanishing) arm delay_task_completion_ms 1000; wait_frames_then_signal KILL "$OUT/$name.stimulus" ;;
	sigkill-mid-encode) wait_frames_then_signal KILL "$OUT/$name.stimulus" ;;
	gstreamer-crash)
		systemctl is-active --quiet cerastream || return "$GATED"
		systemctl kill --signal=SEGV cerastream >"$OUT/$name.stimulus" 2>&1 || return "$FAIL"
		for i in $(seq 1 100); do
			systemctl is-active --quiet cerastream && break
			sleep 0.1
		done
		systemctl is-active --quiet cerastream || return "$FAIL"
		;;
	irq-timeout|hardware-hang)
		targeted_fault hang_task_once "$OUT/$name.stimulus"
		;;
	iommu-fault)
		targeted_fault inject_iommu_fault_once "$OUT/$name.stimulus"
		;;
	reset-failure)
		arm fail_reset_once 1
		targeted_fault hang_task_once "$OUT/$name.stimulus"
		;;
	teardown-active) arm delay_task_completion_ms 1000; wait_frames_then_signal TERM "$OUT/$name.stimulus" ;;
	concurrent-destruction)
		gst-launch-1.0 -v \
			videotestsrc is-live=true pattern=ball ! video/x-raw,format=NV12,width=1280,height=720,framerate=30/1 ! mpph264enc ! fakesink sync=false \
			videotestsrc is-live=true pattern=snow ! video/x-raw,format=NV12,width=1280,height=720,framerate=30/1 ! mpph264enc ! fakesink sync=false >"$OUT/$name.stimulus" 2>&1 & a=$!
		sleep 3
		kill -0 "$a" 2>/dev/null || return "$FAIL"
		kill -KILL "$a" 2>/dev/null || true; wait "$a" 2>/dev/null || true
		;;
	rapid-cycles)
		for i in $(seq 1 200); do gst-launch-1.0 -q videotestsrc num-buffers=1 ! video/x-raw,format=NV12,width=320,height=240 ! mpph264enc ! fakesink || return "$FAIL"; done >"$OUT/$name.stimulus" 2>&1
		;;
	concurrent-destroy-loops)
		(for ((i=0; i<50; i++)); do gst-launch-1.0 -q videotestsrc num-buffers=1 ! video/x-raw,format=NV12,width=320,height=240 ! mpph264enc ! fakesink || exit 1; done) >"$OUT/$name-a.stimulus" 2>&1 & a=$!
		(for ((i=0; i<50; i++)); do gst-launch-1.0 -q videotestsrc num-buffers=1 ! video/x-raw,format=NV12,width=320,height=240 ! mpph264enc ! fakesink || exit 1; done) >"$OUT/$name-b.stimulus" 2>&1 & b=$!
		wait "$a"; rc=$?; wait "$b" || rc=$?; ((rc == 0))
		;;
	libmpp-4k5994-h265)
		timeout 15 gst-launch-1.0 -v videotestsrc num-buffers=5 ! video/x-raw,format=NV12,width=3840,height=2160,framerate=60000/1001 ! mpph265enc ! identity silent=false ! fakesink >"$OUT/$name.stimulus" 2>&1
		rc=$?
		if ((rc == 0)); then
			(( $(grep -c 'last-message = chain' "$OUT/$name.stimulus") == 5 )) || return "$FAIL"
			printf 'classification=accepted-hal-survived\n' >>"$OUT/$name.stimulus"
		elif ((rc == 1)) && grep -Eq 'Invalid argument|EINVAL|errno 22' "$OUT/$name.stimulus" && ! grep -Eq 'Segmentation fault|dumped core' "$OUT/$name.stimulus"; then
			printf 'classification=typed-einval-hal-survived\n' >>"$OUT/$name.stimulus"
		else
			return "$FAIL"
		fi
		;;
	*) return "$USAGE" ;;
	esac
}

# snapshot_quiesced — the settle predicate the recovery loop polls on. It never
# writes SCORE_*; score_snapshots is the one that records a verdict.
snapshot_quiesced() {
	local after=$1 baseline=$2
	[[ -n $(metric_gap "$after" queue_depth) || $(global_metric "$after" queue_depth) == 0 ]] || return 1
	[[ -n $(metric_gap "$after" busy) || $(metric_sum "$after" busy) == 0 ]] || return 1
	[[ -n $(metric_gap "$after" dmabufs) || $(global_metric "$baseline" dmabufs) == "$(global_metric "$after" dmabufs)" ]] || return 1
	[[ -n $(metric_gap "$after" iommu_maps) || $(global_metric "$baseline" iommu_maps) == "$(global_metric "$after" iommu_maps)" ]] || return 1
}

# score_snapshots — the whole recovery verdict as a pure function of four
# files, so --self-test can score committed fixtures in both directions with no
# board and no hardware. An assertion whose metric is GAP on the active profile
# is neither passed nor failed: it joins SCORE_GAPS and is reported.
#
# The metric assertion lines retain their board-tested form, third parameter
# named IDLE_BASELINE and all. That is why they sit
# at the outer indent inside their guards, and why SCORE_REASON is set ahead of
# each rather than inside its failure branch: an extraction that rewrites the
# assertions cannot prove it did not also weaken one.
score_snapshots() {
	local before=$1 after=$2 IDLE_BASELINE=$3 journal=$4 name=$5
	local gap reset_delta counter before_count after_count

	SCORE_GAPS=
	SCORE_REASON=recovery-assertion
	SCORE_RESET_DELTA=

	gap=$(metric_gap "$after" queue_depth)
	if [[ -n $gap ]]; then gap_add "queue_depth=$gap"; else SCORE_REASON=queue-depth
	[[ $(awk '$1=="global"&&$2=="queue_depth"{print $3}' "$after") == 0 ]] || return "$FAIL"
	fi

	gap=$(metric_gap "$after" busy)
	if [[ -n $gap ]]; then gap_add "busy=$gap"; else SCORE_REASON=busy
	[[ $(metric_sum "$after" busy) == 0 ]] || return "$FAIL"
	fi

	gap=$(metric_gap "$after" dmabufs)
	[[ -n $gap ]] || gap=$(metric_gap "$IDLE_BASELINE" dmabufs)
	if [[ -n $gap ]]; then gap_add "dmabufs=$gap"; else SCORE_REASON=dmabufs
	[[ $(awk '$1=="global"&&$2=="dmabufs"{print $3}' "$IDLE_BASELINE") == $(awk '$1=="global"&&$2=="dmabufs"{print $3}' "$after") ]] || return "$FAIL"
	fi

	gap=$(metric_gap "$after" iommu_maps)
	[[ -n $gap ]] || gap=$(metric_gap "$IDLE_BASELINE" iommu_maps)
	if [[ -n $gap ]]; then gap_add "iommu_maps=$gap"; else SCORE_REASON=iommu_maps
	[[ $(awk '$1=="global"&&$2=="iommu_maps"{print $3}' "$IDLE_BASELINE") == $(awk '$1=="global"&&$2=="iommu_maps"{print $3}' "$after") ]] || return "$FAIL"
	fi

	journal_clean "$journal" || return "$FAIL"

	gap=$(metric_gap "$after" resets)
	[[ -n $gap ]] || gap=$(metric_gap "$before" resets)
	if [[ -n $gap ]]; then gap_add "resets=$gap"; SCORE_RESET_DELTA=gap; else
	reset_delta=$(( $(metric_sum "$after" resets) - $(metric_sum "$before" resets) ))
	SCORE_RESET_DELTA=$reset_delta; SCORE_REASON=reset-delta
	case "$name" in
	irq-timeout|iommu-fault|hardware-hang|reset-failure|rga-irq-timeout|rga-iommu-fault|rga-hardware-hang) ((reset_delta >= 1)) || return "$FAIL" ;;
	esac
	fi

	case "$name" in
	dmabuf-vanishing|teardown-active) counter=delay_consumed ;;
	irq-timeout|hardware-hang) counter=hang_task_once_consumed ;;
	iommu-fault) counter=inject_iommu_fault_once_consumed ;;
	reset-failure) counter=fail_reset_once_consumed ;;
	rga-irq-timeout) counter=irq_timeout_once_consumed ;;
	rga-hardware-hang) counter=hang_task_once_consumed ;;
	rga-iommu-fault) counter=inject_iommu_fault_once_consumed ;;
	rga-reset-failure) counter=fail_reset_once_consumed ;;
	*) counter= ;;
	esac
	if [[ -n $counter ]]; then
		before_count=$(awk -v key="$counter" '$1=="fault"&&$2==key{print $3}' "$before")
		after_count=$(awk -v key="$counter" '$1=="fault"&&$2==key{print $3}' "$after")
		SCORE_REASON=consumed-counter
		[[ -n $before_count && $after_count == $((before_count + 1)) ]] || return "$FAIL"
	fi
	SCORE_REASON=recovery-assertion
}

journal_clean() {
	local scan_rc=0
	# Do not use -q: a match must not hide a later read error.
	grep -Ei "$JOURNAL_BAD_SIGNATURES" "$1" >/dev/null || scan_rc=$?
	case $scan_rc in
	0) SCORE_REASON=journal; return "$FAIL" ;;
	1) return 0 ;;
	*) SCORE_REASON='journal-scan'; return "$FAIL" ;;
	esac
}

score_row() {
	local name=$1 baseline=$2 before=$3 after=$4 since=$5 fps
	SCORE_REASON=recovery-assertion
	fps=$(sample_fps)
	kill -0 "$HEALTHY_PID" 2>/dev/null || return "$FAIL"
	awk -v got="$fps" -v base="$baseline" 'BEGIN{exit !(got>=base*0.95 && got<=base*1.05)}' || return "$FAIL"
	healthy_stop || { SCORE_REASON=healthy-wedge; return "$FAIL"; }
	"$PROBE_MPP" "${PROBE_EXPECT[@]}" >"$OUT/$name.capability" 2>&1 || return "$FAIL"
	gst-launch-1.0 -q videotestsrc num-buffers=30 ! video/x-raw,format=NV12,width=1280,height=720 ! mpph264enc ! fakesink >"$OUT/$name.clean" 2>&1 || return "$FAIL"
	for _ in $(seq 1 30); do
		sleep 0.5
		snapshot "$after" || return "$FAIL"
		snapshot_quiesced "$after" "$IDLE_BASELINE" && break
	done
	if ! journalctl -k -b --since "@$since" --no-pager >"$OUT/$name.journal" 2>&1; then
		SCORE_REASON='journal-capture'
		return "$FAIL"
	fi
	score_snapshots "$before" "$after" "$IDLE_BASELINE" "$OUT/$name.journal" "$name" || return "$FAIL"
	[[ ! -r /proc/lockdep_stats ]] || grep -q '^ debug_locks: *1$' /proc/lockdep_stats || return "$FAIL"
	SCORE_FPS=$fps
}

survive_row() {
	printf 'row=%s verdict=SURVIVE baseline_fps=%s healthy_fps=%s reset_delta=%s busy=%s queue_depth=%s dmabufs=%s iommu_maps=%s journal_bad=0%s\n' \
		"$1" "$2" "$SCORE_FPS" "$SCORE_RESET_DELTA" \
		"$(field_state busy 0)" "$(field_state queue_depth 0)" \
		"$(field_state dmabufs baseline)" "$(field_state iommu_maps baseline)" \
		"${SCORE_GAPS:+ gaps=$SCORE_GAPS}"
}

# fatal_check — final journal validation after cleanup. Fatal reports, wedges
# and unknown journal state stop the campaign; a lone warning fails only its row.
fatal_check() {
	local name=$1 since=$2 journal scan_rc=0 journal_error=
	journal="$OUT/$name.journal"
	case "$SCORE_REASON" in
	journal-capture|journal-scan) journal_error=$SCORE_REASON; FATAL=$name ;;
	healthy-wedge) FATAL=$name ;;
	esac
	# Always refresh after cleanup: score_row may have captured an earlier window.
	if ! journalctl -k -b --since "@$since" --no-pager >"$journal" 2>&1; then
		SCORE_REASON='journal-capture'
		FATAL=$name
		return "$FAIL"
	fi
	grep -Ei "$FATAL_SIGNATURES" "$journal" >/dev/null || scan_rc=$?
	case $scan_rc in
	0)
		SCORE_REASON='journal-fatal'
		FATAL=$name
		;;
	1) ;;
	*)
		SCORE_REASON='journal-scan'
		FATAL=$name
		;;
	esac
	[[ -z $journal_error ]] || SCORE_REASON=$journal_error
	[[ -z $FATAL ]] || return "$FAIL"
	if ! journal_clean "$journal"; then
		[[ $SCORE_REASON != journal-scan ]] || FATAL=$name
		return "$FAIL"
	fi
}

skip_row_after_fatal() {
	printf 'row=%s verdict=GATED reason=stopped-after-%s\n' "$1" "$FATAL"
}

summary_line() {
	printf 'matrix failures=%s gated=%s baseline_fps=%s out=%s%s\n' \
		"$1" "$2" "$3" "$4" "${FATAL:+ fatal=$FATAL}"
}

run_row() {
	local name=$1 baseline=$2 since=$ROW_SINCE rc=0
	local before="$OUT/$name.before" after="$OUT/$name.after"
	SCORE_REASON=
	snapshot "$before"
	stimulate "$name" || rc=$?
	if ((rc == GATED)); then SCORE_REASON=stimulus-unavailable; return "$GATED"; fi
	((rc == 0)) || { SCORE_REASON=stimulus; return "$FAIL"; }
	score_row "$name" "$baseline" "$before" "$after" "$since"
}

# The admitted campaign, separate from hardware admission so fixtures run the
# same startup, scoring and cleanup order as a board.
matrix_rows() {
	local baseline name failures=0 gated=0 rc started
	for name in "${ROWS[@]}"; do
		[[ $ROW == all || $ROW == "$name" ]] || continue
		if [[ -n $FATAL ]]; then
			skip_row_after_fatal "$name"; gated=$((gated + 1)); continue
		fi
		IDLE_BASELINE="$OUT/$name.idle-baseline"
		snapshot "$IDLE_BASELINE" || return "$GATED"
		ROW_SINCE=$(date +%s)
		SCORE_REASON=
		started=0
		if healthy_start "$name"; then
			started=1
			baseline=$(sample_fps)
			run_row "$name" "$baseline"; rc=$?
		else
			SCORE_REASON=healthy-start
			rc=$FAIL
		fi
		if ! healthy_stop; then
			SCORE_REASON=healthy-wedge
			rc=$FAIL
			FATAL=$name
		fi
		if ! fatal_check "$name" "$ROW_SINCE"; then
			rc=$FAIL
		fi
		case $rc in
		0) survive_row "$name" "$baseline" ;;
		"$GATED") printf 'row=%s verdict=GATED reason=%s\n' "$name" "$SCORE_REASON"; ((gated++)) ;;
		*) printf 'row=%s verdict=FAIL reason=%s\n' "$name" "${SCORE_REASON:-recovery-assertion}"; ((failures++)) ;;
		esac
		((started)) || return "$FAIL"
	done
	summary_line "$failures" "$gated" "${baseline:-0}" "$OUT"
	((failures == 0 && gated == 0))
}

# ---------------------------------------------------------------------------
# --self-test
# ---------------------------------------------------------------------------

st_fixtures_dir() {
	if [[ -d $HERE/../fixtures ]]; then (cd "$HERE/../fixtures" && pwd)
	elif [[ -d $HERE/tests/fixtures ]]; then (cd "$HERE/tests/fixtures" && pwd)
	else return 1
	fi
}

# st_score — one scoring leg. `want` is PASS or RED. `detail` is the exact gaps
# list a PASS leg must produce, or the exact reason a RED leg must give. A leg
# that cannot go RED on a mutated fixture proves nothing, so every happy leg
# has four mutated twins.
st_score() {
	local label=$1 want=$2 detail=$3 before=$4 after=$5 baseline=$6 journal=$7 row=$8
	local rc=0 got

	score_snapshots "$before" "$after" "$baseline" "$journal" "$row" || rc=$?
	got=$SCORE_GAPS

	if [[ $want == PASS ]]; then
		if ((rc != 0)); then
			printf 'self-test=%s FAIL expected=PASS got=RED reason=%s\n' "$label" "$SCORE_REASON"
			return "$FAIL"
		fi
		if [[ $got != "$detail" ]]; then
			printf 'self-test=%s FAIL expected_gaps=%s got_gaps=%s\n' "$label" "${detail:-<none>}" "${got:-<none>}"
			return "$FAIL"
		fi
		printf 'self-test=%s PASS verdict=SURVIVE gaps=%s\n' "$label" "${got:-<none>}"
		return 0
	fi

	if ((rc == 0)); then
		printf 'self-test=%s FAIL expected=RED got=SURVIVE\n' "$label"
		return "$FAIL"
	fi
	if [[ -n $detail && $SCORE_REASON != "$detail" ]]; then
		printf 'self-test=%s FAIL expected_reason=%s got_reason=%s\n' "$label" "$detail" "$SCORE_REASON"
		return "$FAIL"
	fi
	printf 'self-test=%s PASS verdict=RED reason=%s\n' "$label" "$SCORE_REASON"
}

# st_profile_legs — the five legs every profile owes: one happy path and the
# four mutations of it that must each turn RED.
st_profile_legs() {
	local profile=$1 src=$2 row=$3 want_gaps=$4 scratch=$5
	local before="$src/$row.before" after="$src/$row.after"
	local baseline="$src/$row.idle-baseline" journal="$src/$row.journal"
	local counter rc=0 f

	for f in "$before" "$after" "$baseline" "$journal"; do
		[[ -r $f ]] || { printf 'self-test=%s-happy FAIL reason=missing-fixture path=%s\n' "$profile" "$f"; return "$FAIL"; }
	done

	case "$row" in
	irq-timeout|hardware-hang) counter=hang_task_once_consumed ;;
	iommu-fault) counter=inject_iommu_fault_once_consumed ;;
	*) counter=delay_consumed ;;
	esac

	st_score "$profile-happy" PASS "$want_gaps" "$before" "$after" "$baseline" "$journal" "$row" || rc=1

	# (i) the one-shot never reported a consume
	awk -v key="$counter" -v b="$(awk -v k="$counter" '$1=="fault"&&$2==k{print $3}' "$before")" \
		'$1=="fault"&&$2==key{$3=b}1' OFS=' ' "$after" >"$scratch/$profile.counter.after"
	st_score "$profile-red-counter" RED consumed-counter "$before" "$scratch/$profile.counter.after" \
		"$baseline" "$journal" "$row" || rc=1

	# (ii) a fatal allocator splat inside the row's journal window
	{ cat "$journal"; printf 'Sep 04 03:34:27 ceralive kernel: KASAN: use-after-free in mpp_task_dump+0x1c/0x180\n'; } >"$scratch/$profile.kasan.journal"
	st_score "$profile-red-journal" RED journal "$before" "$after" "$baseline" \
		"$scratch/$profile.kasan.journal" "$row" || rc=1

	# (iii) a core still busy after recovery
	awk 'NR==1&&$2=="busy"{$3=1}1' OFS=' ' "$after" >"$scratch/$profile.busy.after"
	st_score "$profile-red-busy" RED busy "$before" "$scratch/$profile.busy.after" \
		"$baseline" "$journal" "$row" || rc=1

	# (iv) dma-buf objects leaked against the idle baseline
	awk '$1=="global"&&$2=="dmabufs"{$3=$3+7}1' OFS=' ' "$after" >"$scratch/$profile.dmabufs.after"
	st_score "$profile-red-dmabufs" RED dmabufs "$before" "$scratch/$profile.dmabufs.after" \
		"$baseline" "$journal" "$row" || rc=1

	# (v) recovery never reset the core the fault landed on
	awk 'NR==FNR{if ($2=="resets") r[$1]=$3; next} $2=="resets"&&($1 in r){$3=r[$1]}1' \
		OFS=' ' "$before" "$after" >"$scratch/$profile.resets.after"
	st_score "$profile-red-reset-delta" RED reset-delta "$before" "$scratch/$profile.resets.after" \
		"$baseline" "$journal" "$row" || rc=1

	return "$rc"
}

# st_wedge_reaped — a real child that ignores TERM. The reaper must escalate to
# KILL, decide aliveness with kill -0, then reap with wait and clear the pid.
st_wedge_reaped() {
	local log=$1 rc=0 pid
	local saved_term=$HEALTHY_TERM_POLLS saved_kill=$HEALTHY_KILL_POLLS

	HEALTHY_TERM_POLLS=3
	HEALTHY_KILL_POLLS=50
	bash -c 'trap "" TERM; while :; do sleep 0.2; done' &
	HEALTHY_PID=$!
	pid=$HEALTHY_PID
	HEALTHY_WEDGED=
	sleep 0.4
	healthy_stop >"$log" 2>&1 || rc=$?
	HEALTHY_TERM_POLLS=$saved_term
	HEALTHY_KILL_POLLS=$saved_kill

	if ((rc != 0)); then
		printf 'self-test=healthy-wedge-reaped FAIL rc=%s\n' "$rc"; return "$FAIL"
	fi
	if grep -q 'healthy-wedge' "$log"; then
		printf 'self-test=healthy-wedge-reaped FAIL reason=wedge-reported-for-a-reaped-child\n'; return "$FAIL"
	fi
	if [[ -n ${HEALTHY_PID:-} ]]; then
		printf 'self-test=healthy-wedge-reaped FAIL reason=pid-not-cleared\n'; return "$FAIL"
	fi
	if kill -0 "$pid" 2>/dev/null; then
		printf 'self-test=healthy-wedge-reaped FAIL reason=child-still-alive\n'; return "$FAIL"
	fi
	printf 'self-test=healthy-wedge-reaped PASS term-ignored kill-escalated wait-reaped pid=%s\n' "$pid"
}

# st_wedge_unreapable — kill -0 keeps succeeding past the post-KILL deadline.
# The reaper must report the wedge, retain the pid and NEVER call wait: an
# unreapable child would block wait forever and make this branch unreachable.
# The stubs live in a subshell so the real builtins are untouched afterwards.
st_wedge_unreapable() {
	local log=$1
	(
		HEALTHY_PID=424242
		HEALTHY_WEDGED=
		HEALTHY_TERM_POLLS=2
		HEALTHY_KILL_POLLS=2
		kill() { return 0; }
		sleep() { :; }
		# Dead by design: this leg asserts the body never runs.
		# shellcheck disable=SC2317
		wait() { printf 'WAIT-INVOKED\n'; return 0; }
		healthy_stop
		printf 'rc=%s retained=%s\n' "$?" "${HEALTHY_PID:-EMPTY}"
	) >"$log" 2>&1

	grep -q '^healthy-wedge pid=424242$' "$log" || {
		printf 'self-test=healthy-wedge-unreapable FAIL reason=no-wedge-line\n'; return "$FAIL"; }
	grep -q '^rc=1 retained=424242$' "$log" || {
		printf 'self-test=healthy-wedge-unreapable FAIL reason=%s\n' "$(tr '\n' ' ' <"$log")"; return "$FAIL"; }
	grep -q 'WAIT-INVOKED' "$log" && {
		printf 'self-test=healthy-wedge-unreapable FAIL reason=wait-was-invoked-on-an-unreapable-child\n'; return "$FAIL"; }
	printf 'self-test=healthy-wedge-unreapable PASS returned=1 pid-retained wait-never-invoked\n'
}

# st_fatal_stop — a KASAN line on row k stops the campaign at k; a benign
# window (the shape a 77/GATED row leaves behind) never sets FATAL.
st_fatal_stop() (
	local scratch=$1 saved_out=$OUT saved_fatal=$FATAL saved_reason=$SCORE_REASON
	local row=hardware-hang next=reset-failure rc=0 emitted lines

	OUT="$scratch/fatal"
	mkdir -p "$OUT"
	FATAL=
	SCORE_REASON=
	journalctl() { cat "$scratch/fatal-source"; }

	printf 'Sep 04 03:34:26 ceralive kernel: mpp_rkvenc2 fdbd0000.rkvenc-core: reset done\n' >"$scratch/fatal-source"
	fatal_check "$next" 0
	if [[ -n $FATAL ]]; then
		printf 'self-test=fatal-stop FAIL reason=benign-journal-set-fatal=%s\n' "$FATAL"
		rc=1
	fi

	{ printf 'Sep 04 03:34:26 ceralive kernel: rk_vcodec: task 4995 processing time out!\n'
	  printf 'Sep 04 03:34:26 ceralive kernel: KASAN: slab-out-of-bounds in rkvenc_irq+0x40/0x300\n'
	} >"$scratch/fatal-source"
	fatal_check "$row" 0
	if [[ $FATAL != "$row" ]]; then
		printf 'self-test=fatal-stop FAIL reason=kasan-journal-did-not-set-fatal got=%s\n' "${FATAL:-<none>}"
		rc=1
	fi

	emitted=$(skip_row_after_fatal "$next")
	if [[ $emitted != "row=$next verdict=GATED reason=stopped-after-$row" ]]; then
		printf 'self-test=fatal-stop FAIL reason=bad-stopped-line got=%s\n' "$emitted"
		rc=1
	fi
	lines=$(summary_line 1 5 29.980 /tmp/fm)
	if [[ $lines != *" fatal=$row" ]]; then
		printf 'self-test=fatal-stop FAIL reason=summary-missing-fatal got=%s\n' "$lines"
		rc=1
	fi

	FATAL=
	lines=$(summary_line 0 1 29.980 /tmp/fm)
	if [[ $lines == *fatal=* ]]; then
		printf 'self-test=fatal-stop FAIL reason=summary-carried-fatal-with-none-set got=%s\n' "$lines"
		rc=1
	fi

	OUT=$saved_out
	FATAL=$saved_fatal
	SCORE_REASON=$saved_reason
	((rc == 0)) || return "$FAIL"
	printf 'self-test=fatal-stop PASS kasan-row=%s stopped=%s benign-window-clean summary-fatal-field-ok\n' "$row" "$next"
)

st_option_values() {
	local option got
	for option in --driver --out --row --probe-mpp --invalid-ioctl --probe-rga; do
		CERALIVE_BOARD_TEST=0 timeout 2 bash "$HERE/fault-matrix.sh" "$option" >/dev/null 2>&1; got=$?
		printf 'self-test=missing-option-value option=%s want=2 got=%s\n' "$option" "$got"
		[[ $got == "$USAGE" ]] || return "$FAIL"
	done
	CERALIVE_BOARD_TEST=0 timeout 2 bash "$HERE/fault-matrix.sh" \
		--driver island --out 'unused path with spaces' --row all \
		--probe-mpp unused --invalid-ioctl unused >/dev/null 2>&1; got=$?
	printf 'self-test=present-option-values want=77 got=%s\n' "$got"
	[[ $got == "$GATED" ]]
}

st_journal_windows() (
	local scratch=$1 fixtures=$2 mode got rc=0 now report_at stimulus_rc
	local row=hardware-hang expected_fatal journal_calls stopped
	ROW=$row
	PROBE_MPP=true
	# Only board operations and the clock are substituted; the campaign,
	# run_row, score_row and fatal_check remain the production functions.
	date() { printf '%s\n' "$now"; }
	sleep() { :; }
	snapshot() { cp "$fixtures/$row.${1##*.}" "$1"; }
	sample_fps() { printf '30\n'; }
	healthy_start() {
		HEALTHY_PID=$$
		[[ $mode != startup* ]] || report_at=$now
		now=102
		[[ $mode != startup-failed ]]
	}
	stimulate() {
		[[ $mode != gated-report && $mode != failed-report ]] || report_at=$now
		return "$stimulus_rc"
	}
	healthy_stop() {
		stopped=$((stopped + 1))
		if [[ $mode == cleanup-gated || $mode == cleanup-failed || ( $mode == cleanup-scored && $stopped == 2 ) ]]; then
			report_at=103
		fi
		return 0
	}
	gst-launch-1.0() { return 0; }
	journalctl() {
		local since
		while (($#)); do
			if [[ $1 == --since ]]; then since=${2#@}; break; fi
			shift
		done
		journal_calls=$((journal_calls + 1))
		if ((report_at >= since)); then
			printf 'kernel: KASAN: synthetic report at %s\n' "$report_at"
		fi
		return 0
	}
	for mode in startup-report startup-failed gated-report failed-report cleanup-gated cleanup-failed cleanup-scored clean-gated clean-failed clean-scored; do
		OUT="$scratch/window-$mode"
		mkdir -p "$OUT"
		FATAL=; SCORE_REASON=; ROW_SINCE=0
		now=100; report_at=-1; journal_calls=0; stopped=0
		stimulus_rc=0; expected_fatal=$row
		case "$mode" in
		*gated*) stimulus_rc=$GATED ;;
		*failed*|startup-report) stimulus_rc=$FAIL ;;
		esac
		[[ $mode != clean-* ]] || expected_fatal=
		matrix_rows >"$OUT/result" 2>&1; got=$?
		printf 'self-test=journal-window mode=%s exit=%s ROW_SINCE=%s FATAL=%s captures=%s stopped=%s\n' \
			"$mode" "$got" "$ROW_SINCE" "${FATAL:-EMPTY}" "$journal_calls" "$stopped"
		if [[ $FATAL != "$expected_fatal" || $ROW_SINCE != 100 ]] || ((stopped == 0 || journal_calls == 0)); then
			rc=1
		fi
		if [[ $mode == clean-scored ]]; then
			[[ $got == 0 ]] || rc=1
			grep -q 'verdict=SURVIVE' "$OUT/result" || rc=1
		else
			[[ $got == "$FAIL" ]] || rc=1
		fi
		if [[ $mode == clean-gated ]]; then
			grep -q 'verdict=GATED reason=stimulus-unavailable' "$OUT/result" || rc=1
		fi
	done
	return "$rc"
)

# Replay the admitted campaign, including both captures and both scanners.
# Only hardware/clock operations and the selected I/O failure are substituted.
st_journal_validation() (
	local scratch=$1 fixtures=$2 profile=$3 mode='' OUT='' error_status got rc=0
	local journal_calls=0 stimulus_calls expected_fatal expected_reason expected_rc
	local row fixture_row=hardware-hang capture_error_at scanner_error_at scanner_pattern
	PROBE_MPP=true
	date() { printf '100\n'; }
	sleep() { :; }
	snapshot() { cp "$fixtures/$fixture_row.${1##*.}" "$1"; }
	sample_fps() { printf '30\n'; }
	healthy_start() { HEALTHY_PID=$$; }
	healthy_stop() { return 0; }
	stimulate() { stimulus_calls=$((stimulus_calls + 1)); }
	gst-launch-1.0() { return 0; }
	journalctl() {
		journal_calls=$((journal_calls + 1))
		if command grep -q '^row=.*verdict=' "$OUT/result"; then
			printf 'premature-verdict\n' >>"$OUT/events"
		fi
		case "$mode" in
		*fatal*) printf 'kernel: BUG: KASAN: synthetic saved report\n' ;;
		warning) printf 'kernel: WARNING: synthetic saved report\n' ;;
		cleanup-warning) ((journal_calls < 2)) || printf 'kernel: WARNING: cleanup report\n' ;;
		clean-record) printf 'kernel: recovery complete\n' ;;
		esac
		((journal_calls != capture_error_at))
	}
	grep() {
		if [[ ${2:-} == "$JOURNAL_BAD_SIGNATURES" || ${2:-} == "$FATAL_SIGNATURES" ]]; then
			if command grep -q '^row=.*verdict=' "$OUT/result"; then
				printf 'premature-verdict\n' >>"$OUT/events"
			fi
		fi
		if [[ ${2:-} == "$scanner_pattern" || ( $scanner_pattern == both && ( ${2:-} == "$JOURNAL_BAD_SIGNATURES" || ${2:-} == "$FATAL_SIGNATURES" ) ) ]]; then
			if ((scanner_error_at == 0 || journal_calls == scanner_error_at)); then
				printf 'scanner-error\n' >>"$OUT/events"
				printf 'grep: synthetic journal read error\n' >&2
				return "$error_status"
			fi
		fi
		command grep "$@"
	}
	for mode in clean-empty clean-record fatal warning cleanup-warning \
		capture-early-empty capture-early-fatal capture-final-empty capture-final-fatal \
		scan-early-empty scan-early-fatal scan-final-empty scan-final-fatal \
		scan-bad-final-empty scan-both-empty scan-both-fatal scan-both-sweep-empty scan-both-sweep-fatal; do
		for error_status in 2 3; do
			[[ $mode == scan-* || $error_status == 2 ]] || continue
			OUT="$scratch/validation-$profile-$mode-$error_status"
			mkdir -p "$OUT"
			: >"$OUT/events"
			ROW=hardware-hang; row=$ROW
			FATAL=; SCORE_REASON=; journal_calls=0; stimulus_calls=0
			capture_error_at=0; scanner_error_at=0; scanner_pattern=none
			expected_rc=$FAIL; expected_fatal=$row
			case "$mode" in
			clean-*) expected_rc=0; expected_fatal=; expected_reason= ;;
			fatal) expected_reason='journal-fatal' ;;
			*warning) expected_fatal=; expected_reason=journal ;;
			capture-early-*) capture_error_at=1; expected_reason='journal-capture' ;;
			capture-final-*) capture_error_at=2; expected_reason='journal-capture' ;;
			scan-early-*) scanner_error_at=1; scanner_pattern=$JOURNAL_BAD_SIGNATURES; expected_reason='journal-scan' ;;
			scan-final-*) scanner_error_at=2; scanner_pattern=$FATAL_SIGNATURES; expected_reason='journal-scan' ;;
			scan-bad-final-*) scanner_error_at=2; scanner_pattern=$JOURNAL_BAD_SIGNATURES; expected_reason='journal-scan' ;;
			scan-both-*)
				scanner_pattern=both; expected_reason='journal-scan'
				if [[ $mode == scan-both-sweep-* ]]; then
					ROW=all; row=${ROWS[0]}; expected_fatal=$row
				fi ;;
			esac
			matrix_rows >"$OUT/result" 2>&1; got=$?
			printf 'self-test=journal-validation profile=%s mode=%s scanner_status=%s exit=%s FATAL=%s captures=%s stimuli=%s\n' \
				"$profile" "$mode" "$error_status" "$got" "${FATAL:-EMPTY}" "$journal_calls" "$stimulus_calls"
			if [[ $got != "$expected_rc" || $FATAL != "$expected_fatal" || $journal_calls != 2 || $stimulus_calls != 1 ]]; then
				rc=1
			fi
			if command grep -q premature-verdict "$OUT/events"; then
				printf 'self-test=journal-validation FAIL reason=premature-verdict mode=%s\n' "$mode"
				rc=1
			fi
			if [[ $mode == scan-* ]] && ! command grep -q scanner-error "$OUT/events"; then
				printf 'self-test=journal-validation FAIL reason=scanner-not-exercised mode=%s\n' "$mode"
				rc=1
			fi
			if ((expected_rc == 0)); then
				command grep -q "^row=$row verdict=SURVIVE .*journal_bad=0" "$OUT/result" || rc=1
			else
				if command grep -q 'verdict=SURVIVE' "$OUT/result"; then
					printf 'self-test=journal-validation FAIL reason=false-survive mode=%s\n' "$mode"
					rc=1
				fi
				# An earlier capture/scanner failure must remain the row reason,
				# even when a later scan succeeds and sees a fatal report.
				command grep -qx "row=$row verdict=FAIL reason=$expected_reason" "$OUT/result" || rc=1
			fi
			[[ $(command grep -c "^row=$row verdict=" "$OUT/result") == 1 ]] || rc=1
			if [[ $ROW == all ]]; then
				[[ $(command grep -c "verdict=GATED reason=stopped-after-$row" "$OUT/result") == $((${#ROWS[@]} - 1)) ]] || rc=1
			fi
		done
	done
	# No scanner override: a real grep directory-read error is not no-match.
	unset -f grep
	mkdir -p "$scratch/journal-directory-$profile"
	st_score "$profile-journal-directory" RED journal-scan \
		"$fixtures/$fixture_row.before" "$fixtures/$fixture_row.after" \
		"$fixtures/$fixture_row.idle-baseline" "$scratch/journal-directory-$profile" "$fixture_row" || rc=1
	return "$rc"
)

self_test() {
	local expected fixtures scratch rc=0 island

	expected=$(printf '%s\n' "${ROWS[@]}" | wc -l)
	[[ $expected == 16 ]] || return "$FAIL"
	[[ ${ROWS[*]} != *rga* ]] || return "$FAIL"

	fixtures=$(st_fixtures_dir) || {
		printf 'self-test=fixtures FAIL reason=fixture-tree-not-found\n'; return "$FAIL"; }
	island="$fixtures/reliability/orange-pi-5-plus"
	scratch=$(mktemp -d) || return "$FAIL"

	# The island profile has no GAPs by construction: every metric its
	# assertions need is a file the production driver publishes. A gap
	# appearing here would mean an island assertion silently stopped
	# running, so the expected list is asserted empty.
	st_profile_legs island "$island/initial-run" hardware-hang '' "$scratch" || rc=1
	st_score island-happy-iommu PASS '' \
		"$island/iommu-fault-rerun/iommu-fault.before" \
		"$island/iommu-fault-rerun/iommu-fault.after" \
		"$island/iommu-fault-rerun/iommu-fault.idle-baseline" \
		"$island/iommu-fault-rerun/iommu-fault.journal" iommu-fault || rc=1

	st_wedge_reaped "$scratch/wedge-reaped.log" || rc=1
	st_wedge_unreapable "$scratch/wedge-unreapable.log" || rc=1
	st_fatal_stop "$scratch" || rc=1
	st_option_values || rc=1
	st_journal_windows "$scratch" "$island/initial-run" || rc=1
	st_journal_validation "$scratch" "$island/initial-run" island || rc=1
	rga_matrix_self_test "$scratch" || rc=1

	rm -rf "$scratch"
	((rc == 0)) || return "$FAIL"
	printf 'VERDICT: PASS (16 MPP rows registered; 4 RGA rows registered separately)\n'
}

main() {
	local self=0
	while (($#)); do case "$1" in
		--out|--row|--probe-mpp|--invalid-ioctl|--driver|--probe-rga)
			(($# >= 2)) || { usage; return "$USAGE"; }
			case "$1" in
			--out) OUT=$2;; --row) ROW=$2;;
			--probe-mpp) PROBE_MPP=$2;; --invalid-ioctl) INVALID_IOCTL=$2;;
			--probe-rga) PROBE_RGA=$2;;
			--driver) DRIVER=$2;;
			esac
			shift 2;;
		--self-test) self=1; shift;;
		-h|--help) usage; return "$USAGE";; *) usage; return "$USAGE";; esac; done
	((self)) && { self_test; return; }
	[[ $DRIVER != island-rga ]] || { rga_matrix_main; return $?; }
	[[ ${CERALIVE_BOARD_TEST:-0} == 1 && $EUID == 0 ]] || return "$GATED"
	[[ -x $PROBE_MPP && -x $INVALID_IOCTL && -d $FAULT_DEBUG && -r /sys/kernel/debug/dma_buf/bufinfo ]] || return "$GATED"
	[[ $ROW == all || " ${ROWS[*]} " == *" $ROW "* ]] || { usage; return "$USAGE"; }
	select_driver || return $?
	require_configs || return "$GATED"
	seam_inventory || { printf 'matrix verdict=GATED reason=seam-inventory\n'; return "$GATED"; }
	[[ ! -r /proc/lockdep_stats ]] || grep -q '^ debug_locks: *1$' /proc/lockdep_stats || return "$FAIL"
	OUT=${OUT:-/tmp/fault-matrix-$(date -u +%Y%m%dT%H%M%SZ)}; mkdir -p "$OUT"
	{ printf 'board='; tr -d '\0' </proc/device-tree/model; printf '\nkernel='; uname -a; printf 'driver=%s\n' "$DRIVER"; } >"$OUT/identity.txt"
	trap healthy_stop EXIT
	matrix_rows
}

# shellcheck source=tests/board/lib/rga-fault-matrix.sh
source "$HERE/lib/rga-fault-matrix.sh"
main "$@"
