# RGA memory addressability: defect model and fix plan

Status: **[PARTIAL] — source repair and software regressions; not released or
board-qualified.** Updated 2026-09-14. The combined table-ownership and routing
repair is described below. The historical design and pre-fix observations remain
as the acceptance record. No device tree, userspace library, image pin or board
state is changed by this work.

## Combined source repair

The non-handle RGA2 table ring is removed. Every translated channel, including
multi-plane jobs, allocates a private DMA32 table using four-byte PTEs, maps it
for the executing RGA2 device, and owns it until terminal cleanup. One helper
unmaps/frees the table on completion, successful reset and partial construction
failure before DMA starts. No consumer cursor or reservation window remains.

Legacy fd and USERPTR buffers are retained before core selection. Their physical
backing classification feeds the same RGA3 preference as imported handles; all
handle planes are checked and lookup errors propagate. The existing capability
intersection still governs formats, geometry, operations and explicit core
masks. Busy compatible RGA3 cores remain eligible for the least-queued choice,
up to 32 queued jobs per core. Saturated admission returns `-EAGAIN`; idle RGA2
does not override that preference. Single-core selection also passes through
policy rather than bypassing it. The queue cap is checked again under the
scheduler lock at insertion. Queued jobs older than 1,000 ms are retired with
`-ETIMEDOUT` instead of starting. Synchronous wait expiration cancels the whole
request, including queued jobs, before returning `-ETIMEDOUT`; only a completed
request that won the cancellation lock may still return success. Hardware/wait
timeouts use explicit milliseconds, converted to jiffies at the wait boundary.

DMA-BUF classification uses a capable IOMMU attachment, never an exploratory
RGA2 exporter map. The attachment's actual core owns the retained IOVA. Once
RGA2 is selected, reachable DMA-BUFs and USERPTRs get an RGA2-owned execution
mapping even when their backing pages are low and contiguous. PTEs use that
mapping's DMA addresses, not `sg_phys()` or an RGA3 IOVA; cache synchronization
uses its device and mapping direction. Execution mappings are unmapped before
the retained imported-buffer reference is released. Raw physical-address imports
keep their existing direct-address contract; coherent debug buffers use their
allocation's device DMA address. High buffers use the job-shared DMA32 stage.
An absent capable classification
device returns `-ENODEV`; exporter errors are not retried as speculative RGA2
maps. This deliberately does not introduce an exporter-private page-access API.

High-memory USERPTR work forced onto RGA2 uses job-owned DMA32 pages indexed by
original PFN, including original pages behind head/tail shadows. Overlapping
virtual ranges therefore share staged bytes across channels and sequential
tasks. Writable-byte masks limit copy-back to the submitted writable spans;
failed/cancelled jobs do not copy the stage back. Source page references outlive
the stage. The existing 64 MiB/job, 128 MiB/session and 256 MiB/global admission
limits cover both DMA-BUF and USERPTR staging; they were not increased.

Owned SG construction respects the minimum of the advertised segment limit and
the DMA backend maximum, rounded down to a page. RGA2 publishes the backend
limit and rejects a sub-page ceiling. The 32/32 RGA2 masks, RGA3 masks and
page-offset alignment declaration are unchanged. This does not split an
exporter's existing SG list, enlarge swiotlb, or change the PTE address width.

Run the host software gate from this checkout:

```sh
bash scripts/check-rga-memory.sh
```

The gate is registered in the existing CI self-tests job. It compiles maintained
functions or includes the maintained staging implementation directly, with
bounded host fixtures at the kernel allocation/DMA boundary. It covers:

- 262,144 simultaneously live entries as four large tables and as 256 tasks;
  pairwise table-address disjointness, four-byte allocation sizing, reverse
  teardown and an additional construction failure while those tables are live;
- allocation, each multi-plane fill, and table-map failure unwind;
- high-memory RGA2 import with zero failed RGA2 mapping attempts;
- high planes in every handle position, legacy fd/USERPTR preparation,
  preparation failure, busy-RGA3 routing and explicit RGA2 selection;
- USERPTR aliases, untouched destination bytes, cancellation, allocation/map/
  xarray failures and bounded resource errors.

Before repair, the maintained table builder produced **one overlapping pair**
for four large tables and **64 overlapping pairs** for the 256-task case.
Both held 262,144 entries live, exceeding the former 196,611-entry capacity.
The import reproducer returned success only after **one failed RGA2 map**.
The routing test additionally exposed ignored UV/V handles and high USERPTRs
selecting idle RGA2. Those are software RED observations, not new board results.

