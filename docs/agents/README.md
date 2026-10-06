# Preserved agent contracts

Every original AGENTS.md block is retained below; only Markdown link targets moved.
Read the relevant contract before changing its subsystem.

The archived blanket depth prohibition is superseded by the dated
[workspace bit-depth policy](https://github.com/CERALIVE/ceralive/blob/master/AGENTS.md#critical-constraints);
this relocation grants no new implementation or qualification authority.

| Original heading | Preserved file | Governed paths or tasks |
|---|---|---|
| Overview | [overview.md](overview.md) | Repository identity |
| ROLE IN THE GROUP | [role-in-the-group.md](role-in-the-group.md) | `drivers/`, `include/uapi/linux/`, `integration/`; consumer release chain |
| STRUCTURE | [structure.md](structure.md) | `kernel-pin.env`, `drivers/`, `include/`, `integration/`, `patches/`, `scripts/`, `tests/`, `docs/` |
| WHERE TO LOOK | [where-to-look.md](where-to-look.md) | `scripts/`, `tests/board/`, `tests/kunit/`, `integration/`; subsystem documents |
| KEY FACTS | [key-facts.md](key-facts.md) | `drivers/video/rockchip/{mpp,rga3}/`, `kernel-pin.env`, `patches/`, `docs/{COMPAT,OWNERSHIP}.md`, `tests/board/` |
| PR TARGETING | [pr-targeting.md](pr-targeting.md) | `docs/REFERENCES.md`; origin and release integration branches |
| CI | [ci.md](ci.md) | `.github/workflows/`, `scripts/`, `tests/`, `kernel-pin.env` |
| ANTI-PATTERNS | [anti-patterns.md](anti-patterns.md) | `drivers/`, `integration/`, `patches/`, `kernel-pin.env`; release and board safety |
