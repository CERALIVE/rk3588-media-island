#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	return 1
}

require_text() {
	local file=$1
	local text=$2

	grep -Fq "$text" "$file" || fail "$(basename "$file") misses: $text"
}

require_function_order() {
	local file=$1
	local function=$2
	local before=$3
	local after=$4
	local body

	body=$(sed -n "/^[[:alnum:]_ *]*${function}(/,/^}/p" "$file")
	[[ $body == *"$before"*"$after"* ]] ||
		fail "$(basename "$file"):$function must order '$before' before '$after'"
}

check_trace_header() {
	local file=$1
	local system=$2
	shift 2

	require_text "$file" "#define TRACE_SYSTEM $system" || return 1
	require_text "$file" '#include <linux/tracepoint.h>' || return 1
	for event in "$@"; do
		grep -Eq "(TRACE_EVENT|DEFINE_EVENT)\\([^,]+,? ?${event},|(TRACE_EVENT)\\(${event}," "$file" ||
			{ fail "$(basename "$file") misses event: $event"; return 1; }
	done
	require_text "$file" '<trace/define_trace.h>' || return 1
}

check_sources() {
	local root=$1
	local mpp="$root/drivers/video/rockchip/mpp"
	local rga="$root/drivers/video/rockchip/rga3"

	check_trace_header "$mpp/mpp_trace.h" rockchip_mpp \
		mpp_task_queued mpp_core_selected mpp_task_started \
		mpp_task_done mpp_task_error mpp_reset || return 1
	check_trace_header "$rga/rga_trace.h" rockchip_rga \
		rga_req_queued rga_core_selected rga_job_started \
		rga_job_done rga_job_timeout rga_reset || return 1

	require_text "$mpp/mpp_trace.c" '#define CREATE_TRACE_POINTS' || return 1
	require_text "$rga/rga_trace.c" '#define CREATE_TRACE_POINTS' || return 1
	require_text "$mpp/Makefile" 'mpp_trace.o' || return 1
	require_text "$rga/Makefile" 'rga_trace.o' || return 1

	for call in \
		trace_mpp_task_queued \
		trace_mpp_core_selected \
		trace_mpp_task_started \
		trace_mpp_task_done \
		trace_mpp_task_error \
		trace_mpp_reset; do
		require_text "$mpp/mpp_common.c" "${call}(" || return 1
	done
	for call in \
		trace_rga_req_queued \
		trace_rga_core_selected \
		trace_rga_job_started \
		trace_rga_job_done \
		trace_rga_job_timeout \
		trace_rga_reset; do
		require_text "$rga/rga_job.c" "${call}(" || return 1
	done
	require_function_order "$mpp/mpp_common.c" mpp_task_run \
		'trace_mpp_task_started' 'enable_irq(mpp->irq)' || return 1
	require_function_order "$rga/rga_job.c" rga_job_commit \
		'trace_rga_req_queued' 'trace_rga_core_selected' || return 1

	require_text "$mpp/mpp_service.c" 'debugfs_create_dir("rockchip-mpp"' || return 1
	require_text "$mpp/mpp_service.c" 'queue_depth' || return 1
	require_text "$mpp/mpp_service.c" 'busy_ns' || return 1
	require_text "$mpp/mpp_service.c" 'sessions' || return 1
	require_text "$mpp/mpp_service.c" 'debugfs_create_file_aux_num("stats"' || return 1
	require_text "$mpp/mpp_service.c" 'mpp_telemetry_format_session' || return 1
	require_text "$mpp/mpp_telemetry.h" 'mpp_telemetry_mark_once' || return 1
	require_text "$mpp/mpp_common.c" 'mpp_telemetry_mark_once' || return 1
	require_text "$mpp/mpp_service.c" 'mpp_session_get(session)' || return 1
	require_text "$mpp/mpp_service.c" 'mpp_session_put(session)' || return 1
	require_text "$rga/rga_debugger.c" 'RGA_TELEMETRY_ROOT_NAME' || return 1
	require_text "$rga/rga_debugger.c" 'queue_depth' || return 1
	require_text "$rga/rga_debugger.c" 'busy_ns' || return 1
	require_text "$rga/rga_debugger.c" 'sessions' || return 1
	require_text "$rga/rga_debugger.c" 'debugfs_create_file_aux_num("stats"' || return 1
	require_text "$rga/rga_debugger.c" 'rga_session_get_unless_zero(session)' || return 1
	require_text "$rga/rga_debugger.c" 'rga_session_put(session)' || return 1

	require_text "$mpp/mpp_service.c" 'mpp_telemetry_format_load' || return 1
	require_text "$mpp/mpp_common.c" 'mpp_telemetry_task_error' || return 1
	require_text "$mpp/mpp_common.h" 'TASK_STATE_ERROR_REPORTED' || return 1
	require_text "$mpp/mpp_common.h" 'TASK_STATE_DONE_REPORTED' || return 1
	require_text "$mpp/mpp_common.c" 'atomic_xchg(&mpp->reset_request, 0)' || return 1
	require_text "$mpp/mpp_common.c" 'atomic64_inc(&task->session->telemetry.tasks)' || return 1
	require_text "$mpp/mpp_common.c" 'atomic64_add(task->bytes, &task->session->telemetry.bytes)' || return 1
	require_text "$rga/rga_job.c" 'atomic64_inc(&job->session->telemetry.tasks)' || return 1
	require_text "$rga/rga_job.c" 'atomic64_add(job->bytes, &job->session->telemetry.bytes)' || return 1
	require_text "$rga/rga_job.c" 'void rga_telemetry_reset' || return 1
	require_text "$rga/include/rga_job.h" 'void rga_telemetry_reset' || return 1
	if grep -R -Fq --include='*.c' 'scheduler->ops->soft_reset(scheduler);' "$rga"; then
		fail 'RGA reset call bypasses the telemetry wrapper'
		return 1
	fi
	require_text "$rga/rga_job.c" 'atomic_sub(removed, &rga_drvdata->telemetry_queue_depth)' || return 1
	require_text "$rga/include/rga_drv.h" 'RGA_JOB_STATE_TELEMETRY_ACCOUNTED' || return 1

	require_text "$root/configs/rk3588-media-island.fragment" 'CONFIG_DEBUG_FS=y' || return 1
	require_text "$root/configs/rk3588-media-island.fragment" 'CONFIG_FTRACE=y' || return 1
	require_text "$root/configs/rk3588-media-island.fragment" 'CONFIG_ENABLE_DEFAULT_TRACERS=y' || return 1
	require_text "$root/configs/rk3588-media-island.fragment" '# CONFIG_FUNCTION_TRACER is not set' || return 1
	require_text "$root/configs/rk3588-media-island.fragment" 'CONFIG_ROCKCHIP_RGA_DEBUG_FS=y' || return 1

	printf 'PASS: tracepoint and telemetry source contract\n'
}

