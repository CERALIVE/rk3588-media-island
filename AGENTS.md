# rk3588-media-island

Parent: [workspace rules](https://github.com/CERALIVE/ceralive/blob/master/AGENTS.md).

<!-- workspace-hard-rules:begin -->
## Workspace hard rules (identical in every CeraLive AGENTS.md)
- Commits and PRs carry the human author only: no Co-authored-by, no AI attribution.
- Start from the updated canonical branch; rebase to update; never `reset --hard` or discard others' work.
- One focused PR per repo, opened against CERALIVE/<repo>; the root policy PR merges first.
- A repo is self-contained: no path above its root; consume @ceralive packages from the registry, never link:/file:.
- Never delete, skip or weaken a test; every behavior change ships with a test.
- A user-visible change updates docs.ceralive.tv in English and Spanish (es-419), and any ceralive.tv claim it touches, in the same release.
- AGENTS.md holds rules and routing only, within budget; contracts and history live in docs/agents/.
- Full canon: https://github.com/CERALIVE/ceralive/blob/master/AGENTS.md
<!-- workspace-hard-rules:end -->

## ROLE

Maintained REAL SOURCE for the RK3588 MPP service (RKVENC2, RKVDEC2, JPGDEC) and `multi_rga`.
Ships a generated `git am` mailbox series, consumed byte-preserved by `rk3588-kernel-patches`' `island/` lane.
Produces no `.deb`, kernel or image; never belongs in device `REPOS`.

## STRUCTURE

| Path | Purpose |
|---|---|
| `drivers/` | Maintained MPP and RGA kernel source |
| `include/` | Published UAPI headers |
| `integration/` | Build/provider/device-tree patches |
| `configs/` | Island kernel configuration fragment |
| `patches/` | Generated mailbox output |
| `scripts/` | Generators and independent contract checkers |
| `tests/` | Host fixtures, probes, KUnit and hardware drills |
| `docs/` | Ownership, provenance, ABI, qualification and archived contracts |

## COMMANDS

```bash
shellcheck -S style -e SC1091 -x tests/board/*.sh tests/board/lib/*.sh scripts/*.sh
bash scripts/check-rga-memory.sh
for script in tests/board/*.sh tests/dt/*.sh; do bash "$script" --self-test || exit; done
for tool in scripts/{build-series,verify-series-parity,check-compat-shims,check-dt-ownership,check-mpp-hardening,check-modernization,check-upstream-freshness}.py; do python3 "$tool" --self-test || exit; done
for script in scripts/{check-action-pins,check-module-contract,check-telemetry-contract,check-fault-seam-contract,vendor-backlog}.sh; do bash "$script" --self-test || exit; done
bash scripts/check-module-contract.sh
bash scripts/check-telemetry-contract.sh
bash scripts/check-fault-seam-contract.sh
python3 scripts/build-series.py --check
python3 scripts/verify-series-parity.py
python3 scripts/check-compat-shims.py
python3 scripts/check-dt-ownership.py
python3 -m unittest discover -s tests/uapi -v
make -C tests/board CROSS_COMPILE=aarch64-linux-gnu- clean all
make -C tests/board selftest
```

Full PR gate: `.github/workflows/ci.yml`; kernel cross-build, KUnit and static analysis require the pinned kernel tree.
Host fixtures and sanitizer regressions are not board qualification. See the CI contract before running those lanes.

## WHERE TO LOOK

Before changing anything else here, open [docs/agents/README.md](docs/agents/README.md) and read the contract for the subsystem you touch.

| Code path or task | Contract |
|---|---|
| Repository identity | [overview](docs/agents/overview.md) |
| Source scope, consumers and three-merge release chain | [role in the group](docs/agents/role-in-the-group.md) |
| Directory and script inventory | [structure](docs/agents/structure.md) |
| Subsystem docs, board harnesses, provenance and licences | [where to look](docs/agents/where-to-look.md) |
| MPP/RGA lifetime, ioctl, telemetry, ownership, compat and board safety | [key facts](docs/agents/key-facts.md) |
| Remotes, PR target and integration history | [PR targeting](docs/agents/pr-targeting.md) |
| Workflows, fixtures, kernel pin, static analysis and KUnit | [CI](docs/agents/ci.md) |
| Driver/client scope, ABI, DT, licence, release numbering and deployment restrictions | [anti-patterns](docs/agents/anti-patterns.md) |

The archived blanket depth prohibition is superseded by the workspace's dated bit-depth policy; independent FBC/AFBC and AV1 restrictions remain.

## HARD RULES

- Maintain REAL SOURCE: MPP has only RKVENC2/RKVDEC2/JPGDEC; capability tables advertise only compiled and probed clients. AV1 stays off.
- Release a generated `git am` series; `rk3588-kernel-patches`' `island/` lane is the sole, byte-preserving consumer. No `.deb` or `REPOS` entry.
- A kernel change costs three merges: island tag -> `island/` lane bump -> image `patches_commit` bump -> image build.
- Each DT node has exactly one `compatible`, matched by exactly one driver; ownership is DT, never module load order.
- No Kconfig mutual exclusion: never add `depends on !VIDEO_ROCKCHIP_VDEC` or `!VIDEO_ROCKCHIP_RGA`; mainline drivers stay built.
- Island-member provenance names the island tag, commit and asset digest; the independent verifier must not import the generator.
- Never hand-edit `patches/`; change maintained source, then generate and independently verify the series.
- `kernel-pin.env` mirrors the consumer's four `KERNEL_*` values. Change the consumer first; never restate kernel pins in workflows.
- Shims nest in `drivers/video/rockchip/mpp/compat/`; never stub REAL-DEPENDENCY symbols. Classify additions in `docs/COMPAT.md`.
- `docs/COMPAT.md` and `docs/OWNERSHIP.md` are machine inputs; update ownership rows with DT changes and retain lint plus link gates.
- No new DTB or overlay files; use in-tree DTS hunks. No consumer ordinal reuse, gap closure, renumbering or source-patch deletion.
- Preserve UAPI and frozen proc formats; telemetry root creation fails closed. Consult ioctl, lifetime and telemetry contracts before edits.
- RGA reset failure is fail-stop: retain mappings and power until reboot, admit no new work, and preserve device lifetime.
- Test-only fault controls remain default-off; host fixtures never establish silicon qualification.
- Before board deploy: other RAUC slot good, attempt budget >=1, candidate journal captured before reboot; paste qualification transcripts.
- Every board result names board, kernel build and island tag; validate final journals before matrix verdicts, failing closed on I/O errors.
- CalVer tags are `vYYYY.M.N`; release canonical main only after gates pass. Published tags and assets are immutable.
- Never relicense, rewrite SPDX, assert inherited MIT licensing or upstream-submission status; cite upstream evidence by URL and SHA.
- Keep build evidence here and in image dry-runs, not in the patch-application consumer. Follow the routed proof boundaries.
- Keep only CERALIVE origin at rest; use one meaningful integration branch and PR per release, targeting CERALIVE with base main.
