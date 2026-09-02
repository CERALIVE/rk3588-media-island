#!/usr/bin/env python3
"""dt-ownership-lint: one driver per node, proven from the device tree.

The Linux driver core binds ONE driver per platform device, and when two drivers
match one node the winner is module load order -- non-deterministic, and
therefore not a design. `docs/OWNERSHIP.md` states the consequence as a rule:

    Every island-owned node carries exactly ONE `compatible` string, matched by
    exactly ONE driver.

No Kconfig mutual exclusion enforces that, deliberately -- mainline `rkvdec` and
`rockchip-rga` stay BUILT so every silicon handover is reversible by a
device-tree change. This lint is what enforces it instead, which is why
`docs/OWNERSHIP.md` is a machine input rather than prose.

WHAT IT ASSERTS
---------------
1. Every island-owned node named in `docs/OWNERSHIP.md` that an `integration/`
   device-tree hunk touches is left with EXACTLY ONE `compatible` string.
2. That string appears in NO mainline driver's `of_match_table`. Checked against
   the pinned kernel tree when one is present (CI clones it); reported as an
   explicit SKIP, never as a pass, when it is not.
3. The island's own driver match table lists it, and lists it once -- so a node
   is not merely un-contested but actually claimed.
4. `integration/` and `integration/pending/` are linted SEPARATELY. A pending
   hunk is held to the same rule but does not ship, which is what lets the RGA
   flip stage both its DT patches ahead of the release that applies them.

Usage
-----
    scripts/check-dt-ownership.py [--kernel-tree .work/linux]
    scripts/check-dt-ownership.py --self-test
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OWNERSHIP_DOC = "docs/OWNERSHIP.md"
DEFAULT_KERNEL_TREE = ".work/linux"

ISLAND_SOURCE_ROOTS = (
    "drivers/video/rockchip/mpp",
    "drivers/video/rockchip/rga3",
)

BACKTICKED = re.compile(r"`([^`]+)`")
NODE_OPEN = re.compile(r"^\s*(?:([A-Za-z_][\w-]*)\s*:\s*)?([\w@,.+-]+)\s*\{\s*$")
COMPATIBLE = re.compile(r"^\s*compatible\s*=\s*(.*?);", re.DOTALL)
QUOTED = re.compile(r'"([^"]*)"')

# A mainline driver's OF match table entry, in either of the two spellings the
# kernel uses. Matching `.compatible = "..."` alone would miss the many tables
# built with a bare initializer, and matching every quoted string would fire on
# unrelated prose.
OF_MATCH = re.compile(r'\.compatible\s*=\s*"([^"]+)"|\{\s*"([^"]+)"\s*,')


class OwnershipError(RuntimeError):
    """The ownership table itself could not be read."""


@dataclass(frozen=True)
class OwnershipRow:
    silicon: str
    labels: tuple[str, ...]
    owner: str
    line: int

    @property
    def island_owned(self) -> bool:
        return "island" in self.owner.lower() and "unchanged" not in self.owner.lower()


def parse_ownership(doc: Path) -> list[OwnershipRow]:
    if not doc.is_file():
        raise OwnershipError(f"{doc} is missing -- dt-ownership-lint has no input")

    rows: list[OwnershipRow] = []
    label_index = owner_index = silicon_index = None

    for number, raw in enumerate(doc.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw.strip()
        if not line.startswith("|"):
            label_index = owner_index = silicon_index = None
            continue
        cells = [cell.strip() for cell in line.strip("|").split("|")]

        if label_index is None:
            lowered = [cell.lower() for cell in cells]
            if "silicon" in lowered and any("node label" in cell for cell in lowered):
                silicon_index = lowered.index("silicon")
                label_index = next(
                    index for index, cell in enumerate(lowered) if "node label" in cell
                )
                owner_index = next(
                    (index for index, cell in enumerate(lowered) if "final owner" in cell),
                    None,
                )
            continue

        if all(set(cell) <= set("-: ") for cell in cells if cell):
            continue
        if owner_index is None or len(cells) <= max(label_index, owner_index):
            continue

        rows.append(
            OwnershipRow(
                silicon=cells[silicon_index] if silicon_index is not None else "",
                labels=tuple(BACKTICKED.findall(cells[label_index])),
                owner=cells[owner_index],
                line=number,
            )
        )

    if not rows:
        raise OwnershipError(f"{doc} contains no ownership rows")
    if not any(row.island_owned for row in rows):
        raise OwnershipError(
            f"{doc} declares no island-owned silicon -- the lint would pass vacuously"
        )
    return rows


def island_labels(rows: list[OwnershipRow]) -> dict[str, OwnershipRow]:
    owned: dict[str, OwnershipRow] = {}
    for row in rows:
        if not row.island_owned:
            continue
        for label in row.labels:
            owned[label] = row
    return owned


def post_image(patch_text: str) -> str:
    """The device tree a hunk LEAVES BEHIND: context plus additions.

    Removals are dropped, because the rule is about what the applied tree
    contains -- a node whose second `compatible` the hunk deletes is compliant,
    and a lint reading the raw patch text would refuse it.
    """
    kept: list[str] = []
    for line in patch_text.split("\n"):
        if line.startswith(("diff --git ", "index ", "--- ", "+++ ", "@@", "new file mode", "deleted file mode", "similarity index", "rename ")):
            continue
        if line.startswith("\\"):
            continue
        if line.startswith("-"):
            continue
        kept.append(line[1:] if line.startswith(("+", " ")) else line)
    return "\n".join(kept)


def node_compatibles(text: str) -> dict[str, list[str]]:
    """label -> the compatible strings its node body carries."""
    lines = text.split("\n")
    found: dict[str, list[str]] = {}
    stack: list[str | None] = []

    for index, line in enumerate(lines):
        opened = NODE_OPEN.match(line)
        if opened:
            stack.append(opened.group(1))
            continue
        if line.strip().startswith("};"):
            if stack:
                stack.pop()
            continue
        if not stack or stack[-1] is None:
            continue
        if not line.strip().startswith("compatible"):
            continue
        window = "\n".join(lines[index : index + 6])
        value = COMPATIBLE.match(window)
        if value is None:
            continue
        found.setdefault(stack[-1], []).extend(QUOTED.findall(value.group(1)))
    return found


def dt_patches(root: Path, subdirectory: str) -> list[Path]:
    base = root / "integration" / subdirectory if subdirectory else root / "integration"
    if not base.is_dir():
        return []
    return sorted(path for path in base.glob("*.patch"))


def mainline_of_match(tree: Path) -> dict[str, str]:
    """Every compatible string a mainline driver's match table lists."""
    table: dict[str, str] = {}
    drivers = tree / "drivers"
    if not drivers.is_dir():
        return table
    for source in drivers.rglob("*.c"):
        relative = source.relative_to(tree).as_posix()
        if relative.startswith(ISLAND_SOURCE_ROOTS):
            continue
        try:
            text = source.read_text(encoding="utf-8", errors="surrogateescape")
        except OSError:
            continue
        if "of_match" not in text and ".compatible" not in text:
            continue
        for match in OF_MATCH.finditer(text):
            value = match.group(1) or match.group(2)
            if value and "," in value:
                table.setdefault(value, relative)
    return table


