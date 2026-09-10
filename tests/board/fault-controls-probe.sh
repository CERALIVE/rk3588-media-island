#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# fault-controls-probe.sh — prove the five fault controls that NO matrix row
# consumes actually fire, exactly once, on a live board.
#
# WHY THIS EXISTS. fault-matrix.sh arms four of the nine one-shot fault controls
# (hang_task_once, inject_iommu_fault_once, fail_reset_once and the completion
# delay). The other five — fail_session_alloc_once, fail_clock_enable_once,
# fail_service_attach_once, fail_ccu_attach_once and fail_irq_request_once —
# have never been observed firing on island silicon, because the matrix
# structurally never arms them. That is docs/FAULT-SEAM-CONTRACT.md T3(i) and
# T3(ii), and it means a nine-control coverage claim rests on five controls nobody has
# seen work. A control that has never fired may not fire at all, and a fault seam
# that silently ignores a knob produces a clean run and a green transcript. This
# drill is the missing half.
#
# EVERY ROW ASSERTS FIRING BEFORE IT ASSERTS ANYTHING ELSE. The consumed counter
# must move by exactly one — not zero, and not two — and the one-shot knob must
# have reset itself. Only then does the row look at the errno, the recovery
# encode and the kernel journal.
#
# Contract, per tests/board/README.md rules 1-4:
#   0   every selected row fired exactly once and the device recovered
#   1   a row ran and an assertion did not hold
#   2   usage
#   77  gated — a precondition was unmet. NEVER counted as a pass.
#
# Usage:
#   fault-controls-probe.sh [--driver island|auto] [--out DIR]
#                           [--row NAME|all] [--probe-mpp FILE]
#                           [--invalid-ioctl FILE]
#   fault-controls-probe.sh --self-test    # host-side; no board, no root
#
# Rows: session-alloc clock-enable service-attach ccu-attach irq-request
#
# The last three only fire inside the driver's probe path, so proving them means
# detaching and reattaching one encoder core through its platform-bus driver
# directory. Those two writes are the ONLY board-state mutation in this file and
# they are an explicit, named exception to rule 4 — the paragraph in
# tests/board/README.md states exactly which writes happen and under which
# preconditions. The device name is read off the bus at run time: the encoder
# core addresses are RK3588 device-tree facts, not driver facts, and a hardcoded
# path selects nothing after a respin, which reads exactly like a pass.

set -uo pipefail

readonly FAIL=1 USAGE=2 GATED=77

readonly ROWS=(session-alloc clock-enable service-attach ccu-attach irq-request)
readonly IDLE_FILES=(inject_iommu_fault_idle_ms inject_iommu_fault_idle_consumed
	inject_iommu_fault_idle_fired inject_iommu_fault_idle_state)
IDLE_SNAPSHOT_FN=idle_snapshot
IDLE_WAIT_FN=idle_wait
IDLE_QUIET_FN=idle_no_encode

# Knob, expected errno and probe-time class per row. The counter is ALWAYS
# "<knob>_consumed" for these five: all of them are flag knobs registered through
# mpp_rkvenc_test_add_flag, which synthesises the counter from the full knob name
# (docs/FAULT-SEAM-CONTRACT.md T1). The hand-registered delay knob, whose counter
# is `delay_consumed` and breaks that pattern, is a matrix control and is not a
# row here — so this file needs no special case and must never grow one.
declare -rA KNOB=(
	[session-alloc]=fail_session_alloc_once
	[clock-enable]=fail_clock_enable_once
	[service-attach]=fail_service_attach_once
	[ccu-attach]=fail_ccu_attach_once
	[irq-request]=fail_irq_request_once
)
declare -rA ERRNO=(
	[session-alloc]=ENOMEM
	[clock-enable]=EIO
	[service-attach]=ENOMEM
	[ccu-attach]=ENODEV
	[irq-request]=EBUSY
)
readonly PROBE_TIME_ROWS=(service-attach ccu-attach irq-request)

# A failed attach is reported to userspace as the errno of the write(2) that
# triggered it, and the shell prints that as a strerror sentence. The two never
# look alike, so the mapping is data.
declare -rA STRERROR_TEXT=(
	[ENOMEM]='Cannot allocate memory'
	[ENODEV]='No such device'
	[EBUSY]='Device or resource busy'
	[EIO]='Input/output error'
)

# The kernel configuration symbol that proves the seam is compiled in, per
# driver profile.
declare -rA SEAM_SYMBOL=(
	[island]=CONFIG_ROCKCHIP_MPP_CERALIVE_TEST
)

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly HERE

# The contract's facts are Markdown code spans, so the patterns below have to
# match a backtick. Spelling one inside a quoted pattern is SC2016, so it is
# built instead — do not "simplify" this back to a literal.
BT=$(printf '\140')
readonly BT

# Seam locations. Assignable rather than readonly so --self-test can point the
# whole drill at a synthetic tree; on a board they are never overridden.
MPP_DEBUG=/sys/kernel/debug/rockchip-mpp
FAULT_DEBUG=/sys/kernel/debug/rkvenc-test
DRV_BUS=/sys/bus/platform/drivers
DRV_DIR=
MPP_DEVICE=/dev/mpp_service
EXPECT_TABLE="$HERE/../expected-errno.tsv"
CONTRACT_DOC="$HERE/../../docs/FAULT-SEAM-CONTRACT.md"

DRIVER=auto
OUT=
ROW=all
PROBE_MPP=
INVALID_IOCTL=
REBIND_DEV=

# Every board-touching operation goes through a named hook so --self-test can
# substitute a synthetic driver. On a board these are never reassigned.
ENCODE_FN=board_encode
IOCTL_FN=board_invalid_ioctl
JOURNAL_FN=board_journal
BIND_FN=board_bind
UNBIND_FN=board_unbind
CONFIG_FN=board_config_has
CAPABILITY_FN=board_capability

usage() {
	printf 'usage: %s [--driver island|auto] [--out DIR] [--row NAME|all]\n' "$0" >&2
	printf '       %*s [--probe-mpp FILE] [--invalid-ioctl FILE]\n' "${#0}" '' >&2
	printf '       %s --self-test\n' "$0" >&2
	printf 'rows: %s\n' "${ROWS[*]}" >&2
	printf 'explicit idle-only row: idle-iommu-fault (not part of --row all)\n' >&2
}

# ---------------------------------------------------------------------------
# Snapshot and metric idioms, taken from fault-matrix.sh:28-49 and :108-110.
#
# One deliberate difference: an unreadable per-core metric is recorded as a
# `gap` line instead of aborting the snapshot with 77. The contract's T4
# vocabulary says an unavailable metric is a labelled gap, never a silent pass
# and never a fabricated gate.
# ---------------------------------------------------------------------------