self_test() {
	local tmp
	local fixture

	tmp="$(mktemp -d)"
	trap 'rm -rf "$tmp"' RETURN
	fixture="$tmp/source"
	mkdir -p "$fixture/drivers/video/rockchip/mpp" \
		"$fixture/drivers/video/rockchip/rga3" "$fixture/configs"

	cat >"$fixture/drivers/video/rockchip/mpp/mpp_trace.h" <<'EOF'
#define TRACE_SYSTEM rockchip_mpp
#include <linux/tracepoint.h>
TRACE_EVENT(mpp_task_queued,
TRACE_EVENT(mpp_core_selected,
TRACE_EVENT(mpp_task_started,
TRACE_EVENT(mpp_task_done,
TRACE_EVENT(mpp_task_error,
TRACE_EVENT(mpp_reset,
#include <trace/define_trace.h>
EOF
	cat >"$fixture/drivers/video/rockchip/rga3/rga_trace.h" <<'EOF'
#define TRACE_SYSTEM rockchip_rga
#include <linux/tracepoint.h>
TRACE_EVENT(rga_req_queued,
TRACE_EVENT(rga_core_selected,
TRACE_EVENT(rga_job_started,
TRACE_EVENT(rga_job_done,
TRACE_EVENT(rga_job_timeout,
TRACE_EVENT(rga_reset,
#include <trace/define_trace.h>
EOF
	printf '%s\n' '#define CREATE_TRACE_POINTS' >"$fixture/drivers/video/rockchip/mpp/mpp_trace.c"
	printf '%s\n' '#define CREATE_TRACE_POINTS' >"$fixture/drivers/video/rockchip/rga3/rga_trace.c"
	printf '%s\n' 'mpp_trace.o' >"$fixture/drivers/video/rockchip/mpp/Makefile"
	printf '%s\n' 'rga_trace.o' >"$fixture/drivers/video/rockchip/rga3/Makefile"
	cat >"$fixture/drivers/video/rockchip/mpp/mpp_common.c" <<'EOF'
static int mpp_task_run(void)
{
mpp_telemetry_task_error();
mpp_telemetry_mark_once();
trace_mpp_task_started();
enable_irq(mpp->irq);
}
trace_mpp_task_queued(); trace_mpp_core_selected();
trace_mpp_task_done(); trace_mpp_task_error(); trace_mpp_reset();
atomic_xchg(&mpp->reset_request, 0);
atomic64_inc(&task->session->telemetry.tasks);
atomic64_add(task->bytes, &task->session->telemetry.bytes);
EOF
	printf '%s\n' 'TASK_STATE_ERROR_REPORTED TASK_STATE_DONE_REPORTED' \
		>"$fixture/drivers/video/rockchip/mpp/mpp_common.h"
	printf '%s\n' 'mpp_telemetry_mark_once' \
		>"$fixture/drivers/video/rockchip/mpp/mpp_telemetry.h"
	cat >"$fixture/drivers/video/rockchip/mpp/mpp_service.c" <<'EOF'
debugfs_create_dir("rockchip-mpp", NULL);
queue_depth busy_ns sessions mpp_telemetry_format_load mpp_telemetry_format_session
debugfs_create_file_aux_num("stats", 0444, session->telemetry_dir, session, 0, &stats_fops);
mpp_session_get(session); mpp_session_put(session);
EOF
	cat >"$fixture/drivers/video/rockchip/rga3/rga_job.c" <<'EOF'
int rga_job_commit(void)
{
trace_rga_req_queued(); trace_rga_core_selected();
}
trace_rga_job_started();
trace_rga_job_done(); trace_rga_job_timeout(); trace_rga_reset();
atomic64_inc(&job->session->telemetry.tasks);
atomic64_add(job->bytes, &job->session->telemetry.bytes);
void rga_telemetry_reset(void) {
atomic64_inc(&scheduler->telemetry.resets);
trace_rga_reset();
reset(scheduler);
}
atomic_sub(removed, &rga_drvdata->telemetry_queue_depth);
EOF
	mkdir -p "$fixture/drivers/video/rockchip/rga3/include"
	printf '%s\n' 'void rga_telemetry_reset(void);' >"$fixture/drivers/video/rockchip/rga3/include/rga_job.h"
	printf '%s\n' 'RGA_JOB_STATE_TELEMETRY_ACCOUNTED' >"$fixture/drivers/video/rockchip/rga3/include/rga_drv.h"
	cat >"$fixture/drivers/video/rockchip/rga3/rga_debugger.c" <<'EOF'
RGA_TELEMETRY_ROOT_NAME queue_depth busy_ns sessions
debugfs_create_file_aux_num("stats", 0444, session->telemetry_dir, session, 0, &stats_fops);
rga_session_get_unless_zero(session); rga_session_put(session);
EOF
	cat >"$fixture/configs/rk3588-media-island.fragment" <<'EOF'
CONFIG_DEBUG_FS=y
CONFIG_FTRACE=y
CONFIG_ENABLE_DEFAULT_TRACERS=y
# CONFIG_FUNCTION_TRACER is not set
CONFIG_ROCKCHIP_RGA_DEBUG_FS=y
EOF

	check_sources "$fixture" >/dev/null
	sed -i '/TRACE_EVENT(mpp_task_done,/d' "$fixture/drivers/video/rockchip/mpp/mpp_trace.h"
	if check_sources "$fixture" >/dev/null 2>&1; then
		fail "missing MPP event mutation passed"
	fi
	printf '%s\n' 'TRACE_EVENT(mpp_task_done,' >>"$fixture/drivers/video/rockchip/mpp/mpp_trace.h"
	sed -i '/mpp_telemetry_task_error/d' "$fixture/drivers/video/rockchip/mpp/mpp_common.c"
	if check_sources "$fixture" >/dev/null 2>&1; then
		fail "missing MPP error call-site mutation passed"
	fi
	sed -i '/trace_mpp_task_started/a mpp_telemetry_task_error();' \
		"$fixture/drivers/video/rockchip/mpp/mpp_common.c"
	sed -i '/CONFIG_DEBUG_FS=y/d' "$fixture/configs/rk3588-media-island.fragment"
	if check_sources "$fixture" >/dev/null 2>&1; then
		fail "missing production debugfs mutation passed"
	fi
	printf '%s\n' 'CONFIG_DEBUG_FS=y' >>"$fixture/configs/rk3588-media-island.fragment"
	sed -i '/debugfs_create_file_aux_num("stats"/d' "$fixture/drivers/video/rockchip/rga3/rga_debugger.c"
	if check_sources "$fixture" >/dev/null 2>&1; then
		fail "missing RGA session stats mutation passed"
	fi

	printf 'telemetry-contract self-test: pass:6 fail:0 total:6\n'
}

case "${1:-}" in
--self-test)
	self_test
	;;
"")
	check_sources "$ROOT"
	;;
*)
	fail "usage: $0 [--self-test]"
	;;
esac
