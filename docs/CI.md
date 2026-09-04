# CI — what each gate asserts, and what it does not yet

Three workflows, following the CeraLive CI/CD canon: a `concurrency` block on
every one (`cancel-in-progress: true` for the PR gate, `false` for release and
the watch); `push` constrained to `branches:` because a `pull_request` trigger
exists; top-level `permissions: contents: read` with per-job escalation only
where a job genuinely writes; every `uses:` pinned to the current latest major;
the kernel clone and `ccache` cached; nothing published before the gates run.

**No workflow restates a pinned coordinate.** The kernel tag is read out of
[`../kernel-pin.env`](../kernel-pin.env) by the `pin` job and passed on as job
outputs. A literal tag anywhere under `.github/` would be a regression, because
a pin bump would then leave CI proving the series against a kernel nobody ships
— green, which is the worst kind of failure.

---

## 1. `ci.yml` — the pull-request gate

| Job | Asserts |
|---|---|
| `shellcheck` | every tracked shell script lints clean at `-S style`, excluding only `SC1091` (a runtime-resolved `source` cannot be followed) |
| `self-tests` | every board/DT harness and every CI tool, including MPP hardening, module metadata, trace schemas, counter roots, the dual-core MPP parser, and the RGA lifecycle parser, passes scored fixtures. **A separate job on purpose** — see §3 |
| `series-integrity` | `patches/` regenerates byte-identically from `drivers/` + `integration/`, and an independent checker that does not import the generator agrees |
| `shim-lint` | no compat header gives a `REAL-DEPENDENCY` symbol a body; no unclassified `<soc/rockchip/*.h>` include or `rockchip_*` census symbol exists |
| `dt-ownership-lint` | every island-owned node in `docs/OWNERSHIP.md` is left with exactly one `compatible` string |
| `uapi-parity` | the MPP ioctl values, the ioctl magic and the `mpp_request` layout match both pinned sources |
| `board-probes` | the three C probes cross-build for aarch64 with `-Werror`, and their host build passes its own self-tests |
| `action-pins` | every `uses:` is at the current latest major. **Non-blocking** — see §4 |
| `pin` | nothing — it *reads* the coordinates out of `kernel-pin.env` and emits them |
| `pin-equality` | the four mirrored `KERNEL_*` values equal the consumer repository's |
| `cross-compile-modules` | the pinned tag resolves to both pinned objects; the tree configures the way the device is configured; `vmlinux` supplies provider symbols, `modules_prepare` supplies the final-link script, and configured `vmlinux.symvers` is exposed under the `Module.symvers` filename external modpost reads; exactly `rk_vcodec.ko` and `rga3.ko` link with `-Werror` and publish the OF aliases needed for module autoload; both board DTBs build and pass the ownership/skip-PMU checker; no island `compatible` collides with a mainline `of_match_table` |
| `kunit` | every suite in `tests/kunit/` passes against the pinned kernel; CI also asserts the telemetry symbol resolved `=y` and the telemetry session-format case appeared in the run |
| `static-analysis` | sparse inspects every selected composite object with findings promoted to errors, followed by coccinelle over both island directories; the plan's conditional smatch arm is not enabled without a suitable runner package |

### The kernel job, in the order it does things

`cross-compile-modules` is the only expensive job, and each step exists for a
reason worth stating:

1. **Both pinned objects are verified**, not just the commit. A peeled commit
   alone cannot detect a tag object that was re-created — re-signed, re-dated,
   re-worded — while still pointing at the same commit, and the tag object is
   what a signature verifies against.
2. **The config is `defconfig` + the device's own Kconfig fragment + the island
   fragment**, with the device fragment fetched at
   the immutable `image-building-pipeline` commit pinned in
   [`REFERENCES.md`](REFERENCES.md). Building against a bare `defconfig` would
   prove the island against a configuration nobody boots. CI also asserts the
   resulting module values and exact selectable-client set.
3. **The tree is cached on the immutable commit and restored to pristine before
   the cache is written.** The staged island source and the applied
   `integration/` patches would otherwise poison the next run's reset — and a
   poisoned cache fails *green*.
4. **A configured `vmlinux` and `modules_prepare` run before the modules.** The
   first writes `vmlinux.symvers` but not the external-modpost filename; the
   second writes `scripts/module.lds` but deliberately no symbol table. CI needs
   both, then checks the symbol dump is non-empty and copies it to
   `Module.symvers`. The two module builds run without `KBUILD_MODPOST_WARN`:
    `shim-lint` catches a REAL-DEPENDENCY given a stub body, and strict modpost
     catches a declaration with no provider behind it.
