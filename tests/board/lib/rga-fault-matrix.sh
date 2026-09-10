#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Sourced by fault-matrix.sh; its journal and snapshot scorers are shared.

RGA_DEBUG=/sys/kernel/debug/rockchip-rga
RGA_FAULT_DEBUG=/sys/kernel/debug/rga-test
RGA_RESET=/sys/kernel/debug/rkrga/reset
readonly RGA_KNOBS=(irq_timeout_once inject_iommu_fault_once hang_task_once fail_reset_once)

rga_counter_for_row() {
	case "$1" in
	rga-irq-timeout) printf 'irq_timeout_once' ;;
	rga-iommu-fault) printf 'inject_iommu_fault_once' ;;
	rga-hardware-hang) printf 'hang_task_once' ;;
	rga-reset-failure) printf 'fail_reset_once' ;;
	*) return "$USAGE" ;;
	esac
}

rga_seam_inventory() {
	local knob expected actual
	for knob in "${RGA_KNOBS[@]}"; do
		[[ -r $RGA_FAULT_DEBUG/$knob && -w $RGA_FAULT_DEBUG/$knob && $(<"$RGA_FAULT_DEBUG/$knob") == 0 ]] || return "$GATED"
		[[ $(stat -c %a "$RGA_FAULT_DEBUG/$knob") == 600 ]] || return "$GATED"
		[[ -r $RGA_FAULT_DEBUG/${knob}_consumed && $(stat -c %a "$RGA_FAULT_DEBUG/${knob}_consumed") == 400 ]] || return "$GATED"
	done
	expected=$(printf '%s\n' "${RGA_KNOBS[@]}" "${RGA_KNOBS[@]/%/_consumed}" | LC_ALL=C sort)
	actual=$(find "$RGA_FAULT_DEBUG" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort) || return "$GATED"
	[[ $expected == "$actual" ]]
}

rga_clear_faults() {
	local knob rc=0
	for knob in "${RGA_KNOBS[@]}"; do
		printf '0\n' >"$RGA_FAULT_DEBUG/$knob" || rc=1
	done
	return "$rc"
}

rga_snapshot() {
	local dest=$1 core metric value knob count=0
	{
		for core in "$RGA_DEBUG"/cores/*; do
			[[ -d $core ]] || continue
			count=$((count + 1))
			for metric in busy_ns tasks errors resets; do
				value=$(<"$core/$metric") || return "$FAIL"
				[[ $value =~ ^[0-9]+$ ]] || return "$FAIL"
				printf '%s %s %s\n' "${core##*/}" "$metric" "$value"
			done
		done
		((count > 0)) || return "$FAIL"
		value=$(<"$RGA_DEBUG/queue_depth") || return "$FAIL"
		[[ $value =~ ^[0-9]+$ ]] || return "$FAIL"
		printf 'global queue_depth %s\n' "$value"
		value=$(awk '/^Total [0-9]+ objects/{print $2}' /sys/kernel/debug/dma_buf/bufinfo) || return "$FAIL"
		[[ $value =~ ^[0-9]+$ ]] || return "$FAIL"
		printf 'global dmabufs %s\n' "$value"
		printf 'global busy GAP:no-busy-counter\nglobal iommu_maps GAP:no-iommu_maps-counter\n'
		for knob in "${RGA_KNOBS[@]}"; do
			value=$(<"$RGA_FAULT_DEBUG/${knob}_consumed") || return "$FAIL"
			[[ $value =~ ^[0-9]+$ ]] || return "$FAIL"
			printf 'fault %s_consumed %s\n' "$knob" "$value"
		done
	} >"$dest"
}

rga_probe() {
	timeout --kill-after=2 10 "$PROBE_RGA" >"$1" 2>&1
}

rga_clean_blit() {
	rga_probe "$1" && grep -q '^blit_sync=ok ' "$1"
}

