# Contributing to rk3588-media-island

This repository carries kernel driver source that CeraLive maintains but did not
originate. Almost every rule below exists to keep two questions answerable years
from now: **where did this line come from**, and **what was it trying to fix**.

## Branches and pull requests

The canonical branch is `main`. Work happens on **one integration branch per
release**, and that branch produces **exactly one pull request**.

```bash
git fetch origin --prune
git switch main && git merge --ff-only origin/main
git switch -c release/2026.1.0
```

Open the PR explicitly, and check where it landed:

```bash
gh pr create --repo CERALIVE/rk3588-media-island --base main
gh pr view <n> --json url -q .url   # must be https://github.com/CERALIVE/rk3588-media-island/...
```

Keep only the CERALIVE `origin` remote attached. This repository is not a fork,
so nothing should ever point elsewhere at rest.

**PRs on the release branch are not squash-merged.** Squashing collapses the
per-change history that is the entire reason this is a source repository rather
than a patch file — provenance, review record, and the ability to bisect a
regression to one driver change. Use *Rebase and merge* or *Create a merge
commit*. Documentation-only and tooling-only PRs may squash freely.

## Commits

One commit per logical change. A commit that fixes two defects in one driver is
two commits, because a bisect that lands on it can only tell you that one of them
matters.

Subject lines name the **mechanism**, not the file:

```
mpp: release the task once when hw_run has already unwound it
rga3: stop reading the acquire fence after the job is torn down
```

Not `fix mpp bug`, not `update rga3`, not `address review comments`.

### Trailers

Two trailers are specific to this repository and carry real weight.

**`Origin:`** — where an imported or ported change came from. It names a pinned
object and the path inside it, so the claim is checkable:

```
Origin: rockchip-linux/kernel@b4ef083dc0c3608e744deabb43dc6b781aadbe6e drivers/video/rockchip/mpp/mpp_iommu.c
Origin: yisding/linux-rock5b@e7ff978398825b63ddcb13e0572d77564034c1e2 drivers/video/rockchip/rga3/rga_fence.c
```

Rules: always a full 40-character SHA, never a branch, never a bare repository
name. A first-party commit that invents nothing from upstream carries **no**
`Origin:` trailer at all — an empty or placeholder one is worse than none,
because it looks like provenance and is not.

**`Fixes-intent:`** — for a change that alters *behaviour* inherited from
upstream, a one-line statement of what the original code was trying to do. It is
the sentence a future reader needs before deciding whether your change is still
right:

```
Fixes-intent: the vendor path masked the fault IRQ to stop a storm; this keeps that
              intent but syncs the handler token first so the callback cannot outlive it
```

Use it whenever the diff would otherwise read as "upstream was simply wrong".
Upstream usually was not simply wrong; it was solving a problem on a different
kernel.

### Trailers that are forbidden

**Never** add `Co-authored-by:` or any AI/tool attribution — `Generated with…`,
`Co-authored-by: Claude…`, or any variant. This is a public repository and the
rule is absolute. If one slips in, strip it before the commit is pushed.

A clean cherry-pick's real upstream `Author` field is provenance, not a trailer,
and is preserved.

## What must land together

Some pairs are inseparable because the second half is a machine input for the
first. Splitting them across commits produces a red build in between:

| If you change… | You must also change… |
|---|---|
| a compat shim, or any external symbol the drivers call | its row in `docs/COMPAT.md` — `shim-lint` reads that table |
| a device-tree node's owner in `integration/` | its row in `docs/OWNERSHIP.md` — `dt-ownership-lint` reads that table |
| any file under `drivers/` or `include/uapi/` | its row in `docs/PROVENANCE.md` |
| observable behaviour | a test that would have caught the regression |
| the target kernel | **nothing here** — bump `rk3588-kernel-patches` first, then mirror |

## Generated content

`patches/` is generated from `drivers/` and `integration/`. Regenerate it; never
edit it. `series-integrity` regenerates into a temp directory and byte-compares,
so a hand edit is a red build rather than a silent divergence.

## The testing gate

Every change lands with the full gate green: the series-integrity and lint jobs,
the modules-only cross-compile with `-Werror`, KUnit, and static analysis.

- Never delete, skip or weaken a test to make a change pass. Fix the code.
- A previously-passing test that goes red blocks the PR. No `skip()`, no deferred
  TODO.
- If a test genuinely must go — the thing it covered was deleted — say why in the
  PR description.

Board drills are separate and are never a PR gate; they are hardware evidence,
scored from transcripts, recorded in `docs/BOARD-QUALIFICATION.md`.

## Comments

Few, and high-signal. Explain **why**, never what. A comment restating the line
below it is noise; a comment naming the hardware erratum that line works around is
the most valuable thing in the file.

No narration, no changelog-in-comments, no commented-out code.

## Rule D — this repository stands alone

No tracked file may reference a path above this repository's root. No sibling
`link:` or `file:` dependency, no `../` import, no assumption that a neighbouring
checkout exists. CI clones the kernel by URL from `kernel-pin.env` and nothing
else. Test artifacts go to a repository-local, gitignored directory.

## Pull request description

Use the template: **What / Why / How to verify / Risks**. Plain English, written
for a reviewer. No statistics dumps, no auto-generated changelogs, no diffstat
blocks, no AI narration.