These tests do not implement Linux DMA, exercise the real cache hierarchy,
validate pixels, or qualify hardware concurrency. Module/KUnit/static-analysis
evidence must be reported separately. H7 causality and frame conservation remain
unproven. The external-CRU reset defect was already repaired independently in
`v2026.9.3`; neither this ring nor a generic cross-core race is reintroduced as
its cause. No `MMU_CTRL0` write is part of this repair.

Release, consumer-lane merge, image-pin merge, image build and both-board
qualification remain separate, later gates. A pushed source branch reaches no
device and does not authorize any of those gates.

### Software verification receipt

The host memory regressions passed after repair. The RGA arm64 module linked
with `KCFLAGS=-Werror` against a prepared Linux 7.2 derivative of the pinned
baseline; sparse completed with `CF=-Wsparse-error`. Source LSP diagnostics,
the ioctl-staging self-test, shim and modernization checks, module/telemetry
source contracts, ShellCheck, Ruff and the board-harness/tooling **host fixture**
self-tests passed. Generated-series verification reconstructs 87 source files
and preserves all eight integration payloads; the census increased by one for
the new private USERPTR staging header.

**The complete repository gate is not claimed green.** The unchanged MPP
hardening check reports `partial clock enable unwinds` as its one failure
(22/23 checks pass); neither its MPP source nor its test was changed. KUnit
kernel execution and coccinelle were not run: no prepared UML build or `spatch`
binary was available. The host ioctl-staging check is not a substitute for
executing KUnit. No hardware command or silicon qualification was performed.

### Review fixes: failed reset is not quiescence

The RGA2 reset poll now returns `-ETIMEDOUT` on failure; both backend reset
callbacks return status, and the recovery wrapper preserves the result of an
already-claimed epoch. The per-job initialization reset does not consume an
error-recovery claim. Error recovery's epoch starts before hardware execution,
so an interrupt immediately after START cannot inherit the initialization result.

An unsuccessful reset permanently faults that scheduler. Its running job,
command buffer, PTEs, buffer mappings, pins and power reference remain retained;
timeout, cancel, shutdown and late interrupts cannot free them or start another
job on that core. A module reference prevents unload after a failed reset, and
the platform drivers suppress manual bind/unbind attributes so devres cannot
withdraw a live DMA device. Recovery is by reboot, not a blind retry or a claim
that clock gating proves DMA drained. Queued requests can still be cancelled
and freed, since they never started; unrelated healthy cores remain eligible.
This intentionally trades retained memory and power on a failed core for safety.
An asynchronous request on that core may need explicit cancellation; no successful
completion is fabricated. No `MMU_CTRL0` write or external RGA2 CRU reset was added.

The strengthened `LOW_RGA2_CONTROL` was RED on `f5b2fb06e` with `rga2_maps=0`;
it now requires a nonzero RGA2 map count. A new KUnit reset-failure test was RED
on the same source: abort unmapped the PTE and retired the job despite a forced
`-ETIMEDOUT`. A separate queued-deadline test was RED because the wait returned
zero and left the request queued. The expanded KUnit suites exercise the actual
reset poll/wrapper, timeout/cancel/shutdown retention, queue admission/expiry,
and low-buffer execution mapping with deliberately nonidentity DMA addresses,
PTE construction, both cache-sync directions and mapping failure. These are
software boundary fixtures, not cache-coherency or silicon qualification.

The [review-fix verification receipt](verification/rga-review-24a8b5b60.md)
records the final module/sparse/parity results, 57 executed RGA KUnit passes,
the RED observations and artifact hashes.

## Decision

Treat memory-layout-dependent RGA failure as a **driver defect**, not a board
characteristic. Keep high-memory buffers usable through the RGA3 IOMMUs; keep
RGA2 useful through direct reachable mappings and bounded, correctly synchronized
staging when an operation actually requires RGA2. Do not constrain the whole
pipeline to low RAM, raise RGA2's DMA mask, add a fictitious RGA2 IOMMU, or enlarge
swiotlb.

Implement **classify before device mapping and schedule before expensive staging**,
with accurate per-core DMA constraints. This is a correction to existing routing,
not a new RGA3-only driver. A probe-order inversion is a useful first regression
fix, but it is not the complete memory-configuration-independent design.

“Any DRAM configuration” means legal buffers remain usable regardless of where
the OS places them, within the actual hardware/IOMMU address widths and finite
resources. It cannot mean infinite queue capacity, arbitrary physical-address
imports, or success after genuine allocation failure. Those cases require exact,
bounded errors, not truncation, corruption or a memory-size-dependent hang.

## Evidence and source coordinate