rga_stimulate() {
	local name=$1 knob core rc=0 expected_errno=16
	knob=$(rga_counter_for_row "$name") || return "$USAGE"
	printf '1\n' >"$RGA_FAULT_DEBUG/$knob" || return "$FAIL"
	if [[ $name == rga-reset-failure ]]; then
		core=$(awk '/ core <[0-9]+>/{gsub(/[<>]/,"",$NF); print $NF; exit}' "$RGA_RESET") || return "$FAIL"
		[[ $core =~ ^[0-9]+$ ]] || return "$GATED"
		LC_ALL=C bash -c 'printf "%s\n" "$1" >"$2"' _ "$core" "$RGA_RESET" >"$OUT/$name.stimulus" 2>&1 || rc=$?
		((rc != 0)) && grep -q 'Input/output error' "$OUT/$name.stimulus"
	else
		[[ $name != rga-iommu-fault ]] || expected_errno=13
		rga_probe "$OUT/$name.stimulus" || return "$FAIL"
		# The probe's exit zero means answered, NOT that its blit succeeded.
		grep -q "^blit_sync=error errno=$expected_errno " "$OUT/$name.stimulus"
	fi
}

rga_matrix_rows() {
	local name before after rc i
	for name in "${RGA_ROWS[@]}"; do
		[[ $ROW == all || $ROW == "$name" ]] || continue
		ROW_SINCE=$(date +%s)
		before="$OUT/$name.before"; after="$OUT/$name.after"
		SCORE_REASON=preflight-blit; rc=0
		rga_clean_blit "$OUT/$name.preflight" || rc=$GATED
		if ((rc == 0)); then
			SCORE_REASON=snapshot
			rga_snapshot "$before" || rc=$FAIL
		fi
		if ((rc == 0)); then
			SCORE_REASON=stimulus
			rga_stimulate "$name" || rc=$?
		fi
		if ! rga_clear_faults; then SCORE_REASON=disarm; rc=$FAIL; fi
		if ((rc == 0)); then
			SCORE_REASON=recovery-blit
			rga_clean_blit "$OUT/$name.clean" || rc=$FAIL
		fi
		if ((rc == 0)); then
			SCORE_REASON=snapshot
			for ((i=0; i<30; i++)); do
				rga_snapshot "$after" || { rc=$FAIL; break; }
				snapshot_quiesced "$after" "$before" && break
				sleep 0.5
			done
		fi
		if ! fatal_check "$name" "$ROW_SINCE"; then rc=$FAIL; fi
		if ((rc == 0)); then
			score_snapshots "$before" "$after" "$before" "$OUT/$name.journal" "$name" || rc=$FAIL
		fi
		case $rc in
		0) printf 'row=%s verdict=SURVIVE reset_delta=%s journal_bad=0 gaps=%s\n' "$name" "$SCORE_RESET_DELTA" "$SCORE_GAPS" ;;
		77) printf 'row=%s verdict=GATED reason=%s\n' "$name" "$SCORE_REASON"; return "$GATED" ;;
		*) printf 'row=%s verdict=FAIL reason=%s\n' "$name" "$SCORE_REASON"; return "$FAIL" ;;
		esac
	done
}

rga_matrix_main() {
	local active cfg
	[[ $ROW == all || " ${RGA_ROWS[*]} " == *" $ROW "* ]] || return "$USAGE"
	[[ ${CERALIVE_BOARD_TEST:-0} == 1 && $EUID == 0 ]] || return "$GATED"
	[[ -x $PROBE_RGA && -d $RGA_DEBUG/cores && -d $RGA_DEBUG/sessions && -w $RGA_RESET ]] || return "$GATED"
	for cfg in CONFIG_KASAN=y CONFIG_PROVE_LOCKING=y CONFIG_ROCKCHIP_RGA_CERALIVE_TEST=y; do
		zgrep -qx "$cfg" /proc/config.gz || return "$GATED"
	done
	rga_seam_inventory || return "$GATED"
	active=$(find "$RGA_DEBUG/sessions" -mindepth 1 -maxdepth 1 -print) || return "$GATED"
	[[ -z $active ]] || return "$GATED"
	[[ ! -r /proc/lockdep_stats ]] || grep -q '^ debug_locks: *1$' /proc/lockdep_stats || return "$GATED"
	OUT=${OUT:-/tmp/rga-fault-matrix-$(date -u +%Y%m%dT%H%M%SZ)}
	mkdir "$OUT" || return "$FAIL"
	{ printf 'board='; tr -d '\0' </proc/device-tree/model; printf '\nkernel='; uname -a; printf 'driver=island-rga\n'; } >"$OUT/identity.txt"
	trap rga_clear_faults EXIT
	rga_matrix_rows
}