def island_match_table(root: Path) -> dict[str, int]:
    counts: dict[str, int] = {}
    for source_root in ISLAND_SOURCE_ROOTS:
        base = root / source_root
        if not base.is_dir():
            continue
        for source in sorted(base.rglob("*.c")):
            text = source.read_text(encoding="utf-8", errors="surrogateescape")
            for match in OF_MATCH.finditer(text):
                value = match.group(1) or match.group(2)
                if value and "," in value:
                    counts[value] = counts.get(value, 0) + 1
    return counts


def lint_lane(
    root: Path,
    owned: dict[str, OwnershipRow],
    subdirectory: str,
    mainline: dict[str, str] | None,
) -> tuple[list[str], int, dict[str, list[str]]]:
    lane = f"integration/{subdirectory}" if subdirectory else "integration"
    problems: list[str] = []
    seen: dict[str, list[str]] = {}

    patches = dt_patches(root, subdirectory)
    for patch in patches:
        text = patch.read_text(encoding="utf-8", errors="surrogateescape")
        relative = patch.relative_to(root).as_posix()
        for label, compatibles in node_compatibles(post_image(text)).items():
            if label not in owned:
                continue
            seen.setdefault(label, []).extend(compatibles)
            if len(compatibles) != 1:
                problems.append(
                    f"{relative}: island-owned node `{label}` is left with "
                    f"{len(compatibles)} compatible string(s) "
                    f"({', '.join(compatibles) or 'none'}). "
                    f"{OWNERSHIP_DOC}:{owned[label].line} requires exactly one -- "
                    "with two, which driver binds is module load order, which is "
                    "not a design."
                )

    if mainline is not None:
        for label, compatibles in sorted(seen.items()):
            for value in compatibles:
                if value in mainline:
                    problems.append(
                        f"{lane}: island-owned node `{label}` uses compatible "
                        f"\"{value}\", which mainline {mainline[value]} already "
                        "lists in an of_match_table. Two drivers would match one "
                        "node."
                    )

    return problems, len(patches), seen


