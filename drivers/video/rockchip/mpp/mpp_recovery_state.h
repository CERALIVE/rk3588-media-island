/* SPDX-License-Identifier: (GPL-2.0+ OR MIT) */
#ifndef __ROCKCHIP_MPP_RECOVERY_STATE_H__
#define __ROCKCHIP_MPP_RECOVERY_STATE_H__

#include <linux/bitops.h>
#include <linux/errno.h>

enum mpp_task_state {
	TASK_STATE_PENDING = 0,
	TASK_STATE_RUNNING = 1,
	TASK_STATE_START = 2,
	TASK_STATE_HANDLE = 3,
	TASK_STATE_IRQ = 4,
	TASK_STATE_FINISH = 5,
	TASK_STATE_TIMEOUT = 6,
	TASK_STATE_DONE = 7,
	TASK_STATE_PREPARE = 8,
	TASK_STATE_ABORT = 9,
	TASK_STATE_ABORT_READY = 10,
	TASK_STATE_PROC_DONE = 11,
	TASK_STATE_ERROR_REPORTED = 12,
	TASK_STATE_DONE_REPORTED = 13,
	TASK_STATE_BUSY_REPORTED = 14,
	TASK_TIMING_CREATE = 16,
	TASK_TIMING_CREATE_END = 17,
	TASK_TIMING_PENDING = 18,
	TASK_TIMING_RUN = 19,
	TASK_TIMING_TO_SCHED = 20,
	TASK_TIMING_RUN_END = 21,
	TASK_TIMING_IRQ = 22,
	TASK_TIMING_TO_CANCEL = 23,
	TASK_TIMING_FINISH = 24,
};

enum mpp_session_teardown_phase {
	MPP_SESSION_LIVE = 0,
	MPP_SESSION_UNPUBLISHED,
	MPP_SESSION_TELEMETRY_REMOVED,
	MPP_SESSION_PRIVATE_RELEASED,
	MPP_SESSION_MESSAGES_RELEASED,
	MPP_SESSION_DEAD,
};

enum mpp_task_recovery_cause {
	MPP_TASK_RECOVERY_IRQ,
	MPP_TASK_RECOVERY_TIMEOUT,
	MPP_TASK_RECOVERY_ABORT,
};

static inline int
mpp_session_teardown_advance(enum mpp_session_teardown_phase *phase,
			     enum mpp_session_teardown_phase next)
{
	if (next != *phase + 1)
		return -EINVAL;
	*phase = next;
	return 0;
}

static inline bool mpp_task_recovery_mark_pending(unsigned long *state)
{
	if (test_bit(TASK_STATE_PENDING, state) ||
	    test_bit(TASK_STATE_RUNNING, state) ||
	    test_bit(TASK_STATE_HANDLE, state))
		return false;
	set_bit(TASK_STATE_PENDING, state);
	return true;
}

static inline bool mpp_task_recovery_mark_running(unsigned long *state)
{
	if (!test_bit(TASK_STATE_PENDING, state) ||
	    test_bit(TASK_STATE_RUNNING, state) ||
	    test_bit(TASK_STATE_HANDLE, state))
		return false;
	set_bit(TASK_STATE_RUNNING, state);
	return true;
}

static inline bool
mpp_task_recovery_claim(unsigned long *state, enum mpp_task_recovery_cause cause)
{
	if (!test_bit(TASK_STATE_RUNNING, state))
		return false;
	if (test_and_set_bit(TASK_STATE_HANDLE, state))
		return false;
	if (cause == MPP_TASK_RECOVERY_IRQ)
		set_bit(TASK_STATE_IRQ, state);
	else if (cause == MPP_TASK_RECOVERY_TIMEOUT)
		set_bit(TASK_STATE_TIMEOUT, state);
	else
		set_bit(TASK_STATE_ABORT, state);
	return true;
}

static inline bool mpp_task_recovery_finish(unsigned long *state)
{
	if (!test_bit(TASK_STATE_HANDLE, state))
		return false;
	if (test_and_set_bit(TASK_STATE_FINISH, state))
		return false;
	set_bit(TASK_STATE_DONE, state);
	return true;
}

#endif
