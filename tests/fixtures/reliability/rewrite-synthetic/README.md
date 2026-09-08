# rewrite-synthetic — SYNTHETIC fixtures, never board evidence

Every file in this directory is **synthetic**. Nothing here was captured from a
board, a boot, or a kernel of any kind. No number in these files may be quoted
as a measurement, copied into a ledger cell, or cited as a rewrite result. The
real rewrite comparison run belongs in `docs/media-island/ledger/`, and it is
the only place a rewrite number may come from.

They exist for one reason: `tests/board/fault-matrix.sh --self-test` has to
prove that the **rewrite** driver profile scores in both directions on a dev
host with no board attached. The island profile can be scored against the
committed Orange Pi captures in `../orange-pi-5-plus/`; the rewrite profile has
no captures yet, and a self-test that can only score one profile would leave the
profile most likely to be wrong entirely unexercised.

## How they were generated

By hand, from the rewrite's own debugfs layout, in the exact line format
`snapshot_rewrite()` writes. Each line's provenance:

| line | debugfs source | notes |
|---|---|---|
| `<device> busy <0\|1>` | `rk_mpp_rewrite/state`, `# hardware:` section, `active_job` column | 1 when a job owns that core, 0 otherwise |
| `<client>_core<N> resets <n>` | `rk_mpp_rewrite/reset_{av1dec,rkvdec,rkvenc}_core{0..3}_count` | 3 clients × 4 cores = 12 files |
| `global queue_depth <n>` | `rk_mpp_rewrite/queued_job_count` | a live depth, not a cumulative counter |
| `global dmabufs <n>` | `/sys/kernel/debug/dma_buf/bufinfo` | kernel-global, identical on both profiles |
| `global iommu_maps GAP:no-sessions-summary` | — | the rewrite ships no `sessions-summary`; the gap is labelled, never faked |
| `fault <knob>_consumed <n>` | `rkvenc-test/*consumed` | same names as the island seam |

The device names (`fdbd0000.rkvenc-core`, `fdbe0000.rkvenc-core`,
`fdc38100.rkvdec-core`) are the RK3588 mainline spellings. They are plausible
placeholders, not an observation.

## What the fixture set encodes

One `hardware-hang` row that survives its stimulus:

- `.idle-baseline` — the quiet board before the healthy encode starts.
- `.before` — mid-stimulus: one encoder core busy, one job queued, 12 dma-bufs
  live.
- `.after` — recovered: nothing busy, nothing queued, dma-bufs back to the idle
  baseline, `rkvenc_core0` reset once more than in `.before` (the reset delta
  the four fault rows require), and `hang_task_once_consumed` incremented by
  exactly one.
- `.journal` — a recovery window with no line matching the harness's bad-line
  screen and none matching its fatal-signature set.

The self-test scores this set as `SURVIVE gaps=iommu_maps=GAP:no-sessions-summary`
and then mutates it four ways — a one-shot that never reported a consume, a
`KASAN:` line inside the journal window, a core still busy after recovery, and
leaked dma-bufs — each of which must turn the same scorer RED. The mutations are
generated in a scratch directory at run time and are not committed.