def run(root: Path, kernel_tree: Path | None, announce: bool = True) -> list[str]:
    rows = parse_ownership(root / OWNERSHIP_DOC)
    owned = island_labels(rows)

    mainline: dict[str, str] | None = None
    skip_reason = ""
    if kernel_tree is not None and (kernel_tree / "drivers").is_dir():
        mainline = mainline_of_match(kernel_tree)
    else:
        skip_reason = (
            f"no pinned kernel tree at {kernel_tree} -- the mainline of_match_table "
            "collision check is SKIPPED, not passed. CI clones the tree, so this "
            "arm is live there."
        )

    problems, applied_count, applied_seen = lint_lane(root, owned, "", mainline)
    pending_problems, pending_count, _ = lint_lane(root, owned, "pending", mainline)
    problems += pending_problems

    island_table = island_match_table(root)
    for label, compatibles in sorted(applied_seen.items()):
        for value in compatibles:
            if not island_table:
                continue
            count = island_table.get(value, 0)
            if count == 0:
                problems.append(
                    f"integration: `{label}` is left on compatible \"{value}\", but "
                    "no island driver's of_match_table lists it -- the node would "
                    "bind nothing at all."
                )
            elif count > 1:
                problems.append(
                    f"integration: compatible \"{value}\" appears {count} times "
                    "across island of_match_tables -- exactly one driver may claim "
                    "a node."
                )

    if problems or not announce:
        return problems

    if skip_reason:
        print(f"NOTE: {skip_reason}")
    if applied_count == 0 and pending_count == 0:
        print(
            f"OK: {len(owned)} island-owned node label(s) read from {OWNERSHIP_DOC}. "
            "NO-DT-YET -- integration/ carries no device-tree patch, so the "
            "one-compatible rule has nothing to check and passes vacuously. It "
            "becomes required when the DT integration lands; --self-test proves it "
            "non-vacuously today."
        )
    else:
        print(
            f"OK: {len(owned)} island-owned node label(s); {applied_count} applied "
            f"and {pending_count} pending integration patch(es); every island node "
            "carries exactly one compatible."
        )
    return problems


