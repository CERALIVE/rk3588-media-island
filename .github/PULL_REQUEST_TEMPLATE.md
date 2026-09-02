<!-- No statistics dumps, no auto-generated changelogs, no diffstat blocks, no AI narration. -->

## What

<!-- What changed? One paragraph, plain English. -->

## Why

<!-- Why does this change exist? Link the issue, the defect, or the board transcript. -->

## How to verify

<!-- Concrete steps a reviewer can follow. Name the CI job, the KUnit case, or the board drill. -->

## Risks

<!-- What could break? Rollback plan if needed. "None" is fine if genuinely none. -->

---

**Checklist**

- [ ] Docs updated in the same change (AGENTS.md, README, `docs/`) — see CONTRIBUTING "What must land together"
- [ ] Compat shim or external symbol change carries its `docs/COMPAT.md` row
- [ ] Device-tree owner change carries its `docs/OWNERSHIP.md` row
- [ ] New or changed file under `drivers/` or `include/uapi/` carries its `docs/PROVENANCE.md` row
- [ ] Commits carry `Origin:` where imported, `Fixes-intent:` where inherited behaviour changed, and NO `Co-authored-by` or AI attribution
- [ ] `patches/` was regenerated, not hand-edited
- [ ] `kernel-pin.env`'s four mirrored `KERNEL_*` values are untouched
- [ ] No tracked file references a path above this repository's root
- [ ] Full gate green: series-integrity, shim-lint, dt-ownership-lint, cross-compile, KUnit, static analysis
- [ ] Any board claim is backed by a pasted transcript naming board, kernel build and island tag
