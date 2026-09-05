// SPDX-License-Identifier: GPL-2.0
#include <kunit/test.h>
#include <linux/completion.h>
#include <linux/kthread.h>
#include <linux/sched/task.h>
#include "../mpp/media_recovery.h"

#include "../mpp/mpp_recovery_state.h"

static void mpp_session_teardown_orders_every_phase_test(struct kunit *test)
{
	enum mpp_session_teardown_phase phase = MPP_SESSION_LIVE;

	KUNIT_EXPECT_EQ(test, mpp_session_teardown_advance(&phase,
			MPP_SESSION_UNPUBLISHED), 0);
	KUNIT_EXPECT_EQ(test, mpp_session_teardown_advance(&phase,
			MPP_SESSION_TELEMETRY_REMOVED), 0);
	KUNIT_EXPECT_EQ(test, mpp_session_teardown_advance(&phase,
			MPP_SESSION_PRIVATE_RELEASED), 0);
	KUNIT_EXPECT_EQ(test, mpp_session_teardown_advance(&phase,
			MPP_SESSION_MESSAGES_RELEASED), 0);
	KUNIT_EXPECT_EQ(test, mpp_session_teardown_advance(&phase,
			MPP_SESSION_DEAD), 0);
	KUNIT_EXPECT_EQ(test, phase, MPP_SESSION_DEAD);
}

static void mpp_session_teardown_rejects_skipped_phase_test(struct kunit *test)
{
	enum mpp_session_teardown_phase phase = MPP_SESSION_LIVE;

	KUNIT_EXPECT_EQ(test, mpp_session_teardown_advance(&phase,
			MPP_SESSION_PRIVATE_RELEASED), -EINVAL);
	KUNIT_EXPECT_EQ(test, phase, MPP_SESSION_LIVE);
}

static void mpp_session_teardown_rejects_repeated_phase_test(struct kunit *test)
{
	enum mpp_session_teardown_phase phase = MPP_SESSION_LIVE;

	KUNIT_ASSERT_EQ(test, mpp_session_teardown_advance(&phase,
			MPP_SESSION_UNPUBLISHED), 0);
	KUNIT_EXPECT_EQ(test, mpp_session_teardown_advance(&phase,
			MPP_SESSION_UNPUBLISHED), -EINVAL);
	KUNIT_EXPECT_EQ(test, phase, MPP_SESSION_UNPUBLISHED);
}

static void mpp_session_teardown_rejects_backward_phase_test(struct kunit *test)
{
	enum mpp_session_teardown_phase phase = MPP_SESSION_TELEMETRY_REMOVED;

	KUNIT_EXPECT_EQ(test, mpp_session_teardown_advance(&phase,
			MPP_SESSION_UNPUBLISHED), -EINVAL);
	KUNIT_EXPECT_EQ(test, phase, MPP_SESSION_TELEMETRY_REMOVED);
}

static void mpp_task_timeout_moves_pending_running_to_done_test(struct kunit *test)
{
	unsigned long state = 0;

	KUNIT_ASSERT_TRUE(test, mpp_task_recovery_mark_pending(&state));
	KUNIT_EXPECT_TRUE(test, test_bit(TASK_STATE_PENDING, &state));
	KUNIT_ASSERT_TRUE(test, mpp_task_recovery_mark_running(&state));
	KUNIT_EXPECT_TRUE(test, test_bit(TASK_STATE_RUNNING, &state));
	KUNIT_EXPECT_TRUE(test, mpp_task_recovery_claim(&state,
			MPP_TASK_RECOVERY_TIMEOUT));
	KUNIT_EXPECT_TRUE(test, test_bit(TASK_STATE_TIMEOUT, &state));
	KUNIT_EXPECT_TRUE(test, mpp_task_recovery_finish(&state));
	KUNIT_EXPECT_TRUE(test, test_bit(TASK_STATE_FINISH, &state));
	KUNIT_EXPECT_TRUE(test, test_bit(TASK_STATE_DONE, &state));
	KUNIT_EXPECT_FALSE(test, mpp_task_recovery_finish(&state));
}

static void mpp_task_irq_and_timeout_have_one_owner_test(struct kunit *test)
{
	unsigned long state = 0;

	KUNIT_ASSERT_TRUE(test, mpp_task_recovery_mark_pending(&state));
	KUNIT_ASSERT_TRUE(test, mpp_task_recovery_mark_running(&state));
	KUNIT_EXPECT_TRUE(test, mpp_task_recovery_claim(&state,
			MPP_TASK_RECOVERY_IRQ));
	KUNIT_EXPECT_FALSE(test, mpp_task_recovery_claim(&state,
			MPP_TASK_RECOVERY_TIMEOUT));
	KUNIT_EXPECT_TRUE(test, test_bit(TASK_STATE_IRQ, &state));
	KUNIT_EXPECT_FALSE(test, test_bit(TASK_STATE_TIMEOUT, &state));
}

static void mpp_task_rejects_finish_before_claim_test(struct kunit *test)
{
	unsigned long state = 0;

	KUNIT_ASSERT_TRUE(test, mpp_task_recovery_mark_pending(&state));
	KUNIT_ASSERT_TRUE(test, mpp_task_recovery_mark_running(&state));
	KUNIT_EXPECT_FALSE(test, mpp_task_recovery_finish(&state));
	KUNIT_EXPECT_FALSE(test, test_bit(TASK_STATE_FINISH, &state));
	KUNIT_EXPECT_FALSE(test, test_bit(TASK_STATE_DONE, &state));
}