rga_matrix_self_test() (
	local scratch=$1 name knob mode rc
	local gaps='busy=GAP:no-busy-counter,iommu_maps=GAP:no-iommu_maps-counter'
	[[ ${RGA_ROWS[*]} == 'rga-irq-timeout rga-iommu-fault rga-hardware-hang rga-reset-failure' ]] || return "$FAIL"
	OUT="$scratch/rga"; mkdir -p "$OUT"
	RGA_FAULT_DEBUG="$OUT/seam"; mkdir "$RGA_FAULT_DEBUG"
	for knob in "${RGA_KNOBS[@]}"; do
		printf '0\n' >"$RGA_FAULT_DEBUG/$knob"
	done
	for name in "${RGA_ROWS[@]}"; do
		knob=$(rga_counter_for_row "$name") || return "$FAIL"
		printf '0 resets 10\nglobal queue_depth 0\nglobal dmabufs 3\nglobal busy GAP:no-busy-counter\nglobal iommu_maps GAP:no-iommu_maps-counter\nfault %s_consumed 2\n' "$knob" >"$OUT/before"
		: >"$OUT/journal"
		for mode in good missed double busy reset journal; do
			cp "$OUT/before" "$OUT/after"
			awk -v mode="$mode" '$2=="resets"&&mode!="reset"{$3++} $1=="fault"{if(mode!="missed")$3++;if(mode=="double")$3++} $2=="queue_depth"&&mode=="busy"{$3=1}1' "$OUT/before" >"$OUT/after"
			: >"$OUT/journal"
			[[ $mode != journal ]] || printf 'BUG: synthetic fault\n' >"$OUT/journal"
			rc=0
			score_snapshots "$OUT/before" "$OUT/after" "$OUT/before" "$OUT/journal" "$name" || rc=$?
			if [[ $mode == good || ( $mode == reset && $name == rga-reset-failure ) ]]; then
				[[ $rc == 0 && $SCORE_GAPS == "$gaps" ]] || return "$FAIL"
			else
				[[ $rc == "$FAIL" ]] || return "$FAIL"
			fi
		done
		printf 'self-test=%s PASS synthetic-scoring-and-mutations\n' "$name"
	done
	rga_clear_faults || return "$FAIL"
	for knob in "${RGA_KNOBS[@]}"; do
		[[ $(<"$RGA_FAULT_DEBUG/$knob") == 0 ]] || return "$FAIL"
	done
	RGA_RESET="$OUT/reset"
	printf 'rga3 core <1>\n' >"$RGA_RESET"
	rga_probe() {
		case "$mode" in
		good)
			if [[ $name == rga-iommu-fault ]]; then
				printf 'blit_sync=error errno=13 (Permission denied)\n' >"$1"
			else
				printf 'blit_sync=error errno=16 (Device or resource busy)\n' >"$1"
			fi ;;
		wrong) printf 'blit_sync=error errno=22 (Invalid argument)\n' >"$1" ;;
		success) printf 'blit_sync=ok geometry=640x360\n' >"$1" ;;
		esac
	}
	bash() {
		[[ $mode != good ]] || { printf 'Input/output error\n' >&2; return 1; }
		return 0
	}
	for name in "${RGA_ROWS[@]}"; do
		knob=$(rga_counter_for_row "$name")
		for mode in good wrong success; do
			rga_clear_faults || return "$FAIL"
			rc=0; rga_stimulate "$name" || rc=$?
			[[ $(<"$RGA_FAULT_DEBUG/$knob") == 1 ]] || return "$FAIL"
			if [[ $mode == good ]]; then
				[[ $rc == 0 ]] || return "$FAIL"
			else
				[[ $rc != 0 ]] || return "$FAIL"
			fi
		done
	done
	printf 'self-test=rga-stimuli PASS knob-routing-and-errno-rejection\n'
)