The controlled comparison is established evidence, not rerun here:

| Observation | Rock 5B+ | Orange Pi 5+ |
|---|---:|---:|
| MemTotal | 7,970,296 kB | 3,856,360 kB |
| RAM above 4 GiB | 4.25 GiB | 256 MiB |
| Buffer flags | 40/40 `0x2`, UNDER_4G clear | 76/76 `0x3`, UNDER_4G set |
| DMA32 staging | 10 attempts / 10 successes | 0 attempts |
| swiotlb mapping diagnostics | 9, each requesting 1,048,576 bytes | 0 |

Same silicon, kernel release string `7.2.0-ceralive-rk3588`, driver, binary and
command; the opposite results were predicted from the memory maps. The OPi is
the approximately 4 GiB configuration, **not 16 GiB**. Its 256 MiB above the line
also means a “4 GiB board” must not be assumed always safe.

Source references below use repository commit
`40ea5400398d9157c6da4a00ea7fa4f2a5c2294e`, prefix
`drivers/video/rockchip/rga3/` unless specified. A fetch confirmed canonical
`main` at `b9602a0a49432817c0689ce90b83590b7e52d5b4`; `rga_mm.c` and
`rga_policy.c` are identical between those coordinates. The relevant probe code
also matches; the `rga_drv.c` diff concerns test-seam initialization elsewhere.
These are source coordinates, not a claim that today's boards loaded this exact
worktree. The image pin supplied for this investigation is
`087b440ffcb1676be1f35a6dccd9b2c46edebbd6`; future runs must additionally record
the actual Image/module hashes, because the release string alone is insufficient.

## One model for the controlled low/high-memory split

1. **Reachability is per core, not per board.** RGA2's internal MMU stores 32-bit
   **byte addresses**. `rga_mm.c:1881-1907` rejects a page above
   `SZ_4G - PAGE_SIZE` before narrowing. RGA3 has an external IOMMU and maps high
   backing pages to a device-usable IOVA. RGA2's lack of an external IOMMU is
   correct topology, not missing DT wiring.
2. **The declared masks are already correct for this RK3588 path.**
   `include/rga_dma_policy.h:12-25` specifies RGA2 streaming/coherent **32/32**
   and RGA3 **40/32**. `rga_drv.c:1624-1634` sets both and checks both errors.
   Changing those numbers is not the fix. Coherent limits cover allocations
   made through the device's coherent DMA API; they do not relocate arbitrary
   imported backing pages or every `GFP_KERNEL` allocation.
3. **One shared segment declaration is wrong for the bounced path.**
   `rga_drv.c:1735-1741` advertises almost 4 GiB segments for every core.
   RGA2 may instead hit the DMA backend's single-mapping ceiling. In the
   recorded run, swiotlb had only about 205/32,768 slots occupied, but a
   1 MiB entry exceeded its 256 KiB single-mapping limit. Capacity and
   maximum individual mapping size are different constraints. A larger pool
   cannot make that entry legal.
4. **The importer discovers the problem after attempting the doomed operation.**
   `rga_mm_map_dma_buffer()` chooses the selected job core at `:812`, calls the
   exporter at `:843`, retries through the default IOMMU core only after
   `-EIO` at `:845-864`, and classifies physical reachability at `:883`.
   `rga_dma_buf.c:557-568` attaches and maps the exporter table before it can
   inspect the returned table. “Page granular” is not a request to split that
   exporter table before mapping.
5. **Recovery already exists, but is too late to avoid the diagnostic.**
   `rga_mm.c:2340-2343` sends high DMA-BUFs to a job-shared DMA32 stage;
   `:2175-2202` allocates low pages and builds a segment-limited owned table.
   This explains successful staging alongside mapping diagnostics. It does
   **not** prove each diagnostic caused an ioctl failure, lost frame or crash.
6. **Routing is incomplete across submission forms.** Handle submissions get
   memory flags in `rga_job.c:147-210,260-265`; high DMA-BUF handles prefer
   compatible RGA3 cores in `rga_policy.c:537-548`. Non-handle submissions are
   scheduled first (`rga_job.c:598`) and mapped afterwards
   (`rga_mm.c:3939-3943,3584-3638`). High USERPTR handles are labelled
   `RGA2_BUFFER_DIRECT` at `rga_mm.c:1682-1684` even though their RGA2 path can
   require bouncing. Neither route gets the same high-memory preference.

