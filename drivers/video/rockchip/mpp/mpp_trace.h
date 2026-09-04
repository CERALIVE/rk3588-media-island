/* SPDX-License-Identifier: GPL-2.0-only */
#undef TRACE_SYSTEM
#define TRACE_SYSTEM rockchip_mpp

#if !defined(_ROCKCHIP_MPP_TRACE_H) || defined(TRACE_HEADER_MULTI_READ)
#define _ROCKCHIP_MPP_TRACE_H

#include <linux/tracepoint.h>

TRACE_EVENT(mpp_task_queued,
	TP_PROTO(u32 session, u32 task_id, u32 client),
	TP_ARGS(session, task_id, client),
	TP_STRUCT__entry(
		__field(u32, session)
		__field(u32, task_id)
		__field(u32, client)
	),
	TP_fast_assign(
		__entry->session = session;
		__entry->task_id = task_id;
		__entry->client = client;
	),
	TP_printk("session=%u task=%u client=%u", __entry->session,
		  __entry->task_id, __entry->client)
);

TRACE_EVENT(mpp_core_selected,
	TP_PROTO(u32 task_id, s32 core_id, unsigned long core_idle_mask),
	TP_ARGS(task_id, core_id, core_idle_mask),
	TP_STRUCT__entry(
		__field(u32, task_id)
		__field(s32, core_id)
		__field(unsigned long, core_idle_mask)
	),
	TP_fast_assign(
		__entry->task_id = task_id;
		__entry->core_id = core_id;
		__entry->core_idle_mask = core_idle_mask;
	),
	TP_printk("task=%u core=%d idle=0x%lx", __entry->task_id,
		  __entry->core_id, __entry->core_idle_mask)
);

DECLARE_EVENT_CLASS(mpp_task_core,
	TP_PROTO(s32 core_id, u32 task_id),
	TP_ARGS(core_id, task_id),
	TP_STRUCT__entry(
		__field(s32, core_id)
		__field(u32, task_id)
	),
	TP_fast_assign(
		__entry->core_id = core_id;
		__entry->task_id = task_id;
	),
	TP_printk("core=%d task=%u", __entry->core_id, __entry->task_id)
);

DEFINE_EVENT(mpp_task_core, mpp_task_started,
	TP_PROTO(s32 core_id, u32 task_id),
	TP_ARGS(core_id, task_id)
);

TRACE_EVENT(mpp_task_done,
	TP_PROTO(s32 core_id, u32 task_id, u64 ns),
	TP_ARGS(core_id, task_id, ns),
	TP_STRUCT__entry(
		__field(s32, core_id)
		__field(u32, task_id)
		__field(u64, ns)
	),
	TP_fast_assign(
		__entry->core_id = core_id;
		__entry->task_id = task_id;
		__entry->ns = ns;
	),
	TP_printk("core=%d task=%u ns=%llu", __entry->core_id,
		  __entry->task_id, __entry->ns)
);

TRACE_EVENT(mpp_task_error,
	TP_PROTO(s32 core_id, u32 task_id, u32 irq_status),
	TP_ARGS(core_id, task_id, irq_status),
	TP_STRUCT__entry(
		__field(s32, core_id)
		__field(u32, task_id)
		__field(u32, irq_status)
	),
	TP_fast_assign(
		__entry->core_id = core_id;
		__entry->task_id = task_id;
		__entry->irq_status = irq_status;
	),
	TP_printk("core=%d task=%u irq_status=0x%x", __entry->core_id,
		  __entry->task_id, __entry->irq_status)
);

TRACE_EVENT(mpp_reset,
	TP_PROTO(s32 core_id, s32 reason),
	TP_ARGS(core_id, reason),
	TP_STRUCT__entry(
		__field(s32, core_id)
		__field(s32, reason)
	),
	TP_fast_assign(
		__entry->core_id = core_id;
		__entry->reason = reason;
	),
	TP_printk("core=%d reason=%d", __entry->core_id, __entry->reason)
);

#endif

#undef TRACE_INCLUDE_PATH
#define TRACE_INCLUDE_PATH .
#undef TRACE_INCLUDE_FILE
#define TRACE_INCLUDE_FILE mpp_trace

#include <trace/define_trace.h>
