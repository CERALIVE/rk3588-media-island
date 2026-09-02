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
| `self-tests` | every board harness and every CI tool passes its own scored fixtures. **A separate job on purpose** — see §3 |
| `series-integrity` | `patches/` regenerates byte-identically from `drivers/` + `integration/`, and an independent checker that does not import the generator agrees |
| `shim-lint` | no compat header gives a `REAL-DEPENDENCY` symbol a body; no unclassified `<soc/rockchip/*.h>` include or `rockchip_*` census symbol exists |
| `dt-ownership-lint` | every island-owned node in `docs/OWNERSHIP.md` is left with exactly one `compatible` string |
| `uapi-parity` | the MPP ioctl values, the ioctl magic and the `mpp_request` layout match both pinned sources |
| `board-probes` | the three C probes cross-build for aarch64 with `-Werror`, and their host build passes its own self-tests |
| `action-pins` | every `uses:` is at the current latest major. **Non-blocking** — see §4 |
| `pin` | nothing — it *reads* the coordinates out of `kernel-pin.env` and emits them |
| `pin-equality` | the four mirrored `KERNEL_*` values equal the consumer repository's |
| `cross-compile-modules` | the pinned tag resolves to both pinned objects; the tree configures the way the device is configured; the modules-only build links; no island `compatible` collides with a mainline `of_match_table` |
| `kunit` | `tests/kunit/` passes |
| `static-analysis` | sparse, smatch and coccinelle over the island directories |

### The kernel job, in the order it does things

`cross-compile-modules` is the only expensive job, and each step exists for a
reason worth stating:

1. **Both pinned objects are verified**, not just the commit. A peeled commit
   alone cannot detect a tag object that was re-created — re-signed, re-dated,
   re-worded — while still pointing at the same commit, and the tag object is
   what a signature verifies against.
2. **The config is `defconfig` + the device's own Kconfig fragment**, fetched at
   the immutable `image-building-pipeline` commit pinned in
   [`REFERENCES.md`](REFERENCES.md). Building against a bare `defconfig` would
   prove the island against a configuration nobody boots. The island's own
   Kconfig symbols are the third input the README names; they arrive with the
   driver import, and until then the job performs a two-way merge and says so.
3. **The tree is cached on the immutable commit and restored to pristine before
   the cache is written.** The staged island source and the applied
   `integration/` patches would otherwise poison the next run's reset — and a
   poisoned cache fails *green*.
4. **The modules build is the LINK half of the shim gate.** `shim-lint` catches a
   `REAL-DEPENDENCY` given a stub body; only modpost catches a declaration with
   no provider behind it. Neither alone is sufficient, which is why both exist.

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

## 2. What is vacuous today, and exactly when it stops being

The driver import has not landed. Four gates therefore have nothing to inspect,
and every one of them **says so in words and exits 0** rather than reporting a
clean run it did not perform.

| Gate | Marker it prints | Becomes required when |
|---|---|---|
| `series-integrity` | `NO-SOURCE-YET` — the island roots hold no kernel source and `integration/` holds no patch, so the series is empty by construction | the driver import lands source or an integration patch |
| `shim-lint` | `NO-SOURCE-YET` — 21 `REAL-DEPENDENCY` symbols are read from `docs/COMPAT.md`, but steps 2–4 have no file to scan | the driver import lands source |
| `dt-ownership-lint` | `NO-DT-YET` — 11 island-owned node labels are read, but `integration/` carries no device-tree patch | the DT integration lands |
| `uapi-parity` | `NO-HEADER-YET` — a **skipped** test class, not a passing one | `include/uapi/linux/rk-mpp.h` exists |
| `cross-compile-modules` | `NO-MODULES-YET` — the module directories carry no kernel `Makefile`, so the `.ko` assertion is skipped | a module directory gains a `Makefile` |
| `kunit` | `0 tests. NO-KUNIT-CASES-YET` — no suite exists, so no UML kernel is built | the first KUnit case lands |
| `static-analysis` | `NOTHING-TO-ANALYZE: 0 island .c file(s)` — the three analysers have no translation unit | the driver import lands source |

Two of these are **not** vacuous today and are worth calling out:

- `cross-compile-modules` still clones the pinned kernel, verifies both objects,
  fetches the device fragment, configures, and runs `modules_prepare` — every
  expensive step **except** the module build itself. The toolchain, the cache and
  the config path are therefore exercised now, so the import does not discover a
  broken kernel job on the day it needs one.
- `uapi-parity` runs six real assertions today against the pinned vendor/libmpp
  fixture, including an **independent** re-derivation of `_IOW('v', 1, unsigned
  int)` in Python. Only the island-header comparison is skipped.

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

**The richer form of this mutation — a source file drifting from the patch that
carries it — cannot be shown in this repository yet**, because there is no source
to drift. It is proven instead against a synthetic island in a scratch tree, in
§6, and it becomes reproducible here the moment the import lands. That gap is
stated rather than papered over.

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

## 9. Timings

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

The plan's budget is 25 minutes cold and 8 warm; both are met with room to
spare. **That is not the steady-state number and must not be quoted as one** —
`cross-compile-modules` is fast today precisely because the module build itself
is skipped (`NO-MODULES-YET`) while every step around it runs in full. Expect it
to grow substantially when the import lands real source, and re-measure then
rather than carrying this table forward as if it still applied.

The `ccache` cache reported a miss on both runs, which is correct and not a
defect: its key includes `github.sha`, and nothing has been compiled for it to
hold while the module build is skipped.

---

## 10. Known gaps these gates leave for the driver import

Recorded so the import is not surprised by them:

1. **The link half of the shim gate is unexercised.** `shim-lint`'s static half
   names a `REAL-DEPENDENCY` with no provider, but the authoritative check is an
   undefined symbol at modpost, and there is nothing to link yet.
2. **The census is deliberately strict.** Step 4 refuses *any* `rockchip_*` name
   with no `docs/COMPAT.md` row — including one the island itself defines. That is
   the specification's "fails closed until its semantics are classified", and it
   means the import adds table rows in the same change as the source. It is not a
   bug to work around.
3. **`integration/` patches are applied with `git apply` in `--verbose` mode and
   nothing re-anchors them.** The island has no `rebase/<tag>.rules` equivalent;
   a hunk that stops applying at a new base is a red build and a source edit.
4. **The island Kconfig fragment does not exist**, so `cross-compile-modules`
   merges `defconfig` + the device fragment only. The import adds the third input
   and this document's §1 item 2 stops being a two-way merge.
5. **`kunit` builds nothing today.** Its first real run will need a
   `tests/kunit/.kunitconfig`; the job passes `--kunitconfig=tests/kunit` already.
6. **`release.yml` has never been dispatched**, in either mode. `ci.yml` has now
   run green end to end on GitHub's runners across a cold and a warm cache (§9),
   which validates that YAML as well as the gates; the release workflow is
   written and reviewed but unexecuted, and §7 says so. `ccache` has also never
   held anything, because there is nothing to compile yet.