5. **The linked modules must publish their OF aliases.** Source checks require a
   `MODULE_DEVICE_TABLE` for every MPP and RGA match table, reject the RKVENC2
   hard-IRQ-only request if it regains `IRQF_ONESHOT`, and `modinfo` verifies the
   actual `.ko` metadata. A successful link without aliases cannot autoload from
   device-tree modaliases and therefore fails this job.
6. **Both supported board DTBs are built from the applied lane.**
   `tests/dt/check-dtb-ownership.sh` reads the compiled blobs with `fdtget`,
   proves every MPP node's sole compatible and every client node's
   `rockchip,skip-pmu-idle-request`, and proves the pending RGA compatibles did
   not leak into the live tree.

### The one split gate

`dt-ownership-lint` has two arms and they run in two places, deliberately:

- **the one-compatible rule** runs in its own job with no kernel tree, so it
  answers in seconds and fails fast;
- **"and no mainline `of_match_table` lists that string"** needs the pinned tree,
  so it runs inside `cross-compile-modules` where the tree already is.

The script prints an explicit `NOTE: ... SKIPPED, not passed` in the fast job
rather than implying it checked. Running a 2 GB clone twice to avoid one honest
note would be the worse trade.

---

## 2. Ownership-era gate state

The driver import has landed. Every gate whose input is part of todo 8 is now
non-vacuous:

| Gate | Live assertion |
|---|---|
| `series-integrity` | seven generated mailboxes reconstruct all 76 island source files and carry all six applied integration payloads byte-identically; `integration/pending/` remains excluded |
| `shim-lint` | all classified compatibility headers and source call sites are scanned; a REAL-DEPENDENCY body remains forbidden |
| `uapi-parity` | the imported kernel header is compared with both pinned userspace/vendor references, including every command value and layout assertion |
| `cross-compile-modules` | strict modpost links exactly `rk_vcodec.ko` and `rga3.ko` against the configured Linux 7.2 provider symbol table, verifies their OF aliases with `modinfo`, then builds and inspects both supported board DTBs |
| `static-analysis` | sparse checks all selected MPP/RGA objects with `-Wsparse-error`; coccinelle scans both directories |
| `dt-ownership-lint` | three applied MPP DT patches and two pending RGA DT patches each leave sole island compatibles; the pinned-tree arm rejects any mainline driver collision |

The telemetry source contract additionally mutation-tests event loss, real
call-site loss, lifecycle ordering, the fdinfo-style session file, and a missing
production debugfs symbol. KUnit calls the driver's own load-row and session-row
formatters and freezes their whitespace, field order, and fractional rendering.
Both module builds compile the tracepoint definition units with `-Werror`, which
catches duplicate `CREATE_TRACE_POINTS`, malformed fields, and unavailable
debugfs APIs. Both independent series collectors reject generated `*.mod.c`
files, so an in-tree module build cannot leak metadata back into the release
mailbox.

The configured-kernel step also requires `FTRACE`, `ENABLE_DEFAULT_TRACERS`,
`TRACING`, `EVENT_TRACING`, and `TRACEPOINTS` to resolve `=y`, while
`FUNCTION_TRACER` stays off. This is the minimal closure that registers event
tracepoints and tracefs without adding function-entry instrumentation.

RGA ownership remains deliberately unshipped. Its two patches are linted under
`integration/pending/`, and the DTB checker proves the compiled live tree still
uses the mainline RGA compatibles until todo 19 promotes both together.

### Todo 10 local DTB evidence

On 2026-09-03, both board targets were built from the pinned Linux v7.2 tree
after applying all six live integration patches:

```text
DTC arch/arm64/boot/dts/rockchip/rk3588-rock-5b-plus.dtb
DTC arch/arm64/boot/dts/rockchip/rk3588-orangepi-5-plus.dtb
PASS: both RK3588 board DTBs satisfy MPP ownership; RGA remains pending
```

The same two targets were built from a separate pristine `v7.2` worktree. Both
the baseline and patched `stderr` warning logs contained **zero lines**, and
`cmp` found them byte-identical. This is the required no-new-`dtc`-warnings
comparison, not an inference from a successful build.

