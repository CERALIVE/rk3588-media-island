#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -uo pipefail

readonly FAIL=1 USAGE=2 GATED=77
readonly TRACEFS=/sys/kernel/tracing
readonly MPP_DEBUG=/sys/kernel/debug/rockchip-mpp

DURATION=120
OUT=
SCENARIO=all
MPP_ENC_TEST=
declare -a PIDS=() TAGS=() RATES=() START_NS=() LOGS=()

usage() {
	printf 'usage: %s [--duration SEC] [--out DIR] [--scenario 1..6|all] [--mpp-enc-test FILE]\n' "$0" >&2
	printf '       %s --self-test\n' "$0" >&2
}

kv() { printf '%s=%s\n' "$1" "${2-}"; }

percentile() {
	local pct=$1
	awk -v p="$pct" '{v[NR]=$1} END {if (!NR) exit 1; i=int((NR*p+99)/100); print v[i]}'
}

# Emits one row per selected task. The queued session index is the only stable
# link from the trace to sessions/<pid>-<session>.
trace_rows() {
	awk '
		match($0, /[0-9]+\.[0-9]+: mpp_task_queued:/) {
			ts=substr($0,RSTART,RLENGTH); sub(/:.*/,"",ts)
			if (match($0,/session=[0-9]+/)) s=substr($0,RSTART+8,RLENGTH-8)
			if (match($0,/task=[0-9]+/)) t=substr($0,RSTART+5,RLENGTH-5)
			q[t]=ts; session[t]=s; next
		}
		match($0, /[0-9]+\.[0-9]+: mpp_core_selected:/) {
			ts=substr($0,RSTART,RLENGTH); sub(/:.*/,"",ts)
			if (match($0,/task=[0-9]+/)) t=substr($0,RSTART+5,RLENGTH-5)
			if (match($0,/core=-?[0-9]+/)) c=substr($0,RSTART+5,RLENGTH-5)
			if (match($0,/idle=0x[0-9a-fA-F]+/)) idle=substr($0,RSTART+5,RLENGTH-5); else idle="unknown"
			if (t in q) printf "task=%s session=%s core=%s idle=%s queue_to_select_us=%.3f\n", t,session[t],c,idle,(ts-q[t])*1000000
		}
	' "$1"
}

trace_summary() {
	local trace=$1 session=${2:-} rows latencies n p50 p99 over idle_over
	rows=$(trace_rows "$trace")
	[[ -z $session ]] || rows=$(printf '%s\n' "$rows" | awk -v s="$session" '$0 ~ ("session=" s " ")')
	n=$(printf '%s\n' "$rows" | grep -c '^task=' || true)
	latencies=$(printf '%s\n' "$rows" | sed -n 's/.*queue_to_select_us=\([0-9.]*\).*/\1/p' | sort -n)
	if ((n == 0)); then
		printf 'latency_samples=0\n'
		return "$FAIL"
	fi
	p50=$(printf '%s\n' "$latencies" | percentile 50)
	p99=$(printf '%s\n' "$latencies" | percentile 99)
	over=$(printf '%s\n' "$latencies" | awk '$1>66666.667{n++} END{print n+0}')
	idle_over=$(printf '%s\n' "$rows" | awk '{
		match($0,/idle=0x[0-9a-fA-F]+/); idle=substr($0,RSTART+7,RLENGTH-7)
		match($0,/queue_to_select_us=[0-9.]+/); us=substr($0,RSTART+19,RLENGTH-19)+0
		if (idle != "" && idle != "0" && us > 66666.667) n++
	} END{print n+0}')
	printf 'latency_samples=%s p50_us=%s p99_us=%s over_2_frame_periods=%s idle_wait_over_2_frame_periods=%s\n' \
		"$n" "$p50" "$p99" "$over" "$idle_over"
}

