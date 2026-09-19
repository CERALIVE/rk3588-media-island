# RGA job lifetime across commit and completion

Concern: who owns a `struct rga_job` allocation between the moment
`rga_job_commit()` publishes it to a scheduler queue and the moment that same
function finishes reading it. Source: `drivers/video/rockchip/rga3/rga_job.c`.

This is a job-lifetime concern only. It does not revise the memory
classification, page-table ownership or failed-reset retention work recorded in
[`RGA-MEMORY-ADDRESSABILITY.md`](RGA-MEMORY-ADDRESSABILITY.md), and it changes
no mapping, routing or reset behaviour.

## The ownership gap

`rga_job_alloc()` initialises exactly one reference. That reference belonged to
the committer, and nothing else took one across queue publication:

1. `rga_job_commit()` calls `rga_job_insert_todo_list()`, which links `job->head`
   into `scheduler->todo_list` under `job_mutex` and `irq_lock`, then drops both
   locks and returns. It acquired no queue reference of its own.
2. The committer then keeps reading the job — `task_count`, `task_list`, `bytes`,
   `session` and `request_id` for its queue/selection telemetry — holding neither
   a scheduler lock nor a reference it owns.
3. From the instant those locks drop, another core may dispatch the job. The
   dispatcher's own get/put in `rga_job_next()` is temporary and protects the
   dispatcher, not the committer.
4. Hardware completion reaches `rga_isr_thread()` →
   `rga_request_release_signal()` → `rga_job_cleanup()`, which drops the last
   remaining reference and frees the allocation.

Under sustained composition load, step 4 can complete before step 2 finishes, so
the committer reads an allocation completion has already released. The window is
short and load-dependent, which is why it presents as intermittent memory
corruption under heavy encode/decode/RGA traffic rather than as a deterministic
failure.

The request's `commit_lock` does not close this: ordinary completion never takes
it. Taking a reference *after* `rga_job_insert_todo_list()` returns does not
close it either — by then the object can already be gone. The reference has to be
acquired before publication, while the queue locks are still held.

## The change

- `rga_job_insert_todo_list()` takes a queue reference *before* linking the job,
  on the admitted path only. The queue-full, shutdown and faulted-core refusals
  take no reference and are unchanged.
- `rga_job_commit()` drops the allocation reference after its last job access,
  outside the scheduler locks and the request-manager lock, so the existing
  destructor and its parent reference puts run safely.
- The pre-publication failure path calls `rga_job_put()` instead of
  `rga_job_free()`, so the sole allocation reference is released through the same
  destructor rather than bypassing the refcount.

Resulting ownership: the committer and the scheduler each hold one reference and
either may finish first; destruction happens only after both are done. Completion,
expiry and cancellation consume the scheduler's reference exactly as before, and
failed reset retains it exactly as before.

## Reproducer

Run from the island checkout, without a board, network or kernel build:

```sh
python3 docs/repro/rga-commit-lifetime.py
```

The runner extracts seven complete maintained functions from `rga_job.c`
byte-preserving their bodies — `rga_job_free`, `rga_job_kref_release`,
`rga_job_put`, `rga_job_get`, `rga_job_cleanup`, `rga_job_insert_todo_list` and
`rga_job_commit` — and compiles them against `docs/repro/rga-commit-lifetime.c.in`
with AddressSanitizer and UndefinedBehaviorSanitizer. Hardware, locks, the
allocator and the completion trigger are fixtures. Retirement is forced at the
publication unlock with no timing sleeps, and the scheduler's terminal drop goes
through the real `rga_job_cleanup()`.

Twelve modes are asserted: immediate retirement at publication unlock, retirement
delayed past commit's return, queue-full / shutdown / faulted-core admission
refusals, immediate retirement of a two-task job, and the six preparation,
validation, power, command-allocation, mapping and register-initialisation
failure paths. Each asserts exactly one free, balanced request/session references,
balanced commit power, correct queue accounting, and telemetry only on admitted
jobs.

Against the unchanged source the runner exits 1 and the sanitizer reports the
committer reading released memory, with the allocation, release and access sites
in `rga_job_commit`, `rga_job_cleanup` ← `rga_job_insert_todo_list` and
`rga_job_commit` respectively — the same three-site relationship the board
instrumentation recorded. With the change applied all twelve modes pass. The
gate runs in CI through `scripts/check-rga-memory.sh`.

## Verification limits

The host reproducer proves software ownership only. It does not emulate DMA, IRQ
scheduling, hardware reset, expiry timing, runtime-PM locking or concurrent
parent teardown; those paths were reviewed, not executed here. The fixture uses a
smaller host struct, so its field offsets and object size differ from arm64 and no
offset claim transfers. Board qualification is recorded separately in
[`BOARD-QUALIFICATION.md`](BOARD-QUALIFICATION.md).