KUnit is now non-vacuous: todo 9's request-boundary and deterministic fault
controls run as real suites against the pinned kernel.

---

## 3. `self-tests` is a job, not a lint step — and here is the proof

Shellcheck cannot see a whole class of defect in these scripts. The harness
bootstrap hit one: inside an ERE bracket expression `\t` is a backslash and the
letter `t`, never a tab, so `[ \t]+$` also matches any line ending in `t`. That
is valid shell and valid regex, and it made an assertion unsatisfiable.

Reintroducing exactly that regression, on a throwaway branch:

```
$ sed -n 1902p tests/board/run-baseline.sh
  if grep -qE '[ \t]+$' "${wsfile}"; then

$ shellcheck -S style -e SC1091 -x tests/board/run-baseline.sh
exit=0   <-- shellcheck is GREEN on the defect

$ bash tests/board/run-baseline.sh --self-test   (tail)
trailing-whitespace sanitation preserves lines, order and indent ok
legacy (d) normalization restates only the unevidenced headline ok
bug_reality columns=9 ok
usage board-required=ok
usage host-required=ok
VERDICT: FAIL (self-test)
exit=1   <-- the self-test is RED
```

Control, the script restored:

```
$ bash tests/board/run-baseline.sh --self-test   (tail)
usage board-required=ok
usage host-required=ok
VERDICT: PASS (self-test: screen enforced, document complete, unrun legs honest)
exit=0
```

So the linter and the self-tests are two jobs because they answer two different
questions, and only one of them would have caught this.

---

## 4. `action-pins` is non-blocking, on purpose

An action publishing a new major must not turn an unrelated pull request red.
That is the same floating-runtime failure the canon bans `bun-version: latest`
for, arriving from the other direction. Dependabot opens the bump, a human
reviews it, and this job is the standing report that says one is due. It still
fails loudly when it runs, and its finding is in the log:

```
$ bash scripts/check-action-pins.sh          # with actions/checkout@v4 injected
  ok  actions/cache                                  v6 (latest v6.1.0)
  ok  actions/checkout                               v7 (latest v7.0.1)
  ok  actions/download-artifact                      v8 (latest v8.0.1)
  ok  actions/upload-artifact                        v7 (latest v7.0.1)

FAIL: 1 action pin(s) are behind the current latest major:
  actions/checkout@v4 is pinned to v4; the current latest is v7.0.1 (v7)
exit=1
```

An action it cannot resolve is reported as **unresolved**, never as a pass — a
green run against an unreachable API proves nothing.

---

## 5. Non-vacuity — every gate mutated, on a throwaway branch

A gate that has never gone red is a gate nobody has tested. Each mutation below
was applied to a real working tree on a throwaway branch, the named gate was run,
and the fixture was then removed. Every mutation is paired with a **control**,
because a check that refuses everything is as useless as one that refuses
nothing.

### M1 — `dt-ownership-lint`: an island node given two compatibles

```
$ python3 scripts/check-dt-ownership.py
FAIL: dt-ownership-lint refused this tree.
  integration/0011-dt.patch: island-owned node `vdec0` is left with 2 compatible
  string(s) (rockchip,rkv-decoder-v2, rockchip,rk3588-vdec). docs/OWNERSHIP.md:53
  requires exactly one -- with two, which driver binds is module load order,
  which is not a design.
exit=1
```

Control — the same hunk leaving one string:

```
$ python3 scripts/check-dt-ownership.py
NOTE: no pinned kernel tree at .work/linux -- the mainline of_match_table
collision check is SKIPPED, not passed. CI clones the tree, so this arm is live
there.
OK: 11 island-owned node label(s); 1 applied and 0 pending integration patch(es);
every island node carries exactly one compatible.
exit=0
```

### M2 — `shim-lint`: the `docs/COMPAT.md` negative fixture, on disk

The specification's own fixture, injected into a real compat header at
`drivers/video/rockchip/mpp/compat/soc/rockchip/rockchip_iommu.h`:

```
$ python3 scripts/check-compat-shims.py
FAIL: shim-lint refused this tree.
  drivers/video/rockchip/mpp/compat/soc/rockchip/rockchip_iommu.h:5:
  `rockchip_iommu_enable` is `static inline` in a compat header.
  docs/COMPAT.md:87 classes it REAL-DEPENDENCY, so a compat definition would let
  the build succeed against a stub instead of the real provider.
exit=1
```