self_test() {
	local tmp got
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' RETURN
	cat >"$tmp/trace" <<'EOF'
x [000] 10.000000: mpp_task_queued: session=7 task=41 client=16
x [000] 10.000010: mpp_core_selected: task=41 core=0 idle=0x3
x [000] 11.000000: mpp_task_queued: session=7 task=42 client=16
x [000] 11.020000: mpp_core_selected: task=42 core=1 idle=0x2
x [000] 12.000000: mpp_task_queued: session=8 task=43 client=16
x [000] 12.070000: mpp_core_selected: task=43 core=0 idle=0x1
EOF
	got=$(trace_summary "$tmp/trace" 7) || return "$FAIL"
	[[ $got == *'latency_samples=2 p50_us=10.000 p99_us=20000.000'* ]] || {
		printf 'bad percentile result: %s\n' "$got" >&2; return "$FAIL";
	}
	got=$(trace_summary "$tmp/trace" 8) || return "$FAIL"
	[[ $got == *'idle_wait_over_2_frame_periods=1'* ]] || {
		printf 'starvation discriminator failed: %s\n' "$got" >&2; return "$FAIL";
	}
	if trace_summary /dev/null >/dev/null; then
		printf 'empty trace was accepted\n' >&2
		return "$FAIL"
	fi
	printf 'VERDICT: PASS (latency percentiles and idle-core starvation discriminate)\n'
}

require_board() {
	[[ ${CERALIVE_BOARD_TEST:-0} == 1 ]] || { printf 'VERDICT: GATED (set CERALIVE_BOARD_TEST=1)\n'; return "$GATED"; }
	[[ $EUID == 0 ]] || { printf 'VERDICT: GATED (run as root)\n'; return "$GATED"; }
	for p in "$TRACEFS/trace" "$MPP_DEBUG/queue_depth" /proc/mpp_service/load_interval; do
		[[ -e $p ]] || { printf 'VERDICT: GATED (missing %s)\n' "$p"; return "$GATED"; }
	done
	command -v gst-launch-1.0 >/dev/null || { printf 'VERDICT: GATED (gst-launch-1.0 unavailable)\n'; return "$GATED"; }
}

enable_trace() {
	local event
	printf nop | tee "$TRACEFS/current_tracer" >/dev/null
	printf global | tee "$TRACEFS/trace_clock" >/dev/null 2>&1 || true
	printf 32768 | tee "$TRACEFS/buffer_size_kb" >/dev/null 2>&1 || true
	printf '\n' | tee "$TRACEFS/trace" >/dev/null
	for event in mpp_task_queued mpp_core_selected mpp_task_started mpp_task_done mpp_task_error mpp_reset; do
		[[ -e $TRACEFS/events/rockchip_mpp/$event/enable ]] || return "$GATED"
		printf 1 | tee "$TRACEFS/events/rockchip_mpp/$event/enable" >/dev/null
	done
}

disable_trace() {
	local event
	for event in mpp_task_queued mpp_core_selected mpp_task_started mpp_task_done mpp_task_error mpp_reset; do
		[[ ! -e $TRACEFS/events/rockchip_mpp/$event/enable ]] || printf 0 | tee "$TRACEFS/events/rockchip_mpp/$event/enable" >/dev/null
	done
}

