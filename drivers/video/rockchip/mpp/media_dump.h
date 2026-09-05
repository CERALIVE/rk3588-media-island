/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef ROCKCHIP_MEDIA_DUMP_H
#define ROCKCHIP_MEDIA_DUMP_H

#include <linux/devcoredump.h>
#include <linux/ktime.h>
#include <linux/spinlock.h>
#include <linux/workqueue.h>

#define MEDIA_DUMP_BYTES 4096
#define MEDIA_DUMP_EVENTS 8
#define MEDIA_DUMP_REGS 16

enum media_dump_event {
	MEDIA_STARTED = 1,
	MEDIA_DONE,
	MEDIA_FAULT,
	MEDIA_RESET,
	MEDIA_QUEUED,
	MEDIA_SELECTED,
};

struct media_dump_event_record {
	u64 ns;
	u32 event, task, status;
};

struct media_dump_record {
	u32 task, core, status, reg_base, reg_count;
	u64 iova, span;
	u32 regs[MEDIA_DUMP_REGS];
	struct media_dump_event_record events[MEDIA_DUMP_EVENTS];
};

struct media_dump {
	struct device *dev;
	spinlock_t lock;
	struct work_struct work;
	atomic_t queued;
	u32 next;
	struct media_dump_event_record events[MEDIA_DUMP_EVENTS];
	struct media_dump_record pending;
};

static inline void media_dump_submit(struct device *dev, void **owned, size_t len)
{
	void *data = *owned;

	*owned = NULL;
	dev_coredumpv(dev, data, len, GFP_KERNEL);
}

static inline size_t media_dump_format(char *data, const struct media_dump_record *r)
{
	size_t n;
	unsigned int i;

	n = scnprintf(data, MEDIA_DUMP_BYTES,
		"media-island snapshot v1\ntask=%u core=%u status=%#x\niova=%#llx span=%#llx\n",
		r->task, r->core, r->status, r->iova, r->span);
	for (i = 0; i < min_t(u32, r->reg_count, MEDIA_DUMP_REGS); i++)
		n += scnprintf(data + n, MEDIA_DUMP_BYTES - n, "reg[%#x]=%#x\n",
			       r->reg_base + i * 4, r->regs[i]);
	for (i = 0; i < MEDIA_DUMP_EVENTS; i++)
		n += scnprintf(data + n, MEDIA_DUMP_BYTES - n,
			       "event=%u task=%u status=%#x ns=%llu\n",
			       r->events[i].event, r->events[i].task,
			       r->events[i].status, r->events[i].ns);
	return n;
}

static inline void media_dump_work(struct work_struct *work)
{
	struct media_dump *dump = container_of(work, struct media_dump, work);
	void *owned = vzalloc(MEDIA_DUMP_BYTES);

	/* queued excludes writers until submission has relinquished the buffer. */
	if (owned)
		media_dump_submit(dump->dev, &owned,
				  media_dump_format(owned, &dump->pending));
	atomic_set_release(&dump->queued, 0);
}

static inline void media_dump_cancel(void *data)
{
	struct media_dump *dump = data;

	cancel_work_sync(&dump->work);
}

static inline int media_dump_init(struct media_dump *dump, struct device *dev)
{
	dump->dev = dev;
	spin_lock_init(&dump->lock);
	atomic_set(&dump->queued, 0);
	INIT_WORK(&dump->work, media_dump_work);
	return devm_add_action_or_reset(dev, media_dump_cancel, dump);
}

static inline void media_dump_event(struct media_dump *dump, u32 event,
				    u32 task, u32 status)
{
	unsigned long flags;
	struct media_dump_event_record *record;

	spin_lock_irqsave(&dump->lock, flags);
	record = &dump->events[dump->next++ % MEDIA_DUMP_EVENTS];
	*record = (struct media_dump_event_record) {
		.ns = ktime_get_ns(), .event = event, .task = task, .status = status,
	};
	spin_unlock_irqrestore(&dump->lock, flags);
}

static inline void media_dump_capture(struct media_dump *dump,
				      const struct media_dump_record *record)
{
	unsigned long flags;
	unsigned int i;

	if (atomic_cmpxchg_acquire(&dump->queued, 0, 1))
		return;
	spin_lock_irqsave(&dump->lock, flags);
	dump->pending = *record;
	for (i = 0; i < MEDIA_DUMP_EVENTS; i++)
		dump->pending.events[i] = dump->events[(dump->next + i) % MEDIA_DUMP_EVENTS];
	spin_unlock_irqrestore(&dump->lock, flags);
	schedule_work(&dump->work);
}

#endif