Thus low backing pages avoid bouncing; high backing pages expose premature
RGA2 attachment, an oversized exporter segment, and/or bounce pressure. Installed
DRAM size changes the likelihood of that path, not the validity of the request.
`rga_mm_check_range_sgt()` (`:730-743`) examines **`sg_phys()`**, not
`sg_dma_address()`. A low post-bounce DMA address is not evidence of low backing
memory. Never build an RGA2 PTE from an RGA3 IOVA: addresses belong to their
mapping device/domain.

The established OPi fatal reset on reachable memory remains **separate**. This
design does not claim to resolve reset/AXI-drain behavior. Historical notes also
contain later reset experiments and reversals; none licenses attributing a reset
to these mapping diagnostics merely because it occurred in the same campaign.

## Ranked fixes: correctness, scope and cost

### 1. Recommended: early classification + capability-aware routing + bounded RGA2 fallback

**Files:** `rga_mm.c:797-920,1641-1689,2318-2444,2788-2866,3907-4007`;
`rga_job.c:147-210,260-265,539-604`; `rga_policy.c:318-508,511-581`.

- For DMA-BUFs, acquire lifetime/size and classify through a valid RGA3
  attachment **before** any RGA2 exporter mapping. Do not call exporter-private
  operations or inspect `dma_buf->priv`. The returned backing SG information
  is available only while the attachment remains valid. Do not mutate its SG
  table or re-map a table already mapped by the exporter.
- Keep **mapping owner** separate from **execution core**. Set IOVA metadata
  from the actual attachment device, not from the original requested scheduler
  (`rga_mm.c:880` is especially important when changing the fallback order).
  Existing per-job RGA3 remapping at `:2788-2866` must continue to map for the
  selected core rather than share an IOVA across unrelated domains.
- For USERPTR, pin and validate pages once, retain the pin, classify all spans,
  then select a core. Apply the same preparation to legacy non-handle fd/USERPTR
  jobs before policy. Validate handles and propagate lookup errors instead of
  ignoring `rga_job_judgment_support_core()`'s result at `rga_job.c:262`.
- Intersect operation, format, stride, geometry, CSC, rotation, user core mask
  and addressability for **every task/channel**. Prefer RGA3 for high-memory
  jobs it can actually execute; preserve RGA2 for reachable jobs and RGA2-only
  operations. RGA3 cannot substitute for RGA2 full CSC or every rotation: e.g.
  YUV422 90/270 exclusion at `rga_policy.c:297-315` remains valid.
- **RGA3 busy:** enqueue on a compatible RGA3 core using the existing
  least-queued selection (`rga_policy.c:550-573`), with the existing bounded
  job timeout. Busy is not unsupported. Do not send high memory to RGA2 just
  because RGA3 has a running job. A future queue-versus-copy cost policy needs
  measurements; it is not a prerequisite correctness fix.
- **RGA2 explicitly requested or the only capable core:** use the existing
  per-job DMA32 stage for high DMA-BUFs, without first mapping their large
  exporter SG entries on RGA2. Preserve same-buffer aliases, sequential tasks,
  offsets, untouched destination bytes, reservation/fence ordering and CPU
  begin/end access. Extend the job-shared fallback to high USERPTR pages if
  the RGA2 path must avoid dependence on finite swiotlb bounce capacity;
  pin ownership and overlapping virtual ranges need explicit alias handling.
  Raw physical-address imports without an authorized CPU-access/lifetime
  contract are not eligible for speculative copying.
- A missing/unusable RGA3 mapping device must fail with the original mapping
  error or enter an explicitly supported exporter CPU-access staging path;
  never recreate the doomed RGA2 probe as a diagnostic fallback.

**Correctness:** a job is mapped only onto a device that can address it, or onto
owned reachable storage with an explicit copy/ownership contract. High RAM is
used directly by RGA3, not discarded as unusable system memory. User core masks
are honored, no CSC approximation or hidden split across cores is introduced,
and every terminal path unmaps/unpins/uncharges exactly once before completion
is reported.

**Cost:** medium/high implementation effort across import, policy and lifetime
tests; no UAPI/library change. RGA3 costs IOVA/PTE setup rather than CPU image
copies. Routing changes per-core load and latency under contention; it promises
the same operation semantics, not identical timings or universal bit-exact
cross-core filtering. Qualify pixel output against the existing oracle.
Staging costs low-memory capacity and CPU memory traffic. Current limits are
64 MiB/job, 128 MiB/session, 256 MiB/global (`rga_mm.c:34-36`), not board-size
tests. A new policy must preserve bounded admission, not simply raise them.

### 2. Required companion: truthful segment limits, retain correct masks

**Files:** `rga_drv.c:1624-1634,1735-1760`;
`rga_mm.c:523-548,1024-1037,2191-2202,2390-2401`;
`include/rga_dma_policy.h:28-34`.