snapshot_cores() {
	local dest=$1 core metric
	: >"$dest"
	for core in "$MPP_DEBUG"/cores/*; do
		[[ -d $core ]] || continue
		for metric in busy_ns tasks errors resets; do
			printf '%s %s %s\n' "$(basename "$core")" "$metric" "$(<"$core/$metric")" >>"$dest"
		done
	done
}

core_deltas() {
	local before=$1 after=$2 elapsed_ns=$3
	awk -v ns="$elapsed_ns" 'NR==FNR{a[$1 FS $2]=$3;next}{d=$3-a[$1 FS $2]; if($2=="busy_ns") printf "core=%s busy_ns=%d busy_share=%.2f%% ",$1,d,100*d/ns; else printf "%s_delta=%d ",$2,d; if($2=="resets") print ""}' "$before" "$after"
}

irq_rows() {
	awk '/^[[:space:]]*[0-9]+:/ && $NF ~ /rkvenc-core|rkvenc[01]$/ {irq=$1; sub(/:/,"",irq); n=0; for(i=2;i<=NF&&$i~/^[0-9]+$/;i++) n+=$i; print irq,$NF,n}' "$1"
}

irq_deltas() {
	join -j 1 <(irq_rows "$1" | sort -n) <(irq_rows "$2" | sort -n) |
		awk '{printf "irq=%s label=%s delta=%d\n",$1,$4,$5-$3}'
}

launch() {
	local tag=$1 rate=$2; shift 2
	local log="$CURRENT/$tag.log"
	"$@" >"$log" 2>&1 &
	PIDS+=("$!"); TAGS+=("$tag"); RATES+=("$rate"); START_NS+=("$(date +%s%N)"); LOGS+=("$log")
}

pipe_args() {
	local codec=$1 width=$2 height=$3 fps=$4 bps=$5
	PIPE=(gst-launch-1.0 -v -e videotestsrc is-live=true pattern=smpte
		! "video/x-raw,format=NV12,width=$width,height=$height,framerate=$fps/1"
		! queue max-size-buffers=4 leaky=downstream ! "mpp${codec}enc" bps="$bps"
		! identity silent=false ! fakesink sync=false)
}

monitor() {
	local end=$((SECONDS + DURATION)) q=0 v pid ticks0 ticks1 now total_ticks=0 hz
	hz=$(getconf CLK_TCK)
	declare -A cpu0=()
	for pid in "${PIDS[@]}"; do cpu0[$pid]=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null || echo 0); done
	while ((SECONDS < end)); do
		v=$(<"$MPP_DEBUG/queue_depth")
		((v > q)) && q=$v
		sleep 0.1
	done
	now=$(date +%s%N)
	for pid in "${PIDS[@]}"; do
		ticks0=${cpu0[$pid]:-0}; ticks1=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null || echo "$ticks0")
		total_ticks=$((total_ticks + ticks1 - ticks0))
		kill -INT "$pid" 2>/dev/null || true
	done
	sleep 2
	for pid in "${PIDS[@]}"; do kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
	QUEUE_MAX=$q; END_NS=$now
	CPU=$(awk -v t="$total_ticks" -v h="$hz" -v d="$DURATION" 'BEGIN{printf "%.2f",100*t/h/d}')
}

session_index_for_pid() {
	local pid=$1 dir
	for dir in "$MPP_DEBUG"/sessions/"$pid"-*; do [[ -d $dir ]] && { basename "$dir" | sed 's/^[0-9]*-//'; return; }; done
}

report_sessions() {
	local i frames elapsed expected drops fps branch
	for i in "${!PIDS[@]}"; do
		if [[ ${TAGS[$i]} == auto-tile-* ]]; then
			frames=$(awk -v tiles="${TAGS[$i]##*-}" 'NR==FNR{if($2=="tasks")a[$1]=$3;next} $2=="tasks"{n+=$3-a[$1]} END{print int(n/(tiles+1))}' "$CURRENT/cores.before" "$CURRENT/cores.after")
			elapsed=$(awk -v a="${START_NS[$i]}" -v b="$END_NS" 'BEGIN{printf "%.3f",(b-a)/1000000000}')
			expected=$(awk -v d="$elapsed" 'BEGIN{printf "%d",60*d}')
			drops=$((expected > frames ? expected - frames : 0))
			fps=$(awk -v n="$frames" -v d="$elapsed" 'BEGIN{printf "%.2f",n/d}')
			printf 'session=%s pid=%s fps=%s frames=%s drops=%s elapsed_s=%s target_fps=60\n' \
				"${TAGS[$i]}" "${PIDS[$i]}" "$fps" "$frames" "$drops" "$elapsed"
			continue
		fi
		if [[ ${TAGS[$i]} == one-process ]]; then
			elapsed=$(awk -v a="${START_NS[$i]}" -v b="$END_NS" 'BEGIN{printf "%.3f",(b-a)/1000000000}')
			for branch in a b; do
				frames=$(grep 'last-message = chain' "${LOGS[$i]}" | grep -c "GstIdentity:out_$branch" || true)
				expected=$(awk -v d="$elapsed" 'BEGIN{printf "%d",30*d}')
				drops=$((expected > frames ? expected - frames : 0))
				fps=$(awk -v n="$frames" -v d="$elapsed" 'BEGIN{printf "%.2f",n/d}')
				printf 'session=one-process-%s pid=%s fps=%s frames=%s drops=%s elapsed_s=%s target_fps=30\n' \
					"$branch" "${PIDS[$i]}" "$fps" "$frames" "$drops" "$elapsed"
			done
			continue
		fi
		frames=$(grep -c 'last-message = chain' "${LOGS[$i]}" 2>/dev/null || true)
		elapsed=$(awk -v a="${START_NS[$i]}" -v b="$END_NS" 'BEGIN{printf "%.3f",(b-a)/1000000000}')
		expected=$(awk -v r="${RATES[$i]}" -v d="$elapsed" 'BEGIN{printf "%d",r*d}')
		drops=$((expected > frames ? expected - frames : 0))
		fps=$(awk -v n="$frames" -v d="$elapsed" 'BEGIN{printf "%.2f",n/d}')
		printf 'session=%s pid=%s fps=%s frames=%s drops=%s elapsed_s=%s target_fps=%s\n' \
			"${TAGS[$i]}" "${PIDS[$i]}" "$fps" "$frames" "$drops" "$elapsed" "${RATES[$i]}"
	done
}

run_case() {
	local name=$1 mode=$2 start_journal elapsed_ns low_session='' i
	shift 2
	CURRENT="$OUT/$name"; mkdir -p "$CURRENT"
	PIDS=(); TAGS=(); RATES=(); START_NS=(); LOGS=()
	snapshot_cores "$CURRENT/cores.before"
	cp /proc/interrupts "$CURRENT/interrupts.before"
	journalctl -k -b --no-pager >"$CURRENT/journal.before"
	start_journal=$(wc -l <"$CURRENT/journal.before")
	enable_trace || { printf 'case=%s verdict=GATED reason=trace-events-unavailable\n' "$name"; return "$GATED"; }
	"$@"
	if [[ $mode == fixtures-one ]]; then
		sleep 2; cat /proc/mpp_service/load >"$OUT/fixtures/load-1-session.txt"
		pipe_args h265 3840 2160 30 30000000; launch b 30 "${PIPE[@]}"
		sleep 2
		cat /proc/mpp_service/load >"$OUT/fixtures/load-2-sessions.txt"
		cat /proc/mpp_service/sessions-summary >"$OUT/fixtures/sessions-summary-2-sessions.txt"
		cat /proc/rkrga/load >"$OUT/fixtures/rga-load.txt"
	elif [[ $mode == starvation ]]; then
		sleep 2
		pipe_args h264 1920 1080 30 12000000; launch low 30 "${PIPE[@]}"
		sleep 1; low_session=$(session_index_for_pid "${PIDS[1]}")
	fi
	monitor
	cp "$TRACEFS/trace" "$CURRENT/trace.txt"
	disable_trace
	snapshot_cores "$CURRENT/cores.after"
	cp /proc/interrupts "$CURRENT/interrupts.after"
	journalctl -k -b --no-pager >"$CURRENT/journal.after"
	sed -n "$((start_journal + 1)),\$p" "$CURRENT/journal.after" >"$CURRENT/journal.delta"
	elapsed_ns=$((END_NS - START_NS[0]))
	printf 'case=%s duration_s=%s cpu_pct=%s queue_depth_max=%s journal_errors=%s\n' \
		"$name" "$DURATION" "$CPU" "$QUEUE_MAX" \
		"$(grep -Eic 'WARNING:|BUG:|Oops|timeout|iommu.*fault|mpp.*error|rkvenc.*error' "$CURRENT/journal.delta" || true)"
	report_sessions
	core_deltas "$CURRENT/cores.before" "$CURRENT/cores.after" "$elapsed_ns"
	irq_deltas "$CURRENT/interrupts.before" "$CURRENT/interrupts.after"
	trace_rows "$CURRENT/trace.txt" | awk '{for(i=1;i<=NF;i++)if($i~/^core=/){c=$i;sub("core=","",c);n[c]++}}END{for(c in n)printf "selected_core=%s tasks=%d\n",c,n[c]}' | sort
	[[ $mode != starvation ]] || { kv low_session_index "$low_session"; trace_summary "$CURRENT/trace.txt" "$low_session"; }
	if perf list 2>/dev/null | grep -Eqi 'ddr|dram'; then
		kv memory_bandwidth 'available-but-not-sampled-no-stable-event-name'
	else
		kv memory_bandwidth 'OMITTED-no-DDR-perf-event-exposed'
	fi
}

case_1() {
	mkdir -p "$OUT/fixtures"
	printf 1000 | tee /proc/mpp_service/load_interval >/dev/null
	cat /proc/mpp_service/load >"$OUT/fixtures/load-idle.txt"
	pipe_args h265 3840 2160 30 30000000; launch a 30 "${PIPE[@]}"
}
case_2() { local i; for i in 1 2 3 4; do pipe_args h264 1920 1080 60 12000000; launch "s$i" 60 "${PIPE[@]}"; done; }
case_3() { pipe_args h265 3840 2160 60 45000000; launch h265-4k 60 "${PIPE[@]}"; pipe_args h264 1920 1080 60 12000000; launch h264-a 60 "${PIPE[@]}"; launch h264-b 60 "${PIPE[@]}"; }
case_4() {
	launch one-process 60 gst-launch-1.0 -v -e \
		videotestsrc is-live=true pattern=smpte ! video/x-raw,format=NV12,width=3840,height=2160,framerate=30/1 ! queue ! mpph265enc bps=30000000 ! identity name=out_a silent=false ! fakesink sync=false \
		videotestsrc is-live=true pattern=ball ! video/x-raw,format=NV12,width=3840,height=2160,framerate=30/1 ! queue ! mpph265enc bps=30000000 ! identity name=out_b silent=false ! fakesink sync=false
}
case_5_mode() {
	local value=$1 input="$OUT/4k-nv12-sparse.raw"
	truncate -s 1244160000000 "$input"
	launch "auto-tile-$value" 60 env auto_tile="$value" "$MPP_ENC_TEST" -i "$input" -o /dev/null -w 3840 -h 2160 -f 0 -t 16777220 -n 100000
}
case_6() { pipe_args h265 3840 2160 60 45000000; launch saturating 60 "${PIPE[@]}"; }

main() {
	while (($#)); do
		case $1 in
		--duration) DURATION=${2:-}; shift 2;; --out) OUT=${2:-}; shift 2;;
		--scenario) SCENARIO=${2:-}; shift 2;; --mpp-enc-test) MPP_ENC_TEST=${2:-}; shift 2;;
		--self-test) self_test; exit $?;; -h|--help) usage; exit "$USAGE";; *) usage; exit "$USAGE";; esac
	done
	[[ $DURATION =~ ^[0-9]+$ && $DURATION -gt 0 ]] || { usage; exit "$USAGE"; }
	require_board || exit $?
	OUT=${OUT:-/tmp/dual-core-matrix-$(date -u +%Y%m%dT%H%M%SZ)}; mkdir -p "$OUT"
	trap disable_trace EXIT
	kv board_model "$(tr -d '\000' </proc/device-tree/model)"; kv kernel "$(uname -r)"; kv run_dir "$OUT"
	if [[ $SCENARIO == all || $SCENARIO == 1 ]]; then run_case 1-2x4k30-h265 fixtures-one case_1; fi
	if [[ $SCENARIO == all || $SCENARIO == 2 ]]; then run_case 2-4x1080p60-h264 normal case_2; fi
	if [[ $SCENARIO == all || $SCENARIO == 3 ]]; then run_case 3-mixed normal case_3; fi
	if [[ $SCENARIO == all || $SCENARIO == 4 ]]; then run_case 4-one-process normal case_4; fi
	if [[ $SCENARIO == all || $SCENARIO == 5 ]]; then
		[[ -x $MPP_ENC_TEST ]] || { printf 'case=5-auto-tile verdict=GATED reason=patched-mpi-enc-test-required\n'; [[ $SCENARIO == all ]] || exit "$GATED"; }
		if [[ -x $MPP_ENC_TEST ]]; then run_case 5-auto-tile-off normal case_5_mode 0; run_case 5-auto-tile-on normal case_5_mode 1; fi
	fi
	if [[ $SCENARIO == all || $SCENARIO == 6 ]]; then run_case 6-starvation starvation case_6; fi
	printf 'VERDICT: PASS (requested matrix scenarios completed; score from emitted measurements)\n'
}

main "$@"