Control — the body deleted, the declaration kept:

```
$ python3 scripts/check-compat-shims.py
OK: 21 REAL-DEPENDENCY symbol(s) checked across 1 compat header(s) and 1 island
source file(s); no stub, no unclassified include, no unclassified census symbol.
exit=0
```

The fixture was then removed. **This mutation found a real defect in the lint
itself**, which is the whole reason for running it: a header guard carries no
`;`, so walking a declarator back from the first declaration in a file reached
byte 0 and dragged `#ifndef`/`#define` into the prefix — making a prototype read
as a call site. Fixed in `declarator_prefix()`, and the self-test's
declared-only fixture now carries a header guard so it cannot come back.

### M2b — strict modpost: the real IOMMU provider disappears

M2 proves that the static half rejects a REAL-DEPENDENCY body. The other failure
shape is a declaration with no provider. After configuring and building the
pinned Linux 7.2 provider symbol table, the mutation removed only its
`rockchip_iommu_*` export rows — exactly the symbol-table result of omitting
`integration/0002` — and rebuilt the selected MPP module without
`KBUILD_MODPOST_WARN`:

```text
MODPOST Module.symvers
ERROR: modpost: "rockchip_iommu_mask_irq" [rk_vcodec.ko] undefined!
ERROR: modpost: "rockchip_iommu_sync_fault_handler" [rk_vcodec.ko] undefined!
ERROR: modpost: "rockchip_iommu_enable" [rk_vcodec.ko] undefined!
ERROR: modpost: "rockchip_iommu_unmask_irq" [rk_vcodec.ko] undefined!
ERROR: modpost: "rockchip_iommu_set_fault_handler" [rk_vcodec.ko] undefined!
ERROR: modpost: "rockchip_iommu_disable" [rk_vcodec.ko] undefined!
ERROR: modpost: "rockchip_iommu_prepare_irq" [rk_vcodec.ko] undefined!
ERROR: modpost: "rockchip_iommu_enable_irq_delivery" [rk_vcodec.ko] undefined!
provider-link-negative=PASS exit=2
```

Control — exposing the unmodified `vmlinux.symvers` as `Module.symvers` and
rebuilding emits `rk_vcodec.ko` with exit 0. This is why the CI job supplies the
configured built-in symbol table rather than turning unresolved modpost failures
into warnings.

### M3 — `series-integrity`: a hand-edited `patches/`

`patches/` is generated, so both a hand-added file and a hand-edited `series`
are caught, by both opinions independently.

```
$ python3 scripts/build-series.py --check
FAIL: patches/ is not what the source generates.
  0001-hand-written.patch: present in patches/ but not generated from source
  (hand-added, or its source was removed)
exit=1

$ python3 scripts/verify-series-parity.py
FAIL (independent): patches/series does not match patches/
(present but unlisted: 0001-hand-written.patch)
exit=1
```

```
$ python3 scripts/build-series.py --check     # patches/series hand-edited
FAIL: patches/ is not what the source generates.
  series: differs from what the source generates
exit=1

$ python3 scripts/verify-series-parity.py
FAIL (independent): patches/series does not match patches/
(listed but absent: 0001-invented.patch)
exit=1
```

The richer form is now live against the imported tree: editing any one of the 66
source files without regeneration makes both the producer check and independent
reconstruction check fail. The synthetic proof in §6 remains the small,
auditable mutation transcript for the same invariant.

### M4 — `shim-lint`: source growth fails closed

```
$ python3 scripts/check-compat-shims.py       # an unclassified include
FAIL: shim-lint refused this tree.
  drivers/video/rockchip/mpp/mpp_iommu.c:1: includes
  <soc/rockchip/rockchip_newthing.h>, which has no row in docs/COMPAT.md.
  Classify it (STUB-SAFE or REAL-DEPENDENCY) before the build may consume it.
exit=1

$ python3 scripts/check-compat-shims.py       # an unclassified census symbol
FAIL: shim-lint refused this tree.
  drivers/video/rockchip/mpp/mpp_iommu.c:3: `rockchip_totally_new_api` has no row
  in docs/COMPAT.md. The census is mechanically closed on purpose -- source
  growth fails closed until its semantics are classified.
exit=1
```

Control — the same file calling only classified symbols:

```
$ python3 scripts/check-compat-shims.py
OK: 21 REAL-DEPENDENCY symbol(s) checked across 0 compat header(s) and 1 island
source file(s); no stub, no unclassified include, no unclassified census symbol.
exit=0
```

### M5 — `pin-equality`: a hand-edited mirrored value

```
$ pin_equality                                # KERNEL_COMMIT edited to zeros
--- consumer
+++ kernel-pin.env
@@ -1,4 +1,4 @@
-KERNEL_COMMIT="8d3ae59288f1e7d58d76558a6ee96d533bc5019f"
+KERNEL_COMMIT="0000000000000000000000000000000000000000"
 KERNEL_MIRROR="https://github.com/gregkh/linux.git"
 KERNEL_TAG_OBJECT="237a1c39e8dfd3e1c6f1f023eea37a48ec04cc63"
 KERNEL_TAG="v7.2"
ERROR kernel-pin.env has drifted from CERALIVE/rk3588-kernel-patches.
exit=1
```

Control, unedited: `ok: the four mirrored KERNEL_* values match the consumer's`.

### M6 — `uapi-parity`: a drifted ioctl command value

```
$ python3 -m unittest discover -s tests/uapi   # MPP_CMD_SET_REG_WRITE +0 -> +7
AssertionError: 519 != 512 : MPP_CMD_SET_REG_WRITE drifted: the pinned kernel and
libmpp sources both say 0x200
Ran 7 tests in 0.001s
FAILED (failures=1, skipped=1)
exit=1
```

Control, restored: `Ran 7 tests ... OK (skipped=1)`.

### M7 — `action-pins`: a stale major

Transcript in §4.

### M8 — `self-tests`: the class shellcheck cannot see

Transcript in §3.

---

## 6. The generated series really is `git am`-able

`build-series.py` is only useful if `git am` accepts what it writes. Proven
against a synthetic island — one MPP source file, one Makefile, and one real
`integration/` hunk against a mainline file — applied to a scratch git tree:

```
$ python3 scripts/build-series.py
Wrote 2 patch(es) + series to patches/.

$ cat patches/series
0001-rk3588-media-island-drivers.patch
0002-video-rockchip-makefile-hook.patch

$ git am --keep-non-patch ../island/patches/*.patch
Applying: video: rockchip: add the CeraLive RK3588 media island
Applying: video: rockchip: hook the island Makefile

$ git ls-files
drivers/video/Makefile
drivers/video/rockchip/mpp/Makefile
drivers/video/rockchip/mpp/mpp_service.c

$ cat drivers/video/Makefile
obj-y += rockchip/
obj-$(CONFIG_ROCKCHIP_MPP_SERVICE) += rockchip/mpp/
```

Both series gates then agree about that tree, and both go red the moment a source
file is edited without regenerating:

```
$ python3 scripts/verify-series-parity.py
OK (independent): 2 patch(es) reconstruct 2 island source file(s)
byte-identically and carry 1 integration payload(s) verbatim.

# mpp_service.c edited, patches/ left alone:
$ python3 scripts/verify-series-parity.py
FAIL (independent): the series and its source disagree.
  drivers/video/rockchip/mpp/mpp_service.c: the series' copy differs from the
  file on disk
$ python3 scripts/build-series.py --check
FAIL: patches/ is not what the source generates.
  0001-rk3588-media-island-drivers.patch: differs from what the source generates
```

---

## 7. `release.yml`

`workflow_dispatch` only, with two inputs: a CalVer `version` and a `publish`
boolean that **defaults to false**.

There is no tag trigger, deliberately. The release *claims* its tag atomically at
a verified commit, so a tag that already exists is the failure this workflow
refuses — never its input. A `push: tags:` trigger would invert that.

| Stage | What it does |
|---|---|
| `release-source` | refuses any ref but `refs/heads/main`, validates the CalVer shape, resolves ONE commit and proves it reachable from `origin/main` |
| `gates` | re-runs lint, self-tests, both series opinions, both lints and UAPI parity **against that exact commit** |
| `build-series` | regenerates and byte-compares, then packs a deterministic tar (`--sort=name`, no owner, fixed mtime) plus its `.sha256`, verifies the checksum from the packed bytes, and uploads them as a workflow artifact |
| `publish` | *only when `publish: true`* — refuses an occupied release or tag, claims the tag atomically via the create-reference API, re-verifies it after fetch, creates a **draft**, downloads every asset back and byte-compares it, publishes, then re-verifies the tag once more |