def _self_test() -> int:
    failures: list[str] = []

    def check(name: str, condition: bool) -> None:
        print(f"  [{'ok' if condition else 'FAIL'}] {name}")
        if not condition:
            failures.append(name)

    print("self_test=check-dt-ownership")

    rows = parse_ownership(ROOT / OWNERSHIP_DOC)
    owned = island_labels(rows)
    check("docs/OWNERSHIP.md parses", bool(rows))
    check("vdec0 is island-owned", "vdec0" in owned)
    check("rga is island-owned", "rga" in owned)
    check(
        "a hantro-owned row claims no node",
        all(
            not row.labels
            for row in rows
            if "hantro" in row.owner.lower() and not row.island_owned
        ),
    )
    check(
        "the per-client IOMMU nodes are NOT claimed",
        "rkvenc0_mmu" not in owned and "rkvenc1_mmu" not in owned,
    )

    def hunk(body: str) -> str:
        return (
            "diff --git a/arch/arm64/boot/dts/rockchip/rk3588-base.dtsi "
            "b/arch/arm64/boot/dts/rockchip/rk3588-base.dtsi\n"
            "--- a/arch/arm64/boot/dts/rockchip/rk3588-base.dtsi\n"
            "+++ b/arch/arm64/boot/dts/rockchip/rk3588-base.dtsi\n"
            "@@ -1400,7 +1400,8 @@\n" + body
        )

    with tempfile.TemporaryDirectory() as scratch:
        base = Path(scratch)

        def island(name: str, patch_body: str, lane: str = "") -> Path:
            tree = base / name
            (tree / "docs").mkdir(parents=True, exist_ok=True)
            (tree / "docs/OWNERSHIP.md").write_text(
                (ROOT / OWNERSHIP_DOC).read_text(encoding="utf-8"), encoding="utf-8"
            )
            lane_dir = tree / "integration" / lane if lane else tree / "integration"
            lane_dir.mkdir(parents=True, exist_ok=True)
            (lane_dir / "0011-dts.patch").write_text(hunk(patch_body), encoding="utf-8")
            return tree

        one = island(
            "one-compatible",
            "\tvdec0: video-codec@fdc38000 {\n"
            '-\t\tcompatible = "rockchip,rk3588-vdec";\n'
            '+\t\tcompatible = "rockchip,rkv-decoder-v2";\n'
            "\t\treg = <0x0 0xfdc38000 0x0 0x400>;\n"
            "\t};\n",
        )
        check("one compatible passes", not run(one, None, announce=False))

        two = island(
            "two-compatibles",
            "\tvdec0: video-codec@fdc38000 {\n"
            '-\t\tcompatible = "rockchip,rk3588-vdec";\n'
            '+\t\tcompatible = "rockchip,rkv-decoder-v2", "rockchip,rk3588-vdec";\n'
            "\t\treg = <0x0 0xfdc38000 0x0 0x400>;\n"
            "\t};\n",
        )
        found = run(two, None, announce=False)
        check(
            "two compatibles on an island node fails, naming the node",
            any("`vdec0`" in problem and "2 compatible" in problem for problem in found),
        )

        kept = island(
            "kept-mainline-compatible",
            "\tvdec0: video-codec@fdc38000 {\n"
            '\t\tcompatible = "rockchip,rk3588-vdec";\n'
            '+\t\trockchip,skip-pmu-idle-request;\n'
            "\t};\n",
        )
        check(
            "leaving the mainline compatible in place is still one string",
            not run(kept, None, announce=False),
        )

        untouched = island(
            "untouched-node",
            "\tvpu121: video-codec@fdb50000 {\n"
            '\t\tcompatible = "rockchip,rk3588-vpu", "rockchip,rk3568-vpu";\n'
            "\t};\n",
        )
        check(
            "a node the island does not own may keep two compatibles",
            not run(untouched, None, announce=False),
        )

        pending = island(
            "pending-two",
            "\trga3_core0: rga@fdb60000 {\n"
            '+\t\tcompatible = "rockchip,rga3_core0", "rockchip,rk3588-rga3";\n'
            "\t};\n",
            lane="pending",
        )
        check(
            "a PENDING hunk is held to the same rule",
            any("rga3_core0" in problem for problem in run(pending, None, announce=False)),
        )

        # The mainline-collision arm, against a synthetic kernel tree.
        collide = island(
            "collision",
            "\tvdec0: video-codec@fdc38000 {\n"
            '+\t\tcompatible = "rockchip,rk3588-vdec";\n'
            "\t};\n",
        )
        fake_tree = base / "linux"
        (fake_tree / "drivers/staging/media/rkvdec").mkdir(parents=True)
        (fake_tree / "drivers/staging/media/rkvdec/rkvdec.c").write_text(
            "static const struct of_device_id of_rkvdec_match[] = {\n"
            '\t{ .compatible = "rockchip,rk3588-vdec", .data = &cfg },\n'
            "\t{ /* sentinel */ }\n};\n",
            encoding="utf-8",
        )
        found = run(collide, fake_tree, announce=False)
        check(
            "a compatible mainline already matches fails, naming the driver",
            any("rkvdec.c" in problem for problem in found),
        )

        clean = island(
            "no-collision",
            "\tvdec0: video-codec@fdc38000 {\n"
            '+\t\tcompatible = "rockchip,rkv-decoder-v2";\n'
            "\t};\n",
        )
        check(
            "a vendor-only compatible does not collide",
            not run(clean, fake_tree, announce=False),
        )

        # The island's own match table must claim the node.
        unclaimed = island(
            "unclaimed",
            "\tvdec0: video-codec@fdc38000 {\n"
            '+\t\tcompatible = "rockchip,rkv-decoder-v2";\n'
            "\t};\n",
        )
        mpp = unclaimed / "drivers/video/rockchip/mpp"
        mpp.mkdir(parents=True)
        (mpp / "mpp_rkvenc2.c").write_text(
            'static const struct of_device_id mpp_rkvenc_match[] = {\n'
            '\t{ .compatible = "rockchip,rkv-encoder-v2" },\n};\n',
            encoding="utf-8",
        )
        check(
            "an island node no island driver claims fails",
            any("bind nothing at all" in p for p in run(unclaimed, None, announce=False)),
        )
        (mpp / "mpp_rkvdec2.c").write_text(
            'static const struct of_device_id mpp_rkvdec_match[] = {\n'
            '\t{ .compatible = "rockchip,rkv-decoder-v2" },\n};\n',
            encoding="utf-8",
        )
        check(
            "an island node its own driver claims passes",
            not run(unclaimed, None, announce=False),
        )

        # A table declaring no island silicon must fail closed, not pass empty.
        hollow = base / "hollow"
        (hollow / "docs").mkdir(parents=True)
        (hollow / "docs/OWNERSHIP.md").write_text(
            "| Silicon | Island node label(s) | Final owner |\n"
            "|---|---|---|\n"
            "| RGA3 | — | **UNCHANGED mainline** |\n",
            encoding="utf-8",
        )
        try:
            run(hollow, None, announce=False)
        except OwnershipError as error:
            check("a table with no island row fails closed", "vacuously" in str(error))
        else:
            check("a table with no island row fails closed", False)

    if failures:
        print(f"FAIL: {len(failures)} self-test case(s) failed")
        return 1
    print("PASS: self-test")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kernel-tree", default=DEFAULT_KERNEL_TREE)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv[1:])

    if args.self_test:
        return _self_test()

    tree = Path(args.kernel_tree)
    if not tree.is_absolute():
        tree = ROOT / tree

    try:
        problems = run(ROOT, tree)
    except OwnershipError as error:
        print(f"FAIL: {error}")
        return 1

    if problems:
        print("FAIL: dt-ownership-lint refused this tree.")
        for problem in problems:
            print(f"  {problem}")
        print()
        print(
            "Every island-owned node carries exactly ONE compatible string, matched "
            "by exactly ONE driver. Exclusivity is this lint plus the one-compatible "
            "rule -- never a Kconfig `depends on !...`, which would stop mainline "
            "rkvdec/rockchip-rga being built and make each flip irreversible."
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
