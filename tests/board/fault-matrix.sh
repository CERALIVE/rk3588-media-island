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

OUT=
ROW=all
PROBE_MPP=
INVALID_IOCTL=
HEALTHY_PID=
HEALTHY_LOG=
IDLE_BASELINE=

usage() {
	printf 'usage: %s [--out DIR] [--row NAME|all] [--probe-mpp FILE] [--invalid-ioctl FILE]\n' "$0" >&2
	printf '       %s --self-test\n' "$0" >&2
}

snapshot() {
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

metric_sum() {
	awk -v metric="$2" '$2==metric{sum+=$3}END{print sum+0}' "$1"
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
	sleep 3
	kill -0 "$HEALTHY_PID" 2>/dev/null
}

healthy_stop() {
	[[ -n ${HEALTHY_PID:-} ]] || return 0
	kill -TERM "$HEALTHY_PID" 2>/dev/null || true
	wait "$HEALTHY_PID" 2>/dev/null || true
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
			set -- "$MPP_DEBUG"/sessions/"${tid##*/}"-*
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

score_row() {
	local name=$1 baseline=$2 before=$3 after=$4 since=$5 fps journal_bad reset_delta counter before_count after_count
	fps=$(sample_fps)
	kill -0 "$HEALTHY_PID" 2>/dev/null || return "$FAIL"
	awk -v got="$fps" -v base="$baseline" 'BEGIN{exit !(got>=base*0.95 && got<=base*1.05)}' || return "$FAIL"
	healthy_stop
	"$PROBE_MPP" --expect-island >"$OUT/$name.capability" 2>&1 || return "$FAIL"
	gst-launch-1.0 -q videotestsrc num-buffers=30 ! video/x-raw,format=NV12,width=1280,height=720 ! mpph264enc ! fakesink >"$OUT/$name.clean" 2>&1 || return "$FAIL"
	for _ in $(seq 1 30); do
		sleep 0.5
		snapshot "$after" || return "$FAIL"
		[[ $(awk '$1=="global"&&$2=="queue_depth"{print $3}' "$after") == 0 ]] || continue
		[[ $(metric_sum "$after" busy) == 0 ]] || continue
		[[ $(awk '$1=="global"&&$2=="dmabufs"{print $3}' "$IDLE_BASELINE") == $(awk '$1=="global"&&$2=="dmabufs"{print $3}' "$after") ]] || continue
		[[ $(awk '$1=="global"&&$2=="iommu_maps"{print $3}' "$IDLE_BASELINE") == $(awk '$1=="global"&&$2=="iommu_maps"{print $3}' "$after") ]] || continue
		break
	done
	[[ $(awk '$1=="global"&&$2=="queue_depth"{print $3}' "$after") == 0 ]] || return "$FAIL"
	[[ $(metric_sum "$after" busy) == 0 ]] || return "$FAIL"
	[[ $(awk '$1=="global"&&$2=="dmabufs"{print $3}' "$IDLE_BASELINE") == $(awk '$1=="global"&&$2=="dmabufs"{print $3}' "$after") ]] || return "$FAIL"
	[[ $(awk '$1=="global"&&$2=="iommu_maps"{print $3}' "$IDLE_BASELINE") == $(awk '$1=="global"&&$2=="iommu_maps"{print $3}' "$after") ]] || return "$FAIL"
	journalctl -k -b --since "@$since" --no-pager >"$OUT/$name.journal"
	journal_bad=$(grep -Eic 'WARNING:|BUG:|KASAN:|possible recursive locking|inconsistent lock state|Oops' "$OUT/$name.journal" || true)
	((journal_bad == 0)) || return "$FAIL"
	reset_delta=$(( $(metric_sum "$after" resets) - $(metric_sum "$before" resets) ))
	case "$name" in
	dmabuf-vanishing|teardown-active) counter=delay_consumed ;;
	irq-timeout|hardware-hang) counter=hang_task_once_consumed ;;
	iommu-fault) counter=inject_iommu_fault_once_consumed ;;
	reset-failure) counter=fail_reset_once_consumed ;;
	*) counter= ;;
	esac
	case "$name" in
	irq-timeout|iommu-fault|hardware-hang|reset-failure) ((reset_delta >= 1)) || return "$FAIL" ;;
	esac
	if [[ -n $counter ]]; then
		before_count=$(awk -v key="$counter" '$1=="fault"&&$2==key{print $3}' "$before")
		after_count=$(awk -v key="$counter" '$1=="fault"&&$2==key{print $3}' "$after")
		[[ -n $before_count && $after_count == $((before_count + 1)) ]] || return "$FAIL"
	fi
	[[ ! -r /proc/lockdep_stats ]] || grep -q '^ debug_locks: *1$' /proc/lockdep_stats || return "$FAIL"
	printf 'row=%s verdict=SURVIVE baseline_fps=%s healthy_fps=%s reset_delta=%s busy=0 queue_depth=0 dmabufs=baseline iommu_maps=baseline journal_bad=0\n' "$name" "$baseline" "$fps" "$reset_delta"
}

