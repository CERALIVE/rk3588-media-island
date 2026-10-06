<!-- Moved verbatim from AGENTS.md on 2026-10-05 by lean-rules-docs-landing-latam -->

## PR TARGETING

**This repository is NOT a fork.** It has no upstream parent on GitHub, so
`gh pr create` defaults its base correctly — unlike the sibling
`rk3588-kernel-patches`, which is a fork and has historically defaulted to the
wrong repository. That difference is a reason to be careful rather than relaxed:
the habit that protects the sibling is the habit that keeps this one right too.

Always be explicit anyway:

```bash
gh pr create --repo CERALIVE/rk3588-media-island --base main
gh pr view <n> --json url -q .url   # MUST be https://github.com/CERALIVE/rk3588-media-island/...
```

Keep **only** `origin` (CERALIVE) attached at rest. The vendor and forward-port
trees this repository imports from are cited by URL and SHA in
[`docs/REFERENCES.md`](../REFERENCES.md); if one ever needs fetching, add it
transiently under a descriptive name — **never** as `upstream` — fetch with an
explicit refspec, pin-verify the SHA, and remove it before any push or PR.

One integration branch per release, one PR from it. Commits on that branch stay
individually meaningful, because provenance and review history are the reason this
is a source repository instead of a patch file.

