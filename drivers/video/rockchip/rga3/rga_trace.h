/* SPDX-License-Identifier: GPL-2.0-only */
#undef TRACE_SYSTEM
#define TRACE_SYSTEM rockchip_rga

#if !defined(_ROCKCHIP_RGA_TRACE_H) || defined(TRACE_HEADER_MULTI_READ)
#define _ROCKCHIP_RGA_TRACE_H

#include <linux/tracepoint.h>

TRACE_EVENT(rga_req_queued,
	TP_PROTO(u32 session, u32 request, u32 tasks),
	TP_ARGS(session, request, tasks),
	TP_STRUCT__entry(
		__field(u32, session)
		__field(u32, request)
		__field(u32, tasks)
	),
	TP_fast_assign(
		__entry->session = session;
		__entry->request = request;
		__entry->tasks = tasks;
	),
	TP_printk("session=%u request=%u tasks=%u", __entry->session,
		  __entry->request, __entry->tasks)
);

TRACE_EVENT(rga_core_selected,
	TP_PROTO(u32 request, s32 scheduler_id, u32 core_mask_req),
	TP_ARGS(request, scheduler_id, core_mask_req),
	TP_STRUCT__entry(
		__field(u32, request)
		__field(s32, scheduler_id)
		__field(u32, core_mask_req)
	),
	TP_fast_assign(
		__entry->request = request;
		__entry->scheduler_id = scheduler_id;
		__entry->core_mask_req = core_mask_req;
	),
	TP_printk("request=%u scheduler=%d requested=0x%x", __entry->request,
		  __entry->scheduler_id, __entry->core_mask_req)
);

DECLARE_EVENT_CLASS(rga_job_core,
	TP_PROTO(s32 scheduler_id, u32 request),
	TP_ARGS(scheduler_id, request),
	TP_STRUCT__entry(
		__field(s32, scheduler_id)
		__field(u32, request)
	),
	TP_fast_assign(
		__entry->scheduler_id = scheduler_id;
		__entry->request = request;
	),
	TP_printk("scheduler=%d request=%u", __entry->scheduler_id,
		  __entry->request)
);

DEFINE_EVENT(rga_job_core, rga_job_started,
	TP_PROTO(s32 scheduler_id, u32 request),
	TP_ARGS(scheduler_id, request)
);

TRACE_EVENT(rga_job_done,
	TP_PROTO(s32 scheduler_id, u32 request, u64 ns),
	TP_ARGS(scheduler_id, request, ns),
	TP_STRUCT__entry(
		__field(s32, scheduler_id)
		__field(u32, request)
		__field(u64, ns)
	),
	TP_fast_assign(
		__entry->scheduler_id = scheduler_id;
		__entry->request = request;
		__entry->ns = ns;
	),
	TP_printk("scheduler=%d request=%u ns=%llu", __entry->scheduler_id,
		  __entry->request, __entry->ns)
);

DEFINE_EVENT(rga_job_core, rga_job_timeout,
	TP_PROTO(s32 scheduler_id, u32 request),
	TP_ARGS(scheduler_id, request)
);

TRACE_EVENT(rga_reset,
	TP_PROTO(s32 scheduler_id, s32 reason),
	TP_ARGS(scheduler_id, reason),
	TP_STRUCT__entry(
		__field(s32, scheduler_id)
		__field(s32, reason)
	),
	TP_fast_assign(
		__entry->scheduler_id = scheduler_id;
		__entry->reason = reason;
	),
	TP_printk("scheduler=%d reason=%d", __entry->scheduler_id,
		  __entry->reason)
);

#endif

#undef TRACE_INCLUDE_PATH
#define TRACE_INCLUDE_PATH .
#undef TRACE_INCLUDE_FILE
#define TRACE_INCLUDE_FILE rga_trace

#include <trace/define_trace.h>