After the DMA backend is configured, derive the RGA2 mapping ceiling from
`dma_max_mapping_size(dev)` and the hardware/SG representation limits; retain
the page-offset-preserving `dma_set_min_align_mask(PAGE_SIZE - 1)`. Validate
the return from setting the maximum segment. Owned SG builders must obey both
the backend mapping ceiling and advertised segment limit, with page-safe
rounding and explicit handling of an unusably small limit. Retain the larger
IOMMU-appropriate RGA3 constraint where supported. Do not hardcode 256 KiB as a
universal kernel constant.

**Correctness:** this makes the device contract truthful and bounds SG tables
the island itself constructs. **It is not sufficient alone.** A streaming mask
constrains the returned DMA address; it does not make an existing DMA-BUF's
physical pages low. `dma_set_max_seg_size()` does not split an exporter-owned
SG entry by magic. Exporters may reject incompatible attachment or must construct
a compliant mapped table themselves. The island cannot repair the table after
`dma_buf_map_attachment()` has already failed.

**Cost:** small code change plus boundary tests; more SG entries/map overhead
on constrained paths. Even a fully compliant exporter can consume finite
swiotlb resources and add copy cost. This repairs a contract, not the policy.

### 3. Useful narrow first step, insufficient final fix: probe-order inversion

**Files:** `rga_mm.c:842-884` and its DMA mapping-owner assignments.

Map/classify with the existing IOMMU default first on address-limited RGA2
jobs. Retain that valid attachment for high-memory staging; only attempt an
RGA2 attachment for reachable memory. This removes the reproducible failed
probe rather than suppressing its logs. It is preferable to catching every
`-EIO` and calling it a memory error: exporters can fail for other reasons.

**Cost:** small/medium and localized, but possibly an extra map for low-memory
jobs. It fixes the diagnostic trigger, not non-handle routing, high USERPTR
pressure, all alias/coherency cases, H7, or frame conservation. Historical D3
experiments are not a substitute for regression tests against this source.

Reachability alone is not the full attachment precondition: even low-memory
exporter entries must satisfy the advertised SG contract. If a low contiguous
exporter table is larger than the declared segment limit, do not create a new
invalid attachment. Retain the valid default attachment and use the existing
reachable-memory path only with its cache/address contract proved, or construct
an independently owned, compliant mapping through a supported page-access
contract. Neither mutating the exporter SG nor silently dropping the limit is
acceptable. Run DMA-API debug on low-memory large-entry controls as well.

### 4. Allocation policy: optional RGA2 optimization, not the driver fix