static void mpp_task_failed_run_uses_abort_owner_test(struct kunit *test)
{
	unsigned long state = 0;

	KUNIT_ASSERT_TRUE(test, mpp_task_recovery_mark_pending(&state));
	KUNIT_ASSERT_TRUE(test, mpp_task_recovery_mark_running(&state));
	KUNIT_EXPECT_TRUE(test, mpp_task_recovery_claim(&state,
			MPP_TASK_RECOVERY_ABORT));
	KUNIT_EXPECT_TRUE(test, test_bit(TASK_STATE_ABORT, &state));
	KUNIT_EXPECT_FALSE(test, mpp_task_recovery_claim(&state,
			MPP_TASK_RECOVERY_TIMEOUT));
	KUNIT_EXPECT_TRUE(test, mpp_task_recovery_finish(&state));
}

static void mpp_task_rejects_running_before_pending_test(struct kunit *test)
{
	unsigned long state = 0;

	KUNIT_EXPECT_FALSE(test, mpp_task_recovery_mark_running(&state));
	KUNIT_EXPECT_FALSE(test, test_bit(TASK_STATE_RUNNING, &state));
}

static void mpp_task_rejects_claim_before_running_test(struct kunit *test)
{
	unsigned long state = 0;

	KUNIT_ASSERT_TRUE(test, mpp_task_recovery_mark_pending(&state));
	KUNIT_EXPECT_FALSE(test, mpp_task_recovery_claim(&state,
			MPP_TASK_RECOVERY_ABORT));
	KUNIT_EXPECT_FALSE(test, test_bit(TASK_STATE_HANDLE, &state));
	KUNIT_EXPECT_FALSE(test, test_bit(TASK_STATE_ABORT, &state));
}

static void mpp_task_rejects_repeated_milestones_test(struct kunit *test)
{
	unsigned long state = 0;

	KUNIT_ASSERT_TRUE(test, mpp_task_recovery_mark_pending(&state));
	KUNIT_EXPECT_FALSE(test, mpp_task_recovery_mark_pending(&state));
	KUNIT_ASSERT_TRUE(test, mpp_task_recovery_mark_running(&state));
	KUNIT_EXPECT_FALSE(test, mpp_task_recovery_mark_running(&state));
}

struct media_recovery_race {
	struct media_recovery recovery;
	struct completion start;
	atomic_t sequences;
};

static int media_recovery_racer(void *arg)
{
	struct media_recovery_race *race = arg;
	s64 epoch = atomic64_read(&race->recovery.recovery_epoch);
	int i;

	wait_for_completion(&race->start);
	for (i = 0; i < 1000; i++)
		if (media_recovery_claim(&race->recovery, epoch))
			atomic_inc(&race->sequences);
	return 0;
}

static void media_recovery_concurrent_epoch_test(struct kunit *test)
{
	struct media_recovery_race race;
	struct task_struct *threads[2] = {};
	int i;

	media_recovery_init(&race.recovery);
	init_completion(&race.start);
	atomic_set(&race.sequences, 0);
	for (i = 0; i < ARRAY_SIZE(threads); i++) {
		threads[i] = kthread_run(media_recovery_racer, &race, "media-recover-%d", i);
		KUNIT_EXPECT_FALSE(test, IS_ERR(threads[i]));
		if (IS_ERR(threads[i])) {
			threads[i] = NULL;
			break;
		}
		get_task_struct(threads[i]);
	}
	complete_all(&race.start);
	for (i = 0; i < ARRAY_SIZE(threads); i++) {
		if (!threads[i])
			continue;
		kthread_stop(threads[i]);
		put_task_struct(threads[i]);
	}
	KUNIT_EXPECT_EQ(test, atomic_read(&race.sequences), 1);
}

static void media_recovery_later_epoch_test(struct kunit *test)
{
	struct media_recovery recovery;
	unsigned int sequences = 0;
	s64 old_epoch;

	media_recovery_init(&recovery);
	old_epoch = atomic64_read(&recovery.recovery_epoch);
	sequences += media_recovery_claim(&recovery, old_epoch);
	sequences += media_recovery_claim(&recovery, old_epoch);
	KUNIT_EXPECT_EQ(test, sequences, 1u);
	media_recovery_started(&recovery);
	sequences += media_recovery_claim(&recovery, atomic64_read(&recovery.recovery_epoch));
	KUNIT_EXPECT_EQ(test, sequences, 2u);
	KUNIT_EXPECT_FALSE(test, media_recovery_claim(&recovery, old_epoch));
}

static struct kunit_case mpp_recovery_state_cases[] = {
	KUNIT_CASE(media_recovery_concurrent_epoch_test),
	KUNIT_CASE(media_recovery_later_epoch_test),
	KUNIT_CASE(mpp_session_teardown_orders_every_phase_test),
	KUNIT_CASE(mpp_session_teardown_rejects_skipped_phase_test),
	KUNIT_CASE(mpp_session_teardown_rejects_repeated_phase_test),
	KUNIT_CASE(mpp_session_teardown_rejects_backward_phase_test),
	KUNIT_CASE(mpp_task_timeout_moves_pending_running_to_done_test),
	KUNIT_CASE(mpp_task_irq_and_timeout_have_one_owner_test),
	KUNIT_CASE(mpp_task_rejects_finish_before_claim_test),
	KUNIT_CASE(mpp_task_failed_run_uses_abort_owner_test),
	KUNIT_CASE(mpp_task_rejects_running_before_pending_test),
	KUNIT_CASE(mpp_task_rejects_claim_before_running_test),
	KUNIT_CASE(mpp_task_rejects_repeated_milestones_test),
	{}
};

static struct kunit_suite mpp_recovery_state_suite = {
	.name = "rockchip-mpp-recovery-state",
	.test_cases = mpp_recovery_state_cases,
};

kunit_test_suite(mpp_recovery_state_suite);

MODULE_LICENSE("GPL");
