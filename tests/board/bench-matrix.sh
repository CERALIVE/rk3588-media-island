#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -uo pipefail
HERE=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")

parse_cells() {
	local line header=0
	local -A seen=()
	while IFS= read -r line || [[ -n $line ]]; do
		[[ -z $line || $line == \#* ]] && continue
		if [[ $line == cells: && $header == 0 ]]; then header=1; continue; fi
		[[ $header == 1 && $line =~ ^\ \ -\ \'([a-zA-Z0-9\|.-]+)\'$ ]] || return 2
		local row=${BASH_REMATCH[1]}
		local id mode codec input output width height rate streams seconds core operation extra
		IFS='|' read -r id mode codec input output width height rate streams seconds core operation extra <<< "$row"
		[[ $id =~ ^[a-z0-9][a-z0-9-]+$ && -z ${extra:-} ]] || return 2
		[[ ! ${seen[$id]+present} ]] || return 2
		seen[$id]=1
		if [[ $mode == NO-SOURCE || $mode == EXCLUDED || $mode == latency ]]; then
			[[ $row == "$id|$mode" ]] || return 2
		else
			[[ $row == "$id|$mode|$codec|$input|$output|$width|$height|$rate|$streams|$seconds|$core|$operation" ]] || return 2
			[[ $mode == encode || $mode == rga || $mode == hdmi ]] || return 2
			[[ $codec == h264 || $codec == h265 ]] || return 2
			[[ $input == NV12 || $input == NV16 || $input == RGB ]] || return 2
			[[ $output == NV12 || $output == RGB ]] || return 2
			[[ $operation =~ ^(copy|crop|scale|rotate|csc|combined)$ ]] || return 2
			for value in "$width" "$height" "$rate" "$streams" "$seconds" "$core"; do
				[[ $value =~ ^(0|[1-9][0-9]{0,3})$ ]] || return 2
			done
			(( width > 0 && width <= 3840 && height > 0 && height <= 2160 && width % 2 == 0 && height % 2 == 0 && rate <= 240 && streams >= 1 && streams <= 8 && seconds >= 1 && seconds <= 120 )) || return 2
			[[ $core == 0 || $core == 1 || $core == 2 || $core == 4 ]] || return 2
		fi
		printf '%s\n' "$row"
	done < "$1"
	[[ $header == 1 ]] || return 2
}

prepare_cell() {
	if [[ -d $1 ]]; then mv -- "$1" "$1.interrupted-$(date +%s%N)" || return 1; fi
	mkdir -- "$1"
}

interrupt() {
	trap - INT TERM
	if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; pid=; fi
	if [[ -n ${id:-} && -d $out/$id && ! -f $out/$id/result ]]; then
		printf 'CANCELLED\n' > "$out/$id/result.tmp"
		mv -- "$out/$id/result.tmp" "$out/$id/result"
	fi
	exit "$1"
}

snapshot() {
	local f
	printf 'UPTIME '; cat /proc/uptime
	for f in /sys/kernel/debug/rockchip-{mpp,rga}/cores/*/{busy_ns,tasks,errors,resets} /sys/class/thermal/thermal_zone*/temp /sys/class/thermal/cooling_device*/cur_state; do
		[[ -f $f ]] || continue
		printf '%s=' "$f"; cat "$f" || return 1
	done
	cat /proc/interrupts || return 1
}

self_test() {
	local tmp rc=0 rows
	tmp=$(mktemp -d) || return 1
	rows=$(parse_cells "$HERE/bench-matrix.yaml") || rc=1
	[[ $(printf '%s\n' "$rows" | sort | uniq -d | wc -l) == 0 && -n $rows ]] || rc=1
	printf 'cells:\n  - '\''bad|encode|h264|P010|NV12|1920|1080|60|1|8|0|copy'\''\n' > "$tmp/bad.yaml"
	if parse_cells "$tmp/bad.yaml" >/dev/null; then rc=1; fi
	printf 'cells:\n  - '\''bad|encode|h264|NV12|NV12|1920|1080|60|0|8|0|copy'\''\n' > "$tmp/bad.yaml"
	if parse_cells "$tmp/bad.yaml" >/dev/null; then rc=1; fi
	printf 'cells:\n  - '\''bad;touch|NO-SOURCE'\''\n' > "$tmp/bad.yaml"
	if parse_cells "$tmp/bad.yaml" >/dev/null; then rc=1; fi
	printf 'cells:\n  - '\''same|NO-SOURCE'\''\n  - '\''same|EXCLUDED'\''\n' > "$tmp/bad.yaml"
	if parse_cells "$tmp/bad.yaml" >/dev/null; then rc=1; fi
	mkdir "$tmp/partial"
	printf 'stale sample\n' > "$tmp/partial/samples"
	prepare_cell "$tmp/partial" || rc=1
	[[ ! -e $tmp/partial/samples ]] || rc=1
	( out=$tmp; id=cancelled; mkdir "$out/$id"; sleep 30 & pid=$!; interrupt 130 )
	[[ $? == 130 && $(cat "$tmp/cancelled/result") == CANCELLED ]] || rc=1
	rm -rf -- "$tmp"
	printf 'bench-matrix schema self-test rc=%s (valid, 10-bit, zero streams, injection)\n' "$rc"
	return "$rc"
}

if [[ ${1:-} == --self-test && $# == 1 ]]; then self_test; exit $?; fi
if [[ ${1:-} == --list && $# == 1 ]]; then parse_cells "$HERE/bench-matrix.yaml"; exit $?; fi
if [[ ${1:-} == --score && $# == 2 ]]; then exec bun "$HERE/bench-report.mjs" "$2"; fi
if [[ $# != 3 || ( $1 != --run-rock && $1 != --run-opi ) ]]; then
	printf 'usage: bench-matrix.sh --self-test | --list | --run-rock|--run-opi PROBE OUTPUT\n' >&2
	exit 2
fi
[[ ${CERALIVE_BOARD_TEST:-} == 1 && -f /tmp/ceralive-board-session ]] || exit 77
[[ $(uname -m) == aarch64 && -c /dev/dma_heap/system && -x $2 ]] || exit 77
probe=$(readlink -f -- "$2")
out=$3
[[ $out == /tmp/* && $out != *..* ]] || exit 2
rows=$(parse_cells "$HERE/bench-matrix.yaml") || exit 2
mkdir -p -- "$out" || exit 1
exec 8>"$out/run.lock"
flock -n 8 || exit 75
identity=$(sha256sum "$probe" "$HERE/bench-matrix.yaml" "$HERE/bench-matrix.sh" /proc/sys/kernel/random/boot_id /usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstrockchipmpp.so /usr/lib/aarch64-linux-gnu/librga.so.2 /usr/lib/aarch64-linux-gnu/librockchip_mpp.so.0 "$(modinfo -n rk_vcodec)" "$(modinfo -n rga_multicore)") || exit 1
identity+=" selector=${BENCH_CELL_PREFIX:-all} board=$1"
if [[ -f $out/identity ]]; then
	[[ $(cat "$out/identity") == "$identity" ]] || { printf 'STALE-IDENTITY\n' >&2; exit 1; }
else
	printf '%s\n' "$identity" > "$out/identity" || exit 1
fi
export GST_REGISTRY_UPDATE=no GST_DEBUG_NO_COLOR=1 GST_MPP_ALLOW_CPU_COPY=0 GST_MPP_NO_RGA=0
failed=0
pid=
trap 'if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi' EXIT
trap 'interrupt 130' INT
trap 'interrupt 143' TERM
while IFS='|' read -r id mode codec input output width height rate streams seconds core operation; do
	[[ -n ${BENCH_CELL_PREFIX:-} && $id != "$BENCH_CELL_PREFIX"* ]] && continue
	if [[ -f $out/$id/result && $(cat "$out/$id/result") != CANCELLED ]]; then
		case $(cat "$out/$id/result") in
		'source_rc=0 cell_rc=0'|NO-SOURCE|EXCLUDED) ;;
		*) failed=1 ;;
		esac
		printf 'RESUME %s\n' "$id"; continue
	fi
	prepare_cell "$out/$id" || exit 1
	printf 'START %s uptime=%s\n' "$id" "$(cut -d' ' -f1 /proc/uptime)"
	if [[ $1 == --run-rock && ( $mode == hdmi || $mode == latency ) ]]; then mode=NO-SOURCE; fi
	if [[ $mode == latency ]]; then
		gst-inspect-1.0 timeoverlay > "$out/$id/prerequisite.log" 2>&1
		printf 'timeoverlay_rc=%s; requires timeoverlay plus host decode, no substitute\n' "$?" >> "$out/$id/prerequisite.log"
		printf 'PREREQUISITE-FAIL\n' > "$out/$id/result"
		printf 'DONE %s PREREQUISITE-FAIL\n' "$id"
		failed=1
		continue
	fi
	if [[ $mode == NO-SOURCE || $mode == EXCLUDED ]]; then
		printf '%s\n' "$mode" > "$out/$id/result.tmp"
	else
		cursor=$(journalctl -k -b -n 1 --show-cursor --no-pager | sed -n 's/^-- cursor: //p')
		[[ -n $cursor ]] || exit 1
		source_mode=source; source_rate=0
		if [[ $mode == hdmi ]]; then
			source_mode=hdmi-source; source_rate=$rate
			v4l2-ctl -d /dev/video0 --query-dv-timings --set-dv-bt-timings query > "$out/$id/timings.log" 2>&1 || exit 1
		fi
		timeout --kill-after=5 15 "$probe" "$source_mode" "$codec" "$input" "$output" "$width" "$height" "$source_rate" "$streams" 3 "$core" "$operation" > "$out/$id/source.log" 2>&1 &
		pid=$!
		wait "$pid"
		source_rc=$?
		pid=
		snapshot > "$out/$id/before" || exit 1
		timeout --kill-after=5 "$((seconds + 40))" "$probe" "$mode" "$codec" "$input" "$output" "$width" "$height" "$rate" "$streams" "$seconds" "$core" "$operation" > "$out/$id/cell.log" 2>&1 &
		pid=$!
		while kill -0 "$pid" 2>/dev/null; do
			snapshot >> "$out/$id/samples" || exit 1
			sleep 1
		done
		wait "$pid"; cell_rc=$?
		pid=
		snapshot > "$out/$id/after" || exit 1
		journalctl -k -b --after-cursor "$cursor" --no-pager -o short-monotonic > "$out/$id/journal" || exit 1
		grep -E 'BUG:|Oops:|Kernel panic|Call trace:|WARNING:|SError' "$out/$id/journal" > "$out/$id/fatal"
		journal_rc=$?
		if (( journal_rc != 1 )); then
			printf 'FATAL-JOURNAL scanner_rc=%s\n' "$journal_rc" > "$out/$id/result.tmp"
			mv -- "$out/$id/result.tmp" "$out/$id/result" || exit 1
			exit 1
		fi
		printf 'source_rc=%s cell_rc=%s\n' "$source_rc" "$cell_rc" > "$out/$id/result.tmp"
		if (( source_rc != 0 || cell_rc != 0 )); then failed=1; fi
	fi
	mv -- "$out/$id/result.tmp" "$out/$id/result" || exit 1
	printf 'DONE %s %s\n' "$id" "$(cat "$out/$id/result")"
done <<< "$rows"
printf 'MATRIX_FINISHED failures=%s\n' "$failed"
exit "$failed"