run_row() {
	local name=$1 baseline=$2 since rc=0
	local before="$OUT/$name.before" after="$OUT/$name.after"
	snapshot "$before"; since=$(date +%s)
	stimulate "$name" || rc=$?
	if ((rc == GATED)); then printf 'row=%s verdict=GATED reason=stimulus-unavailable\n' "$name"; return "$GATED"; fi
	((rc == 0)) || { printf 'row=%s verdict=FAIL reason=stimulus\n' "$name"; return "$FAIL"; }
	score_row "$name" "$baseline" "$before" "$after" "$since" || { printf 'row=%s verdict=FAIL reason=recovery-assertion\n' "$name"; return "$FAIL"; }
}

self_test() {
	local expected
	expected=$(printf '%s\n' "${ROWS[@]}" | wc -l)
	[[ $expected == 16 ]] || return "$FAIL"
	[[ ${ROWS[*]} != *rga* ]] || return "$FAIL"
	printf 'VERDICT: PASS (16 MPP rows registered; RGA remains out of scope)\n'
}

main() {
	local self=0 baseline name failures=0 gated=0
	while (($#)); do case "$1" in
		--out) OUT=${2:-}; shift 2;; --row) ROW=${2:-}; shift 2;;
		--probe-mpp) PROBE_MPP=${2:-}; shift 2;; --invalid-ioctl) INVALID_IOCTL=${2:-}; shift 2;;
		--self-test) self=1; shift;;
		-h|--help) usage; return "$USAGE";; *) usage; return "$USAGE";; esac; done
	((self)) && { self_test; return; }
	[[ ${CERALIVE_BOARD_TEST:-0} == 1 && $EUID == 0 ]] || return "$GATED"
	[[ -x $PROBE_MPP && -x $INVALID_IOCTL && -d $FAULT_DEBUG && -r /sys/kernel/debug/dma_buf/bufinfo ]] || return "$GATED"
	[[ $ROW == all || " ${ROWS[*]} " == *" $ROW "* ]] || { usage; return "$USAGE"; }
	zgrep -qx 'CONFIG_KASAN=y' /proc/config.gz || return "$GATED"
	zgrep -qx 'CONFIG_PROVE_LOCKING=y' /proc/config.gz || return "$GATED"
	zgrep -qx 'CONFIG_ROCKCHIP_MPP_CERALIVE_TEST=y' /proc/config.gz || return "$GATED"
	[[ ! -r /proc/lockdep_stats ]] || grep -q '^ debug_locks: *1$' /proc/lockdep_stats || return "$FAIL"
	OUT=${OUT:-/tmp/fault-matrix-$(date -u +%Y%m%dT%H%M%SZ)}; mkdir -p "$OUT"
	{ printf 'board='; tr -d '\0' </proc/device-tree/model; printf '\nkernel='; uname -a; } >"$OUT/identity.txt"
	trap healthy_stop EXIT
	for name in "${ROWS[@]}"; do
		[[ $ROW == all || $ROW == "$name" ]] || continue
		IDLE_BASELINE="$OUT/$name.idle-baseline"
		snapshot "$IDLE_BASELINE" || return "$GATED"
		healthy_start "$name" || return "$FAIL"
		baseline=$(sample_fps)
		run_row "$name" "$baseline"; case $? in 0) ;; "$GATED") ((gated++));; *) ((failures++));; esac
		healthy_stop
	done
	printf 'matrix failures=%s gated=%s baseline_fps=%s out=%s\n' "$failures" "$gated" "$baseline" "$OUT"
	((failures == 0 && gated == 0))
}

main "$@"