**Validation mode stops after `build-series`.** With `publish: false` everything
above runs — the gates, the regeneration, the byte-compare, the checksum, the
artifact upload — and no tag is created, no release exists, and nothing reaches
the consumer. An artifact upload is not a publication, and the dry run uploads
the *same bytes* the publish path would, so validating a release cannot validate
something other than what would ship.

The tar is deterministic because the consumer's `island/` lane records the
asset's digest. Two runs of one commit producing two digests would make that
record unverifiable.

**Not exercised in this change.** No release has been dispatched in either mode.
The workflow is written and reviewed; it has not run. `ci.yml` has, which is a
different claim — see §9.

---

## 8. `upstream-watch.yml`

Weekly (Mondays 05:23 UTC, off the hour because GitHub's scheduler is contended
at `:00`) plus manual dispatch. It opens or updates **one** issue labelled
`upstream-freshness`, and closes it when every pin is current again.

**It is issue-only.** It never edits `docs/REFERENCES.md`, never opens a pull
request, and never dispatches a build — which is why its job is the only one in
this repository escalating `issues: write`, and why it holds no dispatch token.
Moving a pin means re-reading the series, re-running the shim census and
re-verifying the licence inventory; a robot that moved a SHA would be asserting
it had done all three.

It watches the two objects the later cherry-pick step actually draws from:

| Watched | Ref | Why |
|---|---|---|
| `yisding/rock-5b-ysp` | `refs/heads/main` | carries the forward-port patch record under `kernel-drivers/patches/forward-port-rk3588/` |
| `yisding/linux-rock5b` | `refs/heads/rk3588-video-6.18` | the branch tip that record exports from |

A run that cannot resolve an upstream **fails** rather than reporting "current".
A silent watch reads exactly like an up-to-date one, and GitHub disables
scheduled workflows after 60 days of repository inactivity — if this goes quiet,
check that first.

Live, at the time of writing:

```
$ python3 scripts/check-upstream-freshness.py
current: yisding/rock-5b-ysp (forward-port patch record) is still at its pinned object
current: yisding/linux-rock5b (realized maintained series) is still at its pinned object
exit=0
```

---

## 9. Historical scaffold timings

Measured on GitHub's `ubuntu-latest` runners, both runs on `main`, 2026-09-02.
Run `33685651864` populated the kernel cache (**cold**); run `33686051743` hit it
(`Cache hit for: linux-Linux-8d3ae592…`, **warm**).

| Job | Cold | Warm |
|---|---|---|
| `cross-compile-modules` | **140 s** | **91 s** |
| `self-tests` | 35 s | 20 s |
| `board-probes` | 22 s | 18 s |
| `shellcheck` | 8 s | 9 s |
| `pin-equality` | 6 s | 7 s |
| `series-integrity` | 6 s | 6 s |
| `dt-ownership-lint` / `uapi-parity` / `pin` | 5–7 s | 5 s |
| `shim-lint` / `action-pins` / `kunit` / `static-analysis` | 3–4 s | 4–6 s |

These measurements predate the source import and are retained only as the
scaffold baseline. **They are not current performance numbers and must not be
quoted as such.** The live gate now builds a configured `vmlinux` for strict
provider-symbol validation and then links both modules, so the next green run is
the first meaningful import-era timing.

The `ccache` cache reported a miss on both runs, which is correct and not a
defect: its key includes `github.sha`, and nothing has been compiled for it to
hold while the module build is skipped.

---

## 10. Remaining deferred gates

1. **RGA ownership is a later input.** The MPP ownership lane is live. The RGA3
   and RGA2 compatible flips remain under `integration/pending/` until todo 19
   promotes both in one release.
2. **KUnit is live.** Its repo-owned `.kunitconfig` runs the boundary and
    fault/lifecycle, telemetry-format, capability, DMA-policy, and RGA-fence
    suites against the pinned kernel.
3. **Smatch is conditional.** The plan requires it when a suitable runner
   package is installable. This workflow currently gates sparse and coccinelle;
   it does not claim a smatch result.
4. **Integration patches are context-sensitive.** They apply with verbose
   `git apply`; there is no fuzzy re-anchor layer. A Linux pin change that moves
   a hunk is intentionally a red build and an explicit source update.
5. **`release.yml` has never been dispatched**, in either validation or publish
   mode. Its implementation is reviewed, but no release claim is made here.