snapshot() {
	local dest=$1 core metric counter
	{
		for core in "$MPP_DEBUG"/cores/*; do
			[[ -d $core ]] || continue
			for metric in busy busy_ns tasks errors resets; do
				if [[ -r $core/$metric ]]; then
					printf '%s %s %s\n' "$(basename "$core")" "$metric" "$(<"$core/$metric")"
				else
					printf 'gap %s no-%s-counter\n' "$metric" "$metric"
				fi
			done
		done
		if [[ -r $MPP_DEBUG/queue_depth ]]; then
			printf 'global queue_depth %s\n' "$(<"$MPP_DEBUG/queue_depth")"
		else
			printf 'gap queue_depth no-queue_depth-counter\n'
		fi
		for counter in "$FAULT_DEBUG"/*consumed; do
			[[ -r $counter ]] && printf 'fault %s %s\n' "$(basename "$counter")" "$(<"$counter")"
		done
	} >"$dest"
}

metric_sum() {
	awk -v metric="$2" '$2==metric{sum+=$3}END{print sum+0}' "$1"
}

metric_present() {
	awk -v metric="$2" '$2==metric{found=1}END{exit !found}' "$1"
}

gap_names() {
	awk '$1=="gap"{print $3}' "$1" | sort -u | paste -sd, -
}

arm() {
	printf '%s\n' "$2" >"$FAULT_DEBUG/$1"
}

knob_value() {
	[[ -r $FAULT_DEBUG/$1 ]] || return 1
	printf '%s' "$(<"$FAULT_DEBUG/$1")"
}

counter_delta() {
	local before=$1 after=$2 key=$3 b a
	b=$(awk -v k="$key" '$1=="fault"&&$2==k{print $3}' "$before")
	a=$(awk -v k="$key" '$1=="fault"&&$2==k{print $3}' "$after")
	[[ -n $b && -n $a ]] || return 1
	printf '%s' "$((a - b))"
}

# The screen every row runs over its own journal window, verbatim from
# fault-matrix.sh:227. A sanitizer or lockdep report during an INJECTED failure
# is the defect this whole drill exists to find.
journal_bad_count() {
	local file=$1 bad rc
	[[ -f $file && -r $file ]] || return "$FAIL"
	# Unprefixed reader diagnostics are not kernel records. Do not let an
	# error-only capture (even with exit 0) masquerade as an empty window.
	LC_ALL=C grep -Ei '^[[:space:]]*(journalctl:[[:space:]]*)?(journal read failed|Failed to (open|read|seek|iterate|get)|No journal files were found|Hint: You are currently not seeing)' "$file" >/dev/null
	rc=$?
	((rc == 1)) || return "$FAIL"
	bad=$(grep -Eic 'WARNING:|BUG:|KASAN:|possible recursive locking|inconsistent lock state|Oops' "$file")
	rc=$?
	((rc <= 1)) && [[ $bad =~ ^[0-9]+$ ]] || return "$FAIL"
	printf '%s\n' "$bad"
}

# ---------------------------------------------------------------------------
# Board hooks
# ---------------------------------------------------------------------------

board_encode() {
	gst-launch-1.0 -q videotestsrc num-buffers=30 \
		! video/x-raw,format=NV12,width=1280,height=720 \
		! mpph264enc ! fakesink >"$1" 2>&1
}

board_invalid_ioctl() {
	"$INVALID_IOCTL" --device "$MPP_DEVICE" --debugfs "$FAULT_DEBUG" \
		--expect-table "$EXPECT_TABLE" \
		--case session-allocation-failure >"$1" 2>&1
}

board_journal() {
	LC_ALL=C journalctl -k -b --since "@$1" --no-pager >"$2" 2>&1
}

# The write is what carries the errno, so its diagnostic is captured rather than
# discarded. C locale, because the assertion reads an English strerror sentence.
sysfs_write() {
	local file=$1 value=$2
	( LC_ALL=C; printf '%s\n' "$value" >"$file" ) 2>&1
}

board_bind()   { sysfs_write "$DRV_DIR/bind" "$1"; }
board_unbind() { sysfs_write "$DRV_DIR/unbind" "$1"; }

board_config_has() {
	zgrep -qx "$1=y" /proc/config.gz
}

# The probe must assert the exact island client inventory.
board_capability() {
	"$PROBE_MPP" --expect-island >"$1" 2>&1
}

errno_from_message() {
	local msg=$1 name
	for name in "${!STRERROR_TEXT[@]}"; do
		if [[ $msg == *"${STRERROR_TEXT[$name]}"* ]]; then
			printf '%s' "$name"
			return 0
		fi
	done
	return 1
}

# ---------------------------------------------------------------------------
# Contract-derived facts (docs/FAULT-SEAM-CONTRACT.md T1)
# ---------------------------------------------------------------------------

# The recorded bind-attribute verdict. The three probe-time rows are permitted
# only when the contract says the driver leaves bind and unbind attributes in
# place; a drill that decided that for itself would be deciding it from the same
# assumption the contract exists to record.
contract_bind_attr_yes() {
	[[ -r $CONTRACT_DOC ]] || return 1
	grep -Eq "^\| *${BT}bind-attr${BT}[^|]*\| *\*\*yes\*\*" "$CONTRACT_DOC"
}

contract_driver_name() {
	[[ -r $CONTRACT_DOC ]] || return 1
	local name
	name=$(sed -n "s/^| *driver name[^|]*| *${BT}\([A-Za-z0-9_.-]\+\)${BT} *|.*/\1/p" "$CONTRACT_DOC" | head -1)
	[[ -n $name ]] || return 1
	printf '%s' "$name"
}

# ---------------------------------------------------------------------------
# Bus discovery — never a hardcoded device node
# ---------------------------------------------------------------------------

core_devices() {
	local link name
	for link in "$DRV_DIR"/*; do
		[[ -L $link ]] || continue
		name=$(basename "$link")
		case "$name" in
		*rkvenc*) printf '%s\n' "$name" ;;
		esac
	done
}

# Prefer the driver directory the contract names; otherwise take the one on the
# bus that owns an encoder core and still publishes both attributes.
resolve_drv_dir() {
	local want dir
	if want=$(contract_driver_name) && [[ $DRIVER == island && -d $DRV_BUS/$want ]]; then
		DRV_DIR="$DRV_BUS/$want"
		return 0
	fi
	for dir in "$DRV_BUS"/*; do
		[[ -d $dir ]] || continue
		[[ -e $dir/bind && -e $dir/unbind ]] || continue
		DRV_DIR="$dir"
		if [[ -n $(core_devices) ]]; then
			return 0
		fi
	done
	DRV_DIR=
	return 1
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

resolve_driver() {
	[[ $DRIVER == auto ]] || return 0
	"$CONFIG_FN" "${SEAM_SYMBOL[island]}" || return 1
	DRIVER=island
}

gate_config() {
	"$CONFIG_FN" CONFIG_KASAN || return "$GATED"
	"$CONFIG_FN" CONFIG_PROVE_LOCKING || return "$GATED"
	"$CONFIG_FN" "${SEAM_SYMBOL[$DRIVER]}" || return "$GATED"
	[[ ! -r /proc/lockdep_stats ]] || grep -q '^ debug_locks: *1$' /proc/lockdep_stats || return "$FAIL"
}

# Seam-inventory preflight. Every knob this drill arms, and its counter, must
# exist under the seam directory. On the island a missing node is a FAILURE: the
# configuration symbol says the seam is compiled in, so a node the driver did not
# create is a broken seam, not an absent one — and the historical way this went
# wrong was a harness and its self-test agreeing on a name the driver never had.
seam_inventory() {
	local row knob missing=()
	idle_inventory || return $?
	for row in "${ROWS[@]}"; do
		[[ $ROW == all || $ROW == "$row" ]] || continue
		knob=${KNOB[$row]}
		if [[ ! -e $FAULT_DEBUG/$knob || ! -e $FAULT_DEBUG/${knob}_consumed ]]; then
			missing+=("$row")
		fi
	done
	((${#missing[@]} == 0)) && return 0
	printf 'preflight verdict=FAIL reason=seam-inventory missing=%s\n' "$(IFS=,; printf '%s' "${missing[*]}")"
	return "$FAIL"
}

is_probe_time_row() {
	local r
	for r in "${PROBE_TIME_ROWS[@]}"; do
		[[ $r == "$1" ]] && return 0
	done
	return 1
}

# ---------------------------------------------------------------------------
# The exactly-once assertion, run FIRST by every row
# ---------------------------------------------------------------------------

assert_fired_once() {
	local row=$1 before=$2 after=$3 knob delta residual
	knob=${KNOB[$row]}
	delta=$(counter_delta "$before" "$after" "${knob}_consumed") || {
		printf 'row=%s verdict=FAIL reason=counter-unreadable counter=%s_consumed\n' "$row" "$knob"
		return "$FAIL"
	}
	if [[ $delta != 1 ]]; then
		printf 'row=%s verdict=FAIL reason=counter-delta counter=%s_consumed want=1 got=%s\n' \
			"$row" "$knob" "$delta"
		return "$FAIL"
	fi
	residual=$(knob_value "$knob") || {
		printf 'row=%s verdict=FAIL reason=knob-unreadable knob=%s\n' "$row" "$knob"
		return "$FAIL"
	}
	if [[ $residual != 0 ]]; then
		printf 'row=%s verdict=FAIL reason=knob-not-reset knob=%s got=%s\n' "$row" "$knob" "$residual"
		return "$FAIL"
	fi
}

assert_journal_clean() {
	local row=$1 file=$2 bad
	bad=$(journal_bad_count "$file") || {
		printf 'row=%s verdict=FAIL reason=journal-unreadable journal=%s\n' "$row" "$file"
		return "$FAIL"
	}
	((bad == 0)) && return 0
	printf 'row=%s verdict=FAIL reason=journal-report count=%s\n' "$row" "$bad"
	return "$FAIL"
}

capture_journal() {
	local row=$1 since=$2 file=$3
	if ! "$JOURNAL_FN" "$since" "$file"; then
		printf 'row=%s verdict=FAIL reason=journal-capture journal=%s\n' "$row" "$file"
		return "$FAIL"
	fi
	assert_journal_clean "$row" "$file"
}

assert_recovery_encode() {
	local row=$1 log=$2
	"$ENCODE_FN" "$log" && return 0
	printf 'row=%s verdict=FAIL reason=recovery-encode\n' "$row"
	return "$FAIL"
}

# ---------------------------------------------------------------------------
# Rows
# ---------------------------------------------------------------------------

# session-alloc arms NOTHING itself. rkvenc-invalid-ioctl's
# --case session-allocation-failure arms fail_session_alloc_once, attaches, and
# proves the FOLLOWING attach succeeds because the knob is one-shot
# (KP tests/rkvenc-invalid-ioctl.c). Arming it here as well would consume the
# one shot before the harness ever reached it.
idle_inventory() {
	local file present=0
	for file in "${IDLE_FILES[@]}"; do
		[[ ! -e $FAULT_DEBUG/$file ]] || ((present += 1))
	done
	if ((present != 0 && present != ${#IDLE_FILES[@]})); then
		printf 'preflight verdict=FAIL reason=idle-seam-inventory present=%s\n' "$present"
		return "$FAIL"
	fi
	if [[ $ROW == idle-iommu-fault && $present == 0 ]]; then
		printf 'row=idle-iommu-fault verdict=GATED reason=no-idle-control\n'
		return "$GATED"
	fi
}

idle_snapshot() {
	local dest=$1
	snapshot "$dest" || return "$GATED"
	metric_present "$dest" busy && metric_present "$dest" queue_depth || return "$GATED"
	printf 'fault %s %s\n' "${IDLE_FILES[2]}" "$(<"$FAULT_DEBUG/${IDLE_FILES[2]}")" >>"$dest"
	printf 'state %s\n' "$(<"$FAULT_DEBUG/${IDLE_FILES[3]}")" >>"$dest"
	[[ -r /sys/kernel/debug/dma_buf/bufinfo ]] || return "$GATED"
	awk '/^Total [0-9]+ objects/{print "global dmabufs",$2}' /sys/kernel/debug/dma_buf/bufinfo >>"$dest"
	metric_present "$dest" dmabufs || return "$GATED"
	if [[ $DRIVER == island ]]; then
		[[ -r /proc/mpp_service/sessions-summary ]] || return "$GATED"
		printf 'global iommu_maps %s\n' "$(grep -c '^ *[0-9][0-9]*: 0x' /proc/mpp_service/sessions-summary || true)" >>"$dest"
	fi
}

idle_wait() { sleep 6; }
idle_no_encode() { ! pgrep -x gst-launch-1.0 >/dev/null; }

row_idle_iommu_fault() (
	local before="$OUT/idle-iommu-fault.before" after="$OUT/idle-iommu-fault.after"
	local recovered="$OUT/idle-iommu-fault.recovered" journal="$OUT/idle-iommu-fault.journal"
	local since consumed fired state metric value gaps=
	"$IDLE_SNAPSHOT_FN" "$before" || { printf 'row=idle-iommu-fault verdict=GATED reason=idle-metrics\n'; return "$GATED"; }
	if ! "$IDLE_QUIET_FN" || [[ $(metric_sum "$before" busy) != 0 || $(metric_sum "$before" queue_depth) != 0 ]]; then
		printf 'row=idle-iommu-fault verdict=GATED reason=not-idle\n'
		return "$GATED"
	fi
	since=$(date +%s)
	trap 'arm "${IDLE_FILES[0]}" 0' EXIT
	arm "${IDLE_FILES[0]}" 3000 || return "$FAIL"
	if ! "$ENCODE_FN" "$OUT/idle-iommu-fault.stimulus"; then
		printf 'row=idle-iommu-fault verdict=FAIL reason=stimulus\n'
		return "$FAIL"
	fi
	"$IDLE_WAIT_FN" || return "$FAIL"
	capture_journal idle-iommu-fault "$since" "$journal" || return "$FAIL"
	"$IDLE_SNAPSHOT_FN" "$after" || return "$FAIL"
	consumed=$(counter_delta "$before" "$after" "${IDLE_FILES[1]}") || return "$FAIL"
	fired=$(counter_delta "$before" "$after" "${IDLE_FILES[2]}") || return "$FAIL"
	state=$(awk '$1=="state"{print $2}' "$after")
	if [[ $consumed != 1 || $fired != 1 ]]; then
		printf 'row=idle-iommu-fault verdict=FAIL reason=counter-delta consumed=%s fired=%s\n' "$consumed" "$fired"
		return "$FAIL"
	fi
	case "$state" in
	suspended|not-suspended) ;;
	*) printf 'row=idle-iommu-fault verdict=FAIL reason=not-fired state=%s\n' "$state"; return "$FAIL" ;;
	esac
	if [[ $(knob_value "${IDLE_FILES[0]}") != 0 ]]; then
		printf 'row=idle-iommu-fault verdict=FAIL reason=knob-not-reset\n'
		return "$FAIL"
	fi
	if ! grep -q "idle-iommu-fault state=$state errno=0 returned" "$journal"; then
		printf 'row=idle-iommu-fault verdict=FAIL reason=errno\n'
		return "$FAIL"
	fi
	assert_recovery_encode idle-iommu-fault "$OUT/idle-iommu-fault.clean" || return "$FAIL"
	"$IDLE_WAIT_FN" || return "$FAIL"
	"$IDLE_SNAPSHOT_FN" "$recovered" || return "$FAIL"
	for metric in busy queue_depth dmabufs iommu_maps; do
		value=$(metric_sum "$before" "$metric")
		if [[ $(metric_sum "$after" "$metric") != "$value" || $(metric_sum "$recovered" "$metric") != "$value" ]]; then
			printf 'row=idle-iommu-fault verdict=FAIL reason=baseline metric=%s\n' "$metric"
			return "$FAIL"
		fi
	done
	for metric in "${IDLE_FILES[1]}" "${IDLE_FILES[2]}"; do
		if [[ $(counter_delta "$before" "$recovered" "$metric") != 1 ]]; then
			printf 'row=idle-iommu-fault verdict=FAIL reason=refired counter=%s\n' "$metric"
			return "$FAIL"
		fi
	done
	capture_journal idle-iommu-fault "$since" "$journal" || return "$FAIL"
	printf 'row=idle-iommu-fault verdict=SURVIVE state=%s driver=%s consumed_delta=1 fired_delta=1 errno=0 busy=0 queue_depth=0 recovery=ok journal_bad=0%s\n' "$state" "$DRIVER" "$gaps"
)

row_session_alloc() {
	local before="$OUT/session-alloc.before" after="$OUT/session-alloc.after"
	local log="$OUT/session-alloc.ioctl" journal="$OUT/session-alloc.journal"
	local since

	snapshot "$before"
	since=$(date +%s)

	if ! "$IOCTL_FN" "$log"; then
		printf 'row=session-alloc verdict=FAIL reason=stimulus log=%s\n' "$log"
		return "$FAIL"
	fi
	if ! grep -q 'ok  *session-allocation-failure -> ENOMEM' "$log"; then
		printf 'row=session-alloc verdict=FAIL reason=errno-line log=%s\n' "$log"
		return "$FAIL"
	fi

	snapshot "$after"
	assert_fired_once session-alloc "$before" "$after" || return "$FAIL"
	assert_recovery_encode session-alloc "$OUT/session-alloc.clean" || return "$FAIL"
	capture_journal session-alloc "$since" "$journal" || return "$FAIL"

	printf 'row=session-alloc verdict=PASS driver=%s errno=%s counter=%s_consumed delta=1 recovery=ok journal_bad=0%s\n' \
		"$DRIVER" "${ERRNO[session-alloc]}" "${KNOB[session-alloc]}" "$(gap_suffix "$after")"
}

# clock-enable is the one row whose armed stimulus must FAIL. rkvenc_clk_on
# returns -EIO before any clock is touched, so the encode cannot start; the
# journal must carry that errno at power-on, the next identical encode must
# succeed, and the hardware must not have been reset to get there.
row_clock_enable() {
	local before="$OUT/clock-enable.before" after="$OUT/clock-enable.after"
	local armed="$OUT/clock-enable.armed" journal="$OUT/clock-enable.journal"
	local since reset_delta busy

	snapshot "$before"
	since=$(date +%s)
	arm "${KNOB[clock-enable]}" 1

	if "$ENCODE_FN" "$armed"; then
		printf 'row=clock-enable verdict=FAIL reason=armed-encode-succeeded log=%s\n' "$armed"
		return "$FAIL"
	fi

	capture_journal clock-enable "$since" "$journal" || return "$FAIL"
	if ! grep -Eq '[-]EIO|Input/output error|clk_on failed: -5([[:space:]]|$)' "$journal"; then
		printf 'row=clock-enable verdict=FAIL reason=no-injected-errno journal=%s\n' "$journal"
		return "$FAIL"
	fi

	snapshot "$after"
	assert_fired_once clock-enable "$before" "$after" || return "$FAIL"
	assert_recovery_encode clock-enable "$OUT/clock-enable.clean" || return "$FAIL"

	snapshot "$after"
	if metric_present "$after" resets && metric_present "$before" resets; then
		reset_delta=$(( $(metric_sum "$after" resets) - $(metric_sum "$before" resets) ))
		if ((reset_delta != 0)); then
			printf 'row=clock-enable verdict=FAIL reason=reset-delta want=0 got=%s\n' "$reset_delta"
			return "$FAIL"
		fi
	else
		reset_delta=gap
	fi
	if metric_present "$after" busy; then
		busy=$(metric_sum "$after" busy)
		if [[ $busy != 0 ]]; then
			printf 'row=clock-enable verdict=FAIL reason=busy want=0 got=%s\n' "$busy"
			return "$FAIL"
		fi
	else
		busy=gap
	fi
	# Recovery can itself emit a report; the errno capture predates that encode.
	capture_journal clock-enable "$since" "$journal" || return "$FAIL"

	printf 'row=clock-enable verdict=PASS driver=%s errno=%s counter=%s_consumed delta=1 reset_delta=%s busy=%s recovery=ok journal_bad=0%s\n' \
		"$DRIVER" "${ERRNO[clock-enable]}" "${KNOB[clock-enable]}" "$reset_delta" "$busy" "$(gap_suffix "$after")"
}

# The three probe-time rows. Detach one encoder core, arm, reattach — the attach
# must fail with the documented errno — then reattach cleanly and prove the
# encoder still works. REBIND_DEV retains outstanding restoration for the EXIT
# trap; a failed bind must not let the drill detach another core.
row_probe_time() {
	local row=$1
	local before="$OUT/$row.before" after="$OUT/$row.after"
	local journal="$OUT/$row.journal" dev msg got want since

	if ! contract_bind_attr_yes; then
		printf 'row=%s verdict=GATED reason=no-bind-attr\n' "$row"
		return "$GATED"
	fi
	if ! resolve_drv_dir; then
		printf 'row=%s verdict=GATED reason=no-driver-directory\n' "$row"
		return "$GATED"
	fi
	dev=$(core_devices | head -1)
	if [[ -z $dev ]]; then
		printf 'row=%s verdict=GATED reason=no-core-device\n' "$row"
		return "$GATED"
	fi

	want=${ERRNO[$row]}
	snapshot "$before"
	since=$(date +%s)

	REBIND_DEV=$dev
	if ! "$UNBIND_FN" "$dev" >"$OUT/$row.unbind" 2>&1; then
		printf 'row=%s verdict=FAIL reason=unbind dev=%s\n' "$row" "$dev"
		rebind_guard
		return "$FAIL"
	fi

	arm "${KNOB[$row]}" 1

	msg=$("$BIND_FN" "$dev")
	if [[ -z $msg ]]; then
		printf 'row=%s verdict=FAIL reason=armed-attach-succeeded dev=%s want=%s\n' "$row" "$dev" "$want"
		rebind_guard
		return "$FAIL"
	fi
	printf '%s\n' "$msg" >"$OUT/$row.bind-armed"
	got=$(errno_from_message "$msg") || got=unmapped
	if [[ $got != "$want" ]]; then
		printf 'row=%s verdict=FAIL reason=errno want=%s got=%s dev=%s\n' "$row" "$want" "$got" "$dev"
		rebind_guard
		return "$FAIL"
	fi

	snapshot "$after"
	if ! assert_fired_once "$row" "$before" "$after"; then
		rebind_guard
		return "$FAIL"
	fi

	if ! "$BIND_FN" "$dev" >"$OUT/$row.bind-clean" 2>&1; then
		printf 'row=%s verdict=FAIL reason=clean-attach dev=%s\n' "$row" "$dev"
		rebind_guard
		return "$FAIL"
	fi
	REBIND_DEV=

	if ! "$CAPABILITY_FN" "$OUT/$row.capability"; then
		printf 'row=%s verdict=FAIL reason=capability-reprobe dev=%s\n' "$row" "$dev"
		return "$FAIL"
	fi
	assert_recovery_encode "$row" "$OUT/$row.clean" || return "$FAIL"
	capture_journal "$row" "$since" "$journal" || return "$FAIL"

	snapshot "$after"
	printf 'row=%s verdict=PASS driver=%s errno=%s counter=%s_consumed delta=1 dev=%s recovery=ok journal_bad=0%s\n' \
		"$row" "$DRIVER" "$want" "${KNOB[$row]}" "$dev" "$(gap_suffix "$after")"
}

gap_suffix() {
	local names
	names=$(gap_names "$1")
	[[ -n $names ]] || return 0
	printf ' gaps=%s' "$names"
}

rebind_guard() {
	local dev=$REBIND_DEV
	[[ -n $dev ]] || return 0
	if ! "$BIND_FN" "$dev" >/dev/null 2>&1; then
		printf 'cleanup verdict=FAIL reason=rebind dev=%s\n' "$dev" >&2
		return "$FAIL"
	fi
	REBIND_DEV=
	return 0
}

run_row() {
	local row=$1
	if is_probe_time_row "$row"; then
		row_probe_time "$row"
		return
	fi
	case "$row" in
	session-alloc) row_session_alloc ;;
	clock-enable)  row_clock_enable ;;
	*) usage; return "$USAGE" ;;
	esac
}

# ---------------------------------------------------------------------------
# The drill, minus the board/root gate, so --self-test can drive it whole
# ---------------------------------------------------------------------------

drill() {
	local row rc=0 passes=0 failures=0 gated=0
	gate_config || return $?
	seam_inventory || return $?
	if [[ $ROW == idle-iommu-fault ]]; then
		row_idle_iommu_fault
		return
	fi
	trap rebind_guard EXIT
	for row in "${ROWS[@]}"; do
		[[ $ROW == all || $ROW == "$row" ]] || continue
		run_row "$row"
		case $? in
		0) ((passes++)) ;;
		"$GATED") ((gated++)) ;;
		*) ((failures++)) ;;
		esac
		if [[ -n $REBIND_DEV ]]; then
			printf 'fault-controls verdict=FAIL reason=unrestored-core dev=%s\n' "$REBIND_DEV"
			return "$FAIL"
		fi
	done
	printf 'fault-controls driver=%s passes=%s failures=%s gated=%s out=%s\n' \
		"$DRIVER" "$passes" "$failures" "$gated" "$OUT"
	((failures == 0)) || rc="$FAIL"
	((rc != 0)) || ((gated == 0)) || rc="$GATED"
	return "$rc"
}

# ---------------------------------------------------------------------------
# The synthetic one-shot seam — a shell "driver", not a fake device
#
# Modelled on KP tests/lib/qa-fixture.sh. It simulates the driver's ONE-SHOT
# BOOKKEEPING and nothing else:
#
#   armed knob   + stimulus -> counter += 1, knob := 0   (the fault fired once)
#   unarmed knob + stimulus -> nothing                   (there was nothing to fire)
#
# It deliberately does not simulate an encode, an attach or a clock. A fixture
# that pretended to be a driver would start being trusted as one.
#
# FX_MODE is how the self-test turns the drill RED on a BROKEN seam while the
# stimulus itself stays green — which is the only interesting direction. A seam
# that returns the right errno and forgets to book it (`never`), books it twice
# (`twice`), or leaves its one-shot armed (`sticky`) is exactly what
# assert_fired_once exists to catch, and a fixture that could only fail by
# refusing to inject would never exercise that assertion. `inert` is the
# refusing-to-inject case, which proves the other half: an armed stimulus that
# succeeds anyway.
# ---------------------------------------------------------------------------

FX_MODE=once
FX_ENCODE_RECOVERY=ok
FX_CLOCK_JOURNAL=noisy
FX_CLOCK_MESSAGE=
FX_BUMP_RESETS=0
FX_BIND_ERRNO=
FX_CAPABILITY=ok
FX_JOURNAL=
FX_BOUND=

fx_bump() {
	printf '%s\n' "$(( $(<"$FAULT_DEBUG/$1") + 1 ))" >"$FAULT_DEBUG/$1"
}

fx_consume() {
	local knob=$1 armed
	[[ $FX_MODE == inert ]] && return 1
	[[ -r $FAULT_DEBUG/$knob ]] || return 1
	armed=$(<"$FAULT_DEBUG/$knob")
	((armed == 0)) && return 1
	[[ $FX_MODE == sticky ]] || printf '0\n' >"$FAULT_DEBUG/$knob"
	case "$FX_MODE" in
	never) : ;;
	twice) fx_bump "${knob}_consumed"; fx_bump "${knob}_consumed" ;;
	*)     fx_bump "${knob}_consumed" ;;
	esac
	return 0
}

fx_journal_append() {
	printf '%s\n' "$1" >>"$FX_JOURNAL"
}

fx_make_seam() {
	local dir=$1 row knob
	mkdir -p "$dir"
	for row in "${ROWS[@]}"; do
		knob=${KNOB[$row]}
		printf '0\n' >"$dir/$knob"
		printf '0\n' >"$dir/${knob}_consumed"
	done
}

fx_make_mpp() {
	local dir=$1 metric
	mkdir -p "$dir/cores/rkvenc-core0" "$dir/cores/rkvenc-core1"
	for metric in busy busy_ns tasks errors resets; do
		printf '0\n' >"$dir/cores/rkvenc-core0/$metric"
		printf '0\n' >"$dir/cores/rkvenc-core1/$metric"
	done
	printf '0\n' >"$dir/queue_depth"
}

# Synthetic device names on purpose. The two RK3588 spellings are device-tree
# facts, and a fixture that used them would let a hardcoded path pass here and
# select nothing on a board.
fx_make_bus() {
	local dir=$1 dev
	mkdir -p "$dir/mpp_rkvenc2" "$dir/.devices/deadbee0.rkvenc-core" \
		"$dir/.devices/deadbee1.rkvenc-core" "$dir/.devices/module"
	: >"$dir/mpp_rkvenc2/bind"
	: >"$dir/mpp_rkvenc2/unbind"
	for dev in deadbee0.rkvenc-core deadbee1.rkvenc-core module; do
		ln -sf "../.devices/$dev" "$dir/mpp_rkvenc2/$dev"
	done
}

fx_config_has() {
	case "$1" in
	CONFIG_KASAN|CONFIG_PROVE_LOCKING) return 0 ;;
	"${SEAM_SYMBOL[island]}") return 0 ;;
	esac
	return 1
}

fx_capability() {
	if [[ $FX_CAPABILITY != ok || ! -s $FX_BOUND ]]; then
		printf 'client inventory did not come back\n' >"$1"
		return 1
	fi
	printf 'MPP_CMD_PROBE_HW_SUPPORT 0x00010000\n' >"$1"
	return 0
}

fx_journal() {
	cat "$FX_JOURNAL" >"$2" 2>/dev/null || : >"$2"
}

fx_ioctl() {
	local log=$1
	printf '1\n' >"$FAULT_DEBUG/${KNOB[session-alloc]}"
	if fx_consume "${KNOB[session-alloc]}"; then
		{
			printf '  ok   session-allocation-failure -> ENOMEM\n'
			printf '  ok   the following open/attach succeeds (the knob is one-shot)\n'
		} >"$log"
		return 0
	fi
	printf '  FAIL session-allocation-failure: expected ENOMEM, got OK (0)\n' >"$log"
	return 1
}

fx_encode() {
	local log=$1 core
	if fx_consume "${KNOB[clock-enable]}"; then
		printf 'ERROR: from element pipeline: Internal data stream error.\n' >"$log"
		[[ $FX_CLOCK_JOURNAL == silent ]] || \
			fx_journal_append "${FX_CLOCK_MESSAGE:-mpp_rkvenc2 deadbee0.rkvenc-core: clk_on failed: -5}"
		if [[ $FX_BUMP_RESETS == 1 ]]; then
			for core in "$MPP_DEBUG"/cores/*; do
				printf '%s\n' "$(( $(<"$core/resets") + 1 ))" >"$core/resets"
			done
		fi
		return 1
	fi
	if [[ $FX_ENCODE_RECOVERY == fail ]]; then
		printf 'ERROR: pipeline could not be constructed\n' >"$log"
		return 1
	fi
	if [[ $FX_ENCODE_RECOVERY == journal ]]; then
		fx_journal_append 'BUG: KASAN: synthetic recovery-only report'
	fi
	printf 'Setting pipeline to PLAYING ...\nGot EOS from element "pipeline".\n' >"$log"
	return 0
}

fx_unbind() {
	: >"$FX_BOUND"
	return 0
}

# A real probe() consults all three probe-time controls, so the fixture scans
# them instead of being told the row — which is what lets --row all be exercised.
fx_bind() {
	local dev=$1 row want
	for row in "${PROBE_TIME_ROWS[@]}"; do
		if fx_consume "${KNOB[$row]}"; then
			want=${FX_BIND_ERRNO:-${ERRNO[$row]}}
			printf 'bash: line 1: bind: %s\n' "${STRERROR_TEXT[$want]}"
			fx_journal_append "rk-vcodec $dev: probe failed with -$want"
			return 1
		fi
	done
	printf '%s\n' "$dev" >"$FX_BOUND"
	return 0
}

# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

ST_WORK=
ST_LEGS=

st_install_hooks() {
	ENCODE_FN=fx_encode
	IOCTL_FN=fx_ioctl
	JOURNAL_FN=fx_journal
	BIND_FN=fx_bind
	UNBIND_FN=fx_unbind
	CONFIG_FN=fx_config_has
	CAPABILITY_FN=fx_capability
}

st_reset() {
	local row=$1
	rm -rf "${ST_WORK:?}/seam" "${ST_WORK:?}/mpp" "${ST_WORK:?}/bus" "${ST_WORK:?}/out"
	mkdir -p "$ST_WORK/out"
	FAULT_DEBUG="$ST_WORK/seam"
	MPP_DEBUG="$ST_WORK/mpp"
	DRV_BUS="$ST_WORK/bus"
	DRV_DIR=
	OUT="$ST_WORK/out"
	FX_JOURNAL="$ST_WORK/journal.log"
	FX_BOUND="$ST_WORK/bound"
	: >"$FX_JOURNAL"
	printf 'deadbee0.rkvenc-core\n' >"$FX_BOUND"
	fx_make_seam "$FAULT_DEBUG"
	fx_make_mpp "$MPP_DEBUG"
	fx_make_bus "$DRV_BUS"
	FX_MODE=once
	FX_ENCODE_RECOVERY=ok
	FX_CLOCK_JOURNAL=noisy
	FX_CLOCK_MESSAGE=
	FX_BUMP_RESETS=0
	FX_BIND_ERRNO=
	FX_CAPABILITY=ok
	REBIND_DEV=
	DRIVER=island
	ROW=$row
}

# st_leg <name> <want-rc> <token-regex|-> — runs the drill and records one line.
st_leg() {
	local name=$1 want=$2 token=$3 got=0 out verdict token_state=n/a
	out=$(drill 2>&1) || got=$?
	printf '=== leg %s ===\n%s\n' "$name" "$out"
	if [[ $token != - ]]; then
		if grep -Eq "$token" <<<"$out"; then token_state=found; else token_state=missing; fi
	fi
	if [[ $got == "$want" ]] && [[ $token == - || $token_state == found ]]; then
		verdict=PASS
	else
		verdict=FAIL
	fi
	ST_LEGS+="leg=$name want=$want got=$got token=$token_state verdict=$verdict"$'\n'
}

st_clock_errnos() (
	local entry want got
	for entry in \
		'0|mpp_rkvenc2 deadbee0.rkvenc-core: clk_on failed: -5' \
		'0|mpp_rkvenc2 deadbee0.rkvenc-core: clk_on failed: -5 (EIO)' \
		'0|rk-vcodec deadbee0.rkvenc-core: clk_on failed -EIO' \
		'0|rk-vcodec deadbee0.rkvenc-core: clk_on failed -5 (Input/output error)' \
		'1|mpp_rkvenc2 deadbee0.rkvenc-core: clk_on failed: -50' \
		'1|mpp_rkvenc2 deadbee0.rkvenc-core: clk_on failed: -5suffix' \
		'1|unrelated operation failed: -5'; do
		st_reset clock-enable
		want=${entry%%|*}
		FX_CLOCK_MESSAGE=${entry#*|}
		row_clock_enable >"$ST_WORK/clock-errno.log"; got=$?
		printf 'self-test=clock-errno want=%s got=%s message=%s\n' "$want" "$got" "$FX_CLOCK_MESSAGE"
		[[ $got == "$want" ]] || return "$FAIL"
		if [[ $want == 1 ]]; then
			grep -q 'reason=no-injected-errno' "$ST_WORK/clock-errno.log" || return "$FAIL"
		fi
	done
)

st_rebind_cleanup() (
	local got dev=deadbee0.rkvenc-core
	st_reset service-attach
	BIND_FN=false
	rebind_guard || return "$FAIL"
	REBIND_DEV=$dev
	rebind_guard; got=$?
	printf 'self-test=rebind-failure exit=%s retained=%s\n' "$got" "${REBIND_DEV:-EMPTY}"
	[[ $got == "$FAIL" && $REBIND_DEV == "$dev" ]] || return "$FAIL"
	BIND_FN=fx_bind
	rebind_guard || return "$FAIL"
	[[ -z $REBIND_DEV && $(<"$FX_BOUND") == "$dev" ]] || return "$FAIL"
	BIND_FN=false
	rebind_guard || return "$FAIL"

	st_reset all
	drill >"$ST_WORK/rebind-drill.log" 2>&1; got=$?
	trap - EXIT
	[[ $got == "$FAIL" && $REBIND_DEV == "$dev" ]] || return "$FAIL"
	grep -q 'reason=unrestored-core' "$ST_WORK/rebind-drill.log" || return "$FAIL"
	[[ ! -e $OUT/ccu-attach.before && ! -e $OUT/irq-request.before ]] || return "$FAIL"
	printf 'self-test=rebind-cleanup PASS failed-state-retained retry-clears no-pending-noop drill-stops\n'
)

st_fixture_one_shot() {
	local knob=${KNOB[session-alloc]} verdict=PASS
	st_reset session-alloc
	printf '1\n' >"$FAULT_DEBUG/$knob"
	fx_consume "$knob" || verdict=FAIL
	[[ $(<"$FAULT_DEBUG/${knob}_consumed") == 1 ]] || verdict=FAIL
	[[ $(<"$FAULT_DEBUG/$knob") == 0 ]] || verdict=FAIL
	# The second stimulus must NOT re-fire, or every "exactly once" assertion
	# built on this fixture is measuring nothing.
	if fx_consume "$knob"; then verdict=FAIL; fi
	[[ $(<"$FAULT_DEBUG/${knob}_consumed") == 1 ]] || verdict=FAIL
	printf '=== leg fixture-one-shot ===\nconsumed=%s knob=%s\n' \
		"$(<"$FAULT_DEBUG/${knob}_consumed")" "$(<"$FAULT_DEBUG/$knob")"
	ST_LEGS+="leg=fixture-one-shot want=0 got=0 token=n/a verdict=$verdict"$'\n'
}

FX_IDLE_MODE=once
FX_IDLE_STATE=suspended
FX_IDLE_PENDING=0

fx_idle_encode() {
	if [[ $1 == *.clean && $FX_IDLE_MODE == recovery ]]; then return 1; fi
	if [[ $(knob_value "${IDLE_FILES[0]}") != 0 ]]; then
		[[ $FX_IDLE_MODE == sticky ]] || arm "${IDLE_FILES[0]}" 0
		[[ $FX_IDLE_MODE == never ]] || fx_bump "${IDLE_FILES[1]}"
		[[ $FX_IDLE_MODE != twice ]] || fx_bump "${IDLE_FILES[1]}"
		FX_IDLE_PENDING=1
	fi
	printf 'synthetic completed encode\n' >"$1"
}

fx_idle_wait() {
	if ((FX_IDLE_PENDING)); then
		FX_IDLE_PENDING=0
		[[ $FX_IDLE_MODE != no-fire ]] || return 0
		fx_bump "${IDLE_FILES[2]}"
		printf '%s\n' "$FX_IDLE_STATE" >"$FAULT_DEBUG/${IDLE_FILES[3]}"
		if [[ $FX_IDLE_MODE == journal ]]; then
			fx_journal_append 'BUG: synthetic idle diagnostic'
		else
			fx_journal_append "idle-iommu-fault state=$FX_IDLE_STATE errno=$([[ $FX_IDLE_MODE == errno ]] && printf '%s' -19 || printf 0) returned"
		fi
		[[ $FX_IDLE_MODE != baseline ]] || printf '1\n' >"$MPP_DEBUG/queue_depth"
	elif [[ $FX_IDLE_MODE == refire ]]; then
		fx_bump "${IDLE_FILES[2]}"
	fi
}

fx_idle_snapshot() {
	snapshot "$1"
	{
		printf 'fault %s %s\n' "${IDLE_FILES[2]}" "$(<"$FAULT_DEBUG/${IDLE_FILES[2]}")"
		printf 'state %s\n' "$(<"$FAULT_DEBUG/${IDLE_FILES[3]}")"
		printf 'global dmabufs 0\nglobal iommu_maps 0\n'
	} >>"$1"
}

idle_self_test() {
	local driver mode file want token
	ST_WORK=$(mktemp -d) || return "$FAIL"
	ST_LEGS=
	IDLE_SNAPSHOT_FN=fx_idle_snapshot
	IDLE_WAIT_FN=fx_idle_wait
	ENCODE_FN=fx_idle_encode
	driver=island
		for mode in suspended not-suspended none never twice no-fire sticky recovery errno journal baseline refire no-control partial busy; do
			st_reset idle-iommu-fault
			DRIVER=$driver
			FX_IDLE_MODE=$mode
			FX_IDLE_STATE=suspended
			FX_IDLE_PENDING=0
			IDLE_QUIET_FN=true
			for file in "${IDLE_FILES[@]}"; do printf '0\n' >"$FAULT_DEBUG/$file"; done
			printf 'none\n' >"$FAULT_DEBUG/${IDLE_FILES[3]}"
			want=1
			case "$mode" in
			suspended|not-suspended) FX_IDLE_MODE=once; FX_IDLE_STATE=$mode; want=0; token="verdict=SURVIVE state=$mode" ;;
			none) FX_IDLE_STATE=none; token='reason=not-fired' ;;
			never|twice|no-fire) token='reason=counter-delta' ;;
			sticky) token='reason=knob-not-reset' ;;
			recovery) token='reason=recovery-encode' ;;
			errno) token='reason=errno' ;;
			journal) token='reason=journal-report' ;;
			baseline) token='reason=baseline' ;;
			refire) token='reason=refired' ;;
			no-control) for file in "${IDLE_FILES[@]}"; do rm "$FAULT_DEBUG/$file"; done; want=77; token='reason=no-idle-control' ;;
			partial) rm "$FAULT_DEBUG/${IDLE_FILES[2]}"; token='reason=idle-seam-inventory' ;;
			busy) IDLE_QUIET_FN=false; want=77; token='reason=not-idle' ;;
			esac
			st_leg "idle-$driver-$mode" "$want" "$token"
		done
	rm -rf "$ST_WORK"
	printf '%s' "$ST_LEGS"
	if [[ $ST_LEGS == *'verdict=FAIL'* ]]; then return "$FAIL"; fi
	printf 'VERDICT: PASS (idle-only row: both PM readings, island driver, negative assertions and admission gates; synthetic only)\n'
}

st_option_values() {
	local option got
	for option in --driver --out --row --probe-mpp --invalid-ioctl; do
		CERALIVE_BOARD_TEST=0 timeout 2 bash "$HERE/fault-controls-probe.sh" "$option" >/dev/null 2>&1; got=$?
		printf 'self-test=missing-option-value option=%s want=2 got=%s\n' "$option" "$got"
		[[ $got == "$USAGE" ]] || return "$FAIL"
	done
	CERALIVE_BOARD_TEST=0 timeout 2 bash "$HERE/fault-controls-probe.sh" \
		--driver island --out 'unused path with spaces' --row all \
		--probe-mpp unused --invalid-ioctl unused >/dev/null 2>&1; got=$?
	printf 'self-test=present-option-values want=77 got=%s\n' "$got"
	[[ $got == "$GATED" ]]
}

st_journal_captures() (
	local row mode capture capture_error_at got want rc=0 file
	JOURNAL_FN=st_capture
	st_capture() {
		capture=$((capture + 1))
		fx_journal "$@" || return 1
		((capture == capture_error_at)) || return 0
		case "$mode" in
		status) return 1 ;;
		empty-status) : >"$2"; return 1 ;;
		error-status) printf 'journal read failed\n' >"$2"; return 1 ;;
		error-message) printf 'journal read failed\n' >>"$2" ;;
		missing) rm "$2" ;;
		directory) rm "$2"; mkdir "$2" ;;
		esac
	}
	st_reset session-alloc
	capture=0; capture_error_at=1; mode=error-status
	st_capture 0 "$OUT/hook.journal"; got=$?
	[[ $got == 1 && $capture == 1 && $(<"$OUT/hook.journal") == 'journal read failed' ]] || return "$FAIL"
	for row in "${ROWS[@]}" idle-iommu-fault; do
		for capture_error_at in 1 2; do
			[[ $capture_error_at == 1 || $row == clock-enable || $row == idle-iommu-fault ]] || continue
			for mode in status empty-status error-status error-message missing directory; do
				st_reset "$row"
				capture=0
				if [[ $row == idle-iommu-fault ]]; then
					IDLE_SNAPSHOT_FN=fx_idle_snapshot; IDLE_WAIT_FN=fx_idle_wait
					IDLE_QUIET_FN=true; ENCODE_FN=fx_idle_encode
					FX_IDLE_MODE=once; FX_IDLE_STATE=suspended; FX_IDLE_PENDING=0
					for file in "${IDLE_FILES[@]}"; do printf '0\n' >"$FAULT_DEBUG/$file"; done
				fi
				want='journal-unreadable'
				[[ $mode != *status ]] || want='journal-capture'
				(drill) >"$ST_WORK/capture-result" 2>&1; got=$?
				printf 'self-test=journal-capture row=%s capture=%s mode=%s want=1 got=%s\n' "$row" "$capture_error_at" "$mode" "$got"
				[[ $got == "$FAIL" ]] || rc=1
				grep -q "row=$row verdict=FAIL reason=$want" "$ST_WORK/capture-result" || rc=1
				if grep -Eq 'verdict=(PASS|SURVIVE)' "$ST_WORK/capture-result"; then rc=1; fi
			done
		done
	done
	return "$rc"
)

st_journal_reader() (
	local text got want rc=0
	for text in '' '-- No entries --' 'kernel: journal read failed during synthetic operation' \
		'journal read failed' 'Failed to open journal: Permission denied' \
		'No journal files were found.' 'Hint: You are currently not seeing messages from other users and the system.'; do
		printf '%s\n' "$text" >"$ST_WORK/reader.journal"
		case "$text" in ''|'-- No entries --'|kernel:*) want=0 ;; *) want=1 ;; esac
		assert_journal_clean synthetic "$ST_WORK/reader.journal" >"$ST_WORK/reader-result"; got=$?
		printf 'self-test=journal-reader want=%s got=%s text=%s\n' "$want" "$got" "${text:-EMPTY}"
		[[ $got == "$want" ]] || rc=1
	done
	# A read error after the file-existence check must not become grep's clean
	# no-match result (1); grep uses 2 for an actual failure.
	grep() { return 2; }
	assert_journal_clean synthetic "$ST_WORK/reader.journal" >"$ST_WORK/reader-result"; got=$?
	printf 'self-test=journal-reader grep-error want=1 got=%s\n' "$got"
	[[ $got == "$FAIL" ]] || rc=1
	return "$rc"
)

self_test() {
	local row rc=0 actual expected
	ST_WORK=$(mktemp -d) || return "$FAIL"
	st_install_hooks

	st_rebind_cleanup || rc="$FAIL"
	st_clock_errnos || rc="$FAIL"
	st_option_values || rc="$FAIL"
	st_journal_captures || rc="$FAIL"
	st_journal_reader || rc="$FAIL"
	st_fixture_one_shot

	for row in "${ROWS[@]}"; do
		st_reset "$row"
		st_leg "happy-$row" 0 "^row=$row verdict=PASS"
	done

	st_reset all
	st_leg happy-all 0 '^fault-controls driver=island passes=5 failures=0 gated=0'

	# RED 1 — the seam injects the right errno and never books it.
	st_reset session-alloc
	FX_MODE=never
	st_leg red-counter-never "$FAIL" 'reason=counter-delta .*want=1 got=0'

	# RED 2 — the seam books the same one-shot twice.
	st_reset clock-enable
	FX_MODE=twice
	st_leg red-counter-twice "$FAIL" 'reason=counter-delta .*want=1 got=2'

	# RED 3 — the fault fires correctly and the device does not come back.
	st_reset session-alloc
	FX_ENCODE_RECOVERY=fail
	st_leg red-recovery-encode "$FAIL" 'reason=recovery-encode'

	# RED 4 — a seam node was renamed, so the drill would arm a knob the driver
	# never created and read a counter that never moves.
	st_reset irq-request
	mv "$FAULT_DEBUG/${KNOB[irq-request]}_consumed" "$FAULT_DEBUG/fail_irq_request_consumed"
	st_leg red-seam-renamed "$FAIL" 'reason=seam-inventory missing=irq-request'

	# Every remaining assertion owns a RED leg: an assertion no leg can turn red
	# has never been shown to work, and unexercised code is not evidence.
	st_reset session-alloc
	FX_MODE=sticky
	st_leg red-knob-not-reset "$FAIL" 'reason=knob-not-reset'

	st_reset session-alloc
	fx_journal_append 'BUG: KASAN: use-after-free in rkvenc_free_session+0x1c/0x120'
	st_leg red-journal-report "$FAIL" 'reason=journal-report'

	st_reset clock-enable
	FX_ENCODE_RECOVERY=journal
	st_leg red-recovery-journal "$FAIL" 'reason=journal-report'

	st_reset clock-enable
	FX_MODE=inert
	st_leg red-armed-encode-succeeded "$FAIL" 'reason=armed-encode-succeeded'

	st_reset clock-enable
	FX_CLOCK_JOURNAL=silent
	st_leg red-no-injected-errno "$FAIL" 'reason=no-injected-errno'

	st_reset clock-enable
	FX_BUMP_RESETS=1
	st_leg red-reset-delta "$FAIL" 'reason=reset-delta want=0 got=2'

	st_reset service-attach
	FX_MODE=inert
	st_leg red-armed-attach-succeeded "$FAIL" 'reason=armed-attach-succeeded'

	st_reset service-attach
	FX_BIND_ERRNO=EBUSY
	st_leg red-probe-errno "$FAIL" 'reason=errno want=ENOMEM got=EBUSY'

	st_reset ccu-attach
	FX_CAPABILITY=fail
	st_leg red-capability-reprobe "$FAIL" 'reason=capability-reprobe'

	# The gates themselves must be real, not decorative.
	st_reset service-attach
	CONTRACT_DOC="$ST_WORK/no-bind-attr.md"
	printf '| %sbind-attr%s verdict | **no** — the driver suppresses them |\n' "$BT" "$BT" >"$CONTRACT_DOC"
	st_leg gated-no-bind-attr 77 'verdict=GATED reason=no-bind-attr'
	CONTRACT_DOC="$HERE/../../docs/FAULT-SEAM-CONTRACT.md"

	st_reset irq-request
	rm -rf "${DRV_BUS:?}"
	mkdir -p "$DRV_BUS"
	st_leg gated-no-driver-directory 77 'verdict=GATED reason=no-driver-directory'

	st_reset session-alloc
	CONFIG_FN=false
	st_leg gated-no-seam-config 77 -
	CONFIG_FN=fx_config_has

	rm -rf "$ST_WORK"

	actual=$(printf '%s' "$ST_LEGS")
	expected=$(cat <<-'GOLDEN'
	leg=fixture-one-shot want=0 got=0 token=n/a verdict=PASS
	leg=happy-session-alloc want=0 got=0 token=found verdict=PASS
	leg=happy-clock-enable want=0 got=0 token=found verdict=PASS
	leg=happy-service-attach want=0 got=0 token=found verdict=PASS
	leg=happy-ccu-attach want=0 got=0 token=found verdict=PASS
	leg=happy-irq-request want=0 got=0 token=found verdict=PASS
	leg=happy-all want=0 got=0 token=found verdict=PASS
	leg=red-counter-never want=1 got=1 token=found verdict=PASS
	leg=red-counter-twice want=1 got=1 token=found verdict=PASS
	leg=red-recovery-encode want=1 got=1 token=found verdict=PASS
	leg=red-seam-renamed want=1 got=1 token=found verdict=PASS
	leg=red-knob-not-reset want=1 got=1 token=found verdict=PASS
	leg=red-journal-report want=1 got=1 token=found verdict=PASS
	leg=red-recovery-journal want=1 got=1 token=found verdict=PASS
	leg=red-armed-encode-succeeded want=1 got=1 token=found verdict=PASS
	leg=red-no-injected-errno want=1 got=1 token=found verdict=PASS
	leg=red-reset-delta want=1 got=1 token=found verdict=PASS
	leg=red-armed-attach-succeeded want=1 got=1 token=found verdict=PASS
	leg=red-probe-errno want=1 got=1 token=found verdict=PASS
	leg=red-capability-reprobe want=1 got=1 token=found verdict=PASS
	leg=gated-no-bind-attr want=77 got=77 token=found verdict=PASS
	leg=gated-no-driver-directory want=77 got=77 token=found verdict=PASS
	leg=gated-no-seam-config want=77 got=77 token=n/a verdict=PASS
	GOLDEN
	)

	printf '=== leg summary ===\n%s\n' "$actual"
	if [[ $actual != "$expected" ]]; then
		printf '=== expected ===\n%s\n' "$expected" >&2
		printf 'VERDICT: FAIL (leg summary drifted from the committed expectation)\n' >&2
		rc="$FAIL"
	fi
	((rc == 0)) || return "$rc"
	printf 'VERDICT: PASS (5 rows proven fire-once, 13 RED legs proven red, 3 gates proven real)\n'
	idle_self_test
}

# ---------------------------------------------------------------------------

main() {
	local self=0
	while (($#)); do case "$1" in
		--driver|--out|--row|--probe-mpp|--invalid-ioctl)
			(($# >= 2)) || { usage; return "$USAGE"; }
			case "$1" in
			--driver) DRIVER=$2;;
			--out) OUT=$2;;
			--row) ROW=$2;;
			--probe-mpp) PROBE_MPP=$2;;
			--invalid-ioctl) INVALID_IOCTL=$2;;
			esac
			shift 2;;
		--self-test) self=1; shift;;
		-h|--help) usage; return "$USAGE";;
		*) usage; return "$USAGE";; esac; done
	((self)) && { self_test; return; }
	[[ $DRIVER == island || $DRIVER == auto ]] || { usage; return "$USAGE"; }
	[[ $ROW == all || $ROW == idle-iommu-fault || " ${ROWS[*]} " == *" $ROW "* ]] || { usage; return "$USAGE"; }
	[[ ${CERALIVE_BOARD_TEST:-0} == 1 && $EUID == 0 ]] || return "$GATED"
	[[ -x $PROBE_MPP && -x $INVALID_IOCTL && -d $FAULT_DEBUG && -r $EXPECT_TABLE ]] || return "$GATED"
	resolve_driver || return "$GATED"
	OUT=${OUT:-/tmp/fault-controls-$(date -u +%Y%m%dT%H%M%SZ)}; mkdir -p "$OUT"
	{
		printf 'board='
		[[ -r /proc/device-tree/model ]] && tr -d '\0' </proc/device-tree/model
		printf '\nkernel='; uname -a
		printf 'driver=%s\n' "$DRIVER"
	} >"$OUT/identity.txt"
	drill
}

main "$@"