The importer does not choose where an already allocated DMA-BUF lives. The
pipeline has multiple allocators. In the GStreamer fork,
[`gstrgautil.c:119-141`](https://github.com/CERALIVE/gstreamer-rockchip/blob/main/gst/rockchiprga/gstrgautil.c#L119-L141)
chooses system-uncached then system dma-heaps; `gstrgaconvert.c:452-490,755-877`
owns/proposes output and staging pools. The MPP allocator separately requests
`MPP_BUFFER_TYPE_DRM | MPP_BUFFER_FLAGS_DMA32` in
`gst/rockchipmpp/gstmppallocator.c:298-299`, while imported capture buffers retain
their upstream allocator. Engine graph selection is not physical page placement.
These are inspected source behaviors, not a fresh measurement of deployed packages.

A verified DMA32 heap could be selected by an allocator for a known RGA2-only
pool. It must guarantee the entire relevant span is below the aperture; CMA
alone does not guarantee low addresses. The driver can allocate its **own**
low staging pages (`rga_mm.c:2175-2181`), but cannot retroactively move other
drivers' allocations by setting its mask or asking userspace to use a heap.

**Cost:** lower copy cost for known RGA2 workloads, but low-RAM pressure,
fragmentation/reservation cost, exporter/platform plumbing and cross-repo
changes. Globally choosing DMA32 strands usable high RAM and is inferior to
RGA3 routing. No librga R1 change is authorized or needed for this design.

### 5. Honest refusal: mandatory terminal behavior, not the primary solution

**Files:** `rga_policy.c:490-505`; `rga_mm.c:2052-2085,2147-2150,2411-2416,2430-2436`;
completion/fence propagation in `rga_job.c`.

Preserve typed kernel errno through ioctl/fence completion: unsupported
operation/core combination `-EOPNOTSUPP`; invalid layout `-EINVAL`; span overflow
`-EOVERFLOW`; staging size `-E2BIG`; budget `-EDQUOT`; allocation `-ENOMEM`;
actual mapping/I/O error as returned. Do not collapse a transient allocation
failure into `-EOPNOTSUPP` as the USERPTR bounce path currently does at `:2416`.
Report phase, requested/eligible core masks, buffer kind, span, backing-high
classification, segment length/limit and stage-budget outcome, without kernel
addresses or user identifiers. Only report a job failure if the job failed;
successful routing/staging is telemetry, not an error.

Do not modify the global swiotlb message or hide it: prevent the invalid map.
No public librga API, `IM_STATUS`, message text, structure layout, SONAME or
visibility change. Kernel diagnostics are the appropriate surface here.

**Cost:** small implementation change with error-injection/terminal-state tests.
Refusal is valid for actual resource exhaustion or impossible requests, not
for otherwise valid high-memory work RGA3 can perform.

## Implementation and acceptance sequence

1. Preserve the controlled hardware RED and run the host reproducer below on
   the pre-fix source. Record exact source/build identities. No implementation
   precedes that RED.
2. Add production-path tests around import preparation, selected-device mapping,
   masks/SG constraints and error ownership. Land the probe-order correction
   and truthful segment declaration as reviewable changes, then finish the
   shared preparation/routing policy for handles, legacy fd and USERPTR.
3. Exercise low-only, mixed and high-only physical page fixtures, including the
   last page below 4 GiB, first page above it, a crossing span and overflow.
   Fix the exclusive-end boundary at `rga_mm.c:738`: a span ending exactly at
   4 GiB is reachable. Use checked/subtraction-based range arithmetic. Test
   1 MiB exporter entries, segment-boundary offsets, and mapping failure on
   each device. Never infer physical layout from DMA addresses.
4. Add actual mapping/staging lifetime tests: two RGA3 domains, no cross-domain
   IOVA reuse; aliases across channels and sequential tasks; partial destination
   updates; CPU begin/end failures; copy-back failure; cancellation/timeout;
   quota failure and accounting returning to baseline. High USERPTR must not
   silently use independent bounce snapshots for overlapping writable ranges.
   Test single-core policy too (`rga_job.c:555-558` currently bypasses assignment).
5. Run the island's full gate: KUnit and direct ioctl suites, sparse/coccinelle,
   arm64 modules against the pinned final kernel, source provenance updates,
   generated-series regeneration and **independent** byte-parity verification.
   An extracted host test does not qualify DMA, fences, silicon or concurrency.
6. At a separately authorized idle-board window, run controlled low/high-memory
   cases on both boards: AUTO, explicit RGA3 core 0/1, explicit RGA2, RGA2-only
   CSC/rotation, handles/non-handles, DMA-BUF/USERPTR, 1/4/6/8 concurrent jobs.
   Require positive proof that high pages were exercised on each configuration;
   inability to obtain high pages is NOT-EXERCISED, not a passing negative.
   For AUTO high-memory RGA3-capable work require actual RGA3 execution and no
   RGA2 staging/probe; for forced RGA2 require correct pixels, bounded staging
   and no oversized mapping. Preserve deadline/error and fence evidence.
7. Publish only after review/approval: **island merge and tag → kernel-patches
   `island/` lane merge naming immutable tag/commit/asset digest → image
   `patches_commit` merge → image build → separately authorized board validation**.
   No pin to an uncut release. A fix in this repository alone reaches no device.

This investigation performs none of the board operations in step 6/7. No module
reload, serial write, flash, OTA or RAUC-slot operation is part of the reproducer.

## H7: same root cause?

**Not established. Do not merge H7 into the ceiling defect yet; do not claim
it is a different cause either.** The strongest supported statement is a shared
DMA-BUF mapping-failure signature, with high-memory RGA2 mapping a leading,
testable candidate. This is an evidence gap with a discriminating test, not
“cannot be measured.”

Item 43's actual Rock outcome is **status failure, not a five-second stall**:

| Library | N=8 time to `IM_STATUS_FAILURE` | Controls |
|---|---:|---|
| Radxa | 4.605350 s | N=4/6 dwell; one-worker recovery |
| R0 | 0.400651 s | N=1, N=4/6 dwell; one-worker recovery |
| Untouched 57a1067 | 0.500773 s | N=1, N=4/6 dwell; one-worker recovery |
| Post-fix | 0.901518 s | N=1, N=4/6 dwell; one-worker recovery |

Each incident journal records `Failed to map attachment, ret[-5]`. The base
incident includes that diagnostic at 03:29:52–03:29:54 on 2026-09-14. All four
OPi library legs completed 60-second N=4/6/8 dwell with successful worker
statuses: NO-STALL at eight. The absence search used the retained Rock journal
as a positive control, and OPi journals contained other captured messages.

The H7 fixture (`CERALIVE/librga`, `tests/board/h7-board.c:20-35,60-71`)
allocates a system-heap fd source and destination per worker and synchronously
calls `improcess`: 3840×2160 NV16 → NV12, no explicit core selection in that
call. It uses `wrapbuffer_fd`, not preimported buffer handles. Eight workers
hold 232,243,200 bytes (about 221.5 MiB) of image storage before extra driver
allocations. This makes the missing non-handle memory-aware routing relevant,
but buffer volume is not proof of physical placement or the selected core.

The retained H7 evidence does **not** pair an individual failed attachment
with its core, SG physical span and length, mapping limit, stage-budget state
or a controlled low/high allocation intervention. `-EIO` alone is not a unique
swiotlb/4 GiB diagnosis. Concurrent IOVA/resource pressure or another mapping
defect remains possible. A successful one-worker recovery establishes bounded
recovery for that observation; it does not identify the mechanism.

**Decisive follow-up:** on the same kernel/library/fixture, capture a per-job
token linking buffer backing class, selected core, SG maximum entry, exact
mapping failure phase and errno. Run N=8 with verified high-memory buffers
under AUTO and RGA3-only, then a verified DMA32 control under AUTO and RGA2.
Keep allocation sizes, pixel operation and dwell unchanged, with N=1 recovery
and existing lock/stop rules. If the failing high-memory RGA2 attachment is
observed, disappears with RGA3 routing or low-memory substitution, and the
unchanged H7 test passes after the kernel fix, collapse the findings with that
evidence. If failure persists on RGA3-only or proven reachable RGA2 memory,
retain a separate defect and follow its actual error. A later kernel swap
without an otherwise matched comparison does not establish causality.

No R1 librga fix is authorized by H7 or by this design.

## Measurability recovered by the fix

The Rock measurements exist, but the mapping-affected rates are not clean
hardware-capability results. Remove the defect, **then remeasure**, rather
than carrying historical failing rates forward as new passes.

| Rock cells requiring clean rerun | Current blocker | What a successful repair recovers |
|---|---|---|
| `rga-copy-c2`, `rga-to-rgb-c2`, `rga-from-rgb-c2`, `rga-crop-c2`, `rga-scale-c2`, `rga-rotate-c2`, `rga-combined-c2` | Seven forced-RGA2 JOURNAL-ERROR rows | Clean end-to-end RGA2 rates with measured staging/copy cost; not automatically hardware-only rates |
| H.264 and H.265 4×1080p60; H.264 8×720p60 | Three AUTO JOURNAL-ERROR rows | Clean throughput/jitter/CPU/per-core routing observations under contention |
| `h265-eight720p60` | Separate FAIL, also mapping-affected: branches 0 and 1 accept 1,021 and emit 1,020; remaining branches emit 1,021 | Eligibility for a conservation-checked rate comparison **only after every branch conserves frames** |

That is **ten JOURNAL-ERROR classifications plus one separate conservation
FAIL**, not ten printed log lines. The mapping defect affects eleven cells;
it is not yet proven to cause the two missing AUs. Do not turn off the frame
oracle or explain the loss away as a DMA32 artifact.

The OPi campaign did not reproduce mapping failures or the conservation
failure: all seven forced-RGA2 cells performed work, and all eight H.265
branches conserved 1,021/1,021. Its positive-control journal scan is recorded
in the benchmark report. Unlike the earlier controlled 4 GiB experiment, the
later benchmark comparison used different plugin builds (Rock `.2`, OPi `.4`),
so it is **not** a one-variable causal experiment. Reruns must match the
complete software stack and report backing layout, staging bytes, queue wait,
hardware time, end-to-end latency and output correctness separately.

The repair does not manufacture a historical pre-island baseline. Missing or
methodologically different Phase-0 denominators still require matched new
measurements; reset faults and duplicate debugfs-name coverage remain separate.

## Pre-fix reproducer and measured result

Run from the island checkout, without a board, network or kernel build:

```sh
python3 docs/repro/rga-import-order.py
```

`docs/repro/rga-import-order.py` extracts four complete maintained functions
from `rga_mm.c`, byte-preserving their bodies, and compiles them with
`docs/repro/rga-import-order.c.in`. Only the exporter/DMA boundary and required
kernel data types/helpers are fixtures. The boundary models the independently
established 1 MiB/high-page mapping rejection and a successful IOMMU mapping;
it is not an implementation of Linux DMA or swiotlb. Both input layouts use
the same deliberately low post-map DMA address, so a mistaken inference from
DMA address cannot masquerade as low physical placement.

The positive boundary control rejects a high 1 MiB direct-device segment and
accepts a high page-sized segment. Production-path controls require low-memory
RGA2 and high-memory RGA3 imports to succeed with **zero** failed mappings.
The defect assertion then requires the same of high-memory RGA2 import. A
successful eventual return is insufficient: attempting a predictably failing
attachment is itself the reproduced defect.

Measured on the unchanged source, 2026-09-14:

```text
source_sha256=70c91d2c98ee380c59f3d74b6108c1d7237e02cdc8dca2fd615b269b34c02ac3
LOW_RGA2_CONTROL ret=0 failed_maps=0 rga2_maps=1 iommu_maps=0 under4g=1
HIGH_RGA3_CONTROL ret=0 failed_maps=0 rga2_maps=0 iommu_maps=1 under4g=0
HIGH_RGA2 ret=0 failed_maps=1 rga2_maps=1 iommu_maps=1 under4g=0
RED: high-memory import attempted a doomed RGA2 map
```

**Exit 1, reproduced before any driver fix.** Exit 2 is an invalid source
extraction/build/control/environment, never a defect RED. Exit 0 means this
finite import-order test found no failure. There is no expected-failure
inversion and no suppression of an existing CI test. The reproducer remains
explicitly invoked under docs rather than being added as a knowingly failing
normal CI gate. Promote it with the fix and add the wider kernel tests above.

The host compiler was GCC 16.2.1; compilation uses `-Wall -Wextra -Werror`
with `-Wno-sign-compare` for the inherited kernel function's existing
unsigned-long-size/int-size comparison, not a change to its types or body.
Temporary compilation output stays under repository-local `test-results/` and
is removed by the runner. No root-filesystem build cache is populated.

**Proof boundary:** this freshly executed RED is a production-function host
reproducer of the mapping-order defect under a controlled boundary, not a new
hardware RED or proof that H7 fails for this reason. The earlier controlled
Rock/OPi experiment remains the physical evidence. Board reruns, pixel/cache
coherence, asynchronous ordering, full module build/static-analysis gates and
the eventual repaired-board GREEN are still owed by implementation. The
design makes those concrete acceptance tasks rather than unmeasurable rows.

## Reference ledger

Public primary references (retrieved by the upstream-reference investigation):

- [Linux DMA API how-to](https://docs.kernel.org/core-api/dma-api-howto.html):
  coherent versus streaming masks, mapping ownership and synchronization.
- [Linux DMA API](https://docs.kernel.org/core-api/dma-api.html):
  `dma_max_mapping_size()` and SG mapping contracts.
- [Linux swiotlb](https://docs.kernel.org/core-api/swiotlb.html): single-segment
  limits, alignment overhead, map/unmap/sync copy semantics. The runtime-returned
  maximum is authoritative; a nominal 256 KiB is not safe for every alignment.
- [Linux DMA-BUF](https://docs.kernel.org/driver-api/dma-buf.html): exporter
  attachment/map ownership, reservation locks and CPU access bracketing.
- [Mainline RGA buffer handling](https://github.com/torvalds/linux/blob/587858367581b9c55c3690f4e63382ad622719d4/drivers/media/platform/rockchip/rga/rga-buf.c),
  [hardware declaration](https://github.com/torvalds/linux/blob/587858367581b9c55c3690f4e63382ad622719d4/drivers/media/platform/rockchip/rga/rga-hw.c)
  and [probe](https://github.com/torvalds/linux/blob/587858367581b9c55c3690f4e63382ad622719d4/drivers/media/platform/rockchip/rga/rga.c):
  corroborating internal-MMU versus IOMMU distinction, not a drop-in driver
  replacement or authority for copying mainline core/domain policy into the island.
- [Rockchip donor provenance](REFERENCES.md) and
  [maintained island ownership](OWNERSHIP.md): vendor lineage and the actual
  three-core ownership used by this design.

Historical evidence identifiers, with private custody paths kept only in the
matching investigation notepad:

- 2026-09-11 controlled 4 GiB experiment, buffer-flag/staging/swiotlb table.
- Item 43 `ROCK-GAPS-REPORT.md:87-114`, H7 run
  `h7-20260914T032730Z-2926571`; OPi run `20260914T130553Z-3452424`.
- Item 34 `docs/media-island/assessment/benchmarks.md:107-124,168-217,250-259,432-458`
  in the root evidence report: B34-2 mapping and B34-5 conservation.

These names are evidence identifiers, not runtime dependencies on another
checkout. No test in this repository reads an external evidence directory.
