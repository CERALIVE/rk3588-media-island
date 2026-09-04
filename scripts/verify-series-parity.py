#!/usr/bin/env python3
"""Prove `patches/` says exactly what its source says -- independently.

WHY A SECOND CHECKER
--------------------
`scripts/build-series.py --check` regenerates the series and byte-compares. That
proves the GENERATOR agrees with itself: run it twice on one tree and you get one
answer, which is true even if the generator drops half the source or mangles an
integration hunk. A checker that imported the generator would inherit the same
blind spot.

So this script shares NO CODE with the generator, on purpose. It reads
`patches/` as an opaque mailbox, reconstructs what the series claims, and holds
that against `drivers/` and `integration/` from the filesystem alone. Do not
"deduplicate" the two: the duplication IS the independence.

WHAT IT ASSERTS
---------------
1. `patches/series` lists exactly the `*.patch` files present, in apply order.
2. Every mailbox is `git am`-shaped and its `N/T` matches its real position and
   the real series length.
3. Every file a create-mode hunk claims to add reconstructs BYTE-IDENTICALLY to
   the file on disk, and the set of claimed files equals the set of island
   source files -- both directions, so a dropped file and an invented one are
   each an error.
4. Every non-create patch's payload is byte-identical to an `integration/*.patch`
   payload, matched one-to-one -- so a series carrying a hunk `integration/` does
   not have, or omitting one it does, fails.
5. An EMPTY series is accepted only when the source tree is genuinely empty. An
   empty `patches/` beside real source is the silent-drop failure this exists to
   catch.

Usage
-----
    scripts/verify-series-parity.py
    scripts/verify-series-parity.py --self-test
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path
from typing import Final

ROOT = Path(__file__).resolve().parent.parent

# Re-derived here rather than imported. If these two lists ever disagree with the
# generator's, that disagreement is a finding -- which is the entire point.
ISLAND_SOURCE_ROOTS = (
    "drivers/video/rockchip/mpp",
    "drivers/video/rockchip/rga3",
    "include/uapi/linux",
)
ISLAND_SOURCE_SUFFIXES = (".c", ".h", ".S")
ISLAND_SOURCE_EXACT = ("Kconfig", "Makefile")
GENERATED_SOURCE_SUFFIXES = (".mod.c",)
NOT_SOURCE = (".gitkeep",)

REPOSITORY_SOURCE_COUNT: Final = 78
REPOSITORY_INTEGRATION_COUNT: Final = 6
REPOSITORY_SERIES_COUNT: Final = 7

MBOX_DELIMITER = re.compile(r"^From [0-9a-f]{40} Mon Sep 17 00:00:00 2001$")
SUBJECT = re.compile(r"^Subject: \[PATCH (\d+)/(\d+)\] (.+)$")
FILE_HEADER = re.compile(r"^diff --git a/(\S+) b/(\S+)$")
HUNK_HEADER = re.compile(r"^@@ -0,0 \+1,(\d+) @@")


class ParityError(RuntimeError):
    """The series and its source disagree."""


def island_source_files(root: Path) -> dict[str, str]:
    """Every island source file on disk, path -> contents."""
    found: dict[str, str] = {}
    for source_root in ISLAND_SOURCE_ROOTS:
        base = root / source_root
        if not base.is_dir():
            continue
        for candidate in sorted(base.rglob("*")):
            if not candidate.is_file():
                continue
            name = candidate.name
            if name in NOT_SOURCE:
                continue
            if name.endswith(GENERATED_SOURCE_SUFFIXES):
                continue
            if name not in ISLAND_SOURCE_EXACT and not name.endswith(
                ISLAND_SOURCE_SUFFIXES
            ):
                continue
            found[candidate.relative_to(root).as_posix()] = candidate.read_text(
                encoding="utf-8", errors="surrogateescape"
            )
    return found


def integration_payloads(root: Path) -> dict[str, str]:
    """`integration/*.patch` -> the diff text, from the first `diff --git` on.

    `integration/pending/` is excluded: a staged hunk is linted but does not
    ship, so a series carrying one would be the error, not the omission.
    """
    base = root / "integration"
    if not base.is_dir():
        return {}
    payloads: dict[str, str] = {}
    for path in sorted(base.glob("*.patch")):
        text = path.read_text(encoding="utf-8", errors="surrogateescape")
        lines = text.split("\n")
        for index, line in enumerate(lines):
            if line.startswith("diff --git "):
                payloads[path.name] = "\n".join(lines[index:]).rstrip("\n")
                break
        else:
            raise ParityError(
                f"integration/{path.name}: carries no `diff --git` line, so it "
                "cannot be a patch against a mainline file"
            )
    return payloads


def read_series_order(patches: Path) -> list[str]:
    series_file = patches / "series"
    if not series_file.is_file():
        raise ParityError("patches/series is missing")
    listed = [
        line.strip()
        for line in series_file.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    present = sorted(path.name for path in patches.glob("*.patch"))
    if listed != sorted(listed):
        raise ParityError("patches/series is not in lexical apply order")
    if listed != present:
        missing = sorted(set(present) - set(listed))
        extra = sorted(set(listed) - set(present))
        detail = []
        if missing:
            detail.append(f"present but unlisted: {', '.join(missing)}")
        if extra:
            detail.append(f"listed but absent: {', '.join(extra)}")
        raise ParityError("patches/series does not match patches/ (" + "; ".join(detail) + ")")
    return listed


def split_mailbox(text: str, name: str) -> tuple[int, int, str]:
    """(ordinal, total, payload) for one mailbox file."""
    lines = text.split("\n")
    if not lines or not MBOX_DELIMITER.match(lines[0]):
        raise ParityError(f"{name}: not a git-am mailbox (bad `From <hex>` delimiter)")

    ordinal = total = None
    for line in lines[1:]:
        match = SUBJECT.match(line)
        if match:
            ordinal, total = int(match.group(1)), int(match.group(2))
            break
        if not line.strip():
            break
    if ordinal is None or total is None:
        raise ParityError(f"{name}: no `Subject: [PATCH n/T] ...` header")

    try:
        separator = lines.index("---")
    except ValueError as error:
        raise ParityError(f"{name}: no `---` separator before the diff") from error

    payload_lines = lines[separator + 1 :]
    for index, line in enumerate(payload_lines):
        if line == "-- ":
            payload_lines = payload_lines[:index]
            break
    return ordinal, total, "\n".join(payload_lines).rstrip("\n")


def reconstruct_created_files(payload: str, name: str) -> dict[str, str]:
    """Rebuild every file a create-mode payload claims to add.

    Returns an empty mapping for a payload that creates nothing. The caller
    first matches integration payloads exactly because an integration patch may
    itself create a file that mainline does not yet carry.
    """
    files: dict[str, str] = {}
    lines = payload.split("\n")
    index = 0
    while index < len(lines):
        header = FILE_HEADER.match(lines[index])
        if header is None:
            index += 1
            continue
        path = header.group(2)
        index += 1
        creates = False
        while index < len(lines) and not lines[index].startswith("@@"):
            if lines[index].startswith("new file mode "):
                creates = True
            if lines[index].startswith("diff --git "):
                break
            index += 1
        if not creates or index >= len(lines):
            continue
        hunk = HUNK_HEADER.match(lines[index])
        if hunk is None:
            raise ParityError(
                f"{name}: {path} is create-mode but its hunk header is not "
                f"`@@ -0,0 +1,N @@` ({lines[index]!r})"
            )
        expected = int(hunk.group(1))
        index += 1
        body: list[str] = []
        no_newline = False
        while index < len(lines):
            line = lines[index]
            if line.startswith("diff --git "):
                break
            if line == "\\ No newline at end of file":
                no_newline = True
                index += 1
                continue
            if not line.startswith("+"):
                raise ParityError(
                    f"{name}: {path} is create-mode but carries a non-added "
                    f"line ({line!r}) -- a created file has nothing to remove"
                )
            body.append(line[1:])
            index += 1
        if len(body) != expected:
            raise ParityError(
                f"{name}: {path} hunk claims {expected} line(s) but carries {len(body)}"
            )
        files[path] = "\n".join(body) + ("" if no_newline else "\n" if body else "")
    return files


def verify(root: Path) -> list[str]:
    problems: list[str] = []
    patches = root / "patches"
    if not patches.is_dir():
        return ["patches/ does not exist -- run scripts/build-series.py"]

    order = read_series_order(patches)
    on_disk = island_source_files(root)
    integration = integration_payloads(root)

    if not order:
        if on_disk:
            problems.append(
                f"the series is empty but {len(on_disk)} island source file(s) exist "
                "-- the series silently drops them"
            )
        if integration:
            problems.append(
                f"the series is empty but {len(integration)} integration patch(es) "
                "exist -- the series silently drops them"
            )
        if not problems:
            print(
                "OK (independent): the series is empty and so is the source tree "
                "-- NO-SOURCE-YET. This becomes a real parity proof when the "
                "driver import lands."
            )
        return problems

    claimed_files: dict[str, str] = {}
    claimed_from: dict[str, str] = {}
    unmatched_integration = dict(integration)

    for position, name in enumerate(order, start=1):
        text = (patches / name).read_text(encoding="utf-8", errors="surrogateescape")
        ordinal, total, payload = split_mailbox(text, name)
        if ordinal != position:
            problems.append(f"{name}: numbered {ordinal} but sits at position {position}")
        if total != len(order):
            problems.append(
                f"{name}: claims a series of {total} but the series has {len(order)}"
            )

        match = next(
            (
                source
                for source, source_payload in unmatched_integration.items()
                if source_payload == payload
            ),
            None,
        )
        if match is not None:
            del unmatched_integration[match]
            continue

        created = reconstruct_created_files(payload, name)
        if created:
            for path, content in created.items():
                if path in claimed_files:
                    problems.append(
                        f"{path}: created twice, by {claimed_from[path]} and {name}"
                    )
                claimed_files[path] = content
                claimed_from[path] = name
            continue

        problems.append(
            f"{name}: its payload matches no integration/*.patch -- the series "
            "carries a hunk the source does not have"
        )

    for source in sorted(unmatched_integration):
        problems.append(
            f"integration/{source}: no patch in the series carries its payload"
        )

    for path in sorted(set(on_disk) - set(claimed_files)):
        problems.append(f"{path}: island source file absent from the series")
    for path in sorted(set(claimed_files) - set(on_disk)):
        problems.append(f"{path}: the series creates a file that is not island source")
    for path in sorted(set(on_disk) & set(claimed_files)):
        if on_disk[path] != claimed_files[path]:
            problems.append(
                f"{path}: the series' copy differs from the file on disk"
            )

    if not problems:
        print(
            f"OK (independent): {len(order)} patch(es) reconstruct "
            f"{len(claimed_files)} island source file(s) byte-identically and carry "
            f"{len(integration)} integration payload(s) verbatim."
        )
    return problems


def repository_census_problems(root: Path) -> list[str]:
    sources = len(island_source_files(root))
    integration = len(integration_payloads(root))
    series = len(read_series_order(root / "patches"))
    problems: list[str] = []

    if sources != REPOSITORY_SOURCE_COUNT:
        problems.append(
            f"repository source census is {sources}, expected {REPOSITORY_SOURCE_COUNT}"
        )
    if integration != REPOSITORY_INTEGRATION_COUNT:
        problems.append(
            "repository integration census is "
            f"{integration}, expected {REPOSITORY_INTEGRATION_COUNT}"
        )
    if series != REPOSITORY_SERIES_COUNT:
        problems.append(
            f"repository series census is {series}, expected {REPOSITORY_SERIES_COUNT}"
        )

    return problems


def _self_test() -> int:
    """Every rule above, proven to FAIL when its input is mutated."""
    failures: list[str] = []

    def check(name: str, condition: bool) -> None:
        print(f"  [{'ok' if condition else 'FAIL'}] {name}")
        if not condition:
            failures.append(name)

    print("self_test=verify-series-parity")

    good = "\n".join(
        [
            "From " + "0" * 40 + " Mon Sep 17 00:00:00 2001",
            "From: CeraLive <dev@ceralive.tv>",
            "Subject: [PATCH 1/1] add",
            "",
            "body",
            "",
            "---",
            "diff --git a/drivers/video/rockchip/mpp/a.c b/drivers/video/rockchip/mpp/a.c",
            "new file mode 100644",
            "index 0000000000000000000000000000000000000000..1111111111111111111111111111111111111111",
            "--- /dev/null",
            "+++ b/drivers/video/rockchip/mpp/a.c",
            "@@ -0,0 +1,1 @@",
            "+int a;",
            "-- ",
            "2.51.0",
            "",
        ]
    )

    def build(tmp: Path, patch_text: str, file_text: str) -> Path:
        island = tmp
        (island / "drivers/video/rockchip/mpp").mkdir(parents=True, exist_ok=True)
        (island / "drivers/video/rockchip/mpp/a.c").write_text(file_text, encoding="utf-8")
        (island / "patches").mkdir(parents=True, exist_ok=True)
        (island / "patches/0001-add.patch").write_text(patch_text, encoding="utf-8")
        (island / "patches/series").write_text("0001-add.patch\n", encoding="utf-8")
        return island

    with tempfile.TemporaryDirectory() as scratch:
        base = Path(scratch)

        clean = build(base / "clean", good, "int a;\n")
        check("a faithful series verifies clean", not verify(clean))

        # Integration payloads may create a mainline file (for example the
        # rockchip video Kconfig hook) while modifying another one.  That does
        # not turn the mailbox into the island SOURCE bundle: exact payload
        # identity is the class boundary.
        integration_create = base / "integration-create"
        (integration_create / "integration").mkdir(parents=True)
        integration_payload = "\n".join(
            [
                "diff --git a/drivers/video/rockchip/Kconfig b/drivers/video/rockchip/Kconfig",
                "new file mode 100644",
                "index 0000000000000000000000000000000000000000..1111111111111111111111111111111111111111",
                "--- /dev/null",
                "+++ b/drivers/video/rockchip/Kconfig",
                "@@ -0,0 +1,1 @@",
                '+source "drivers/video/rockchip/mpp/Kconfig"',
            ]
        )
        (integration_create / "integration/0001-hooks.patch").write_text(
            integration_payload + "\n", encoding="utf-8"
        )
        (integration_create / "patches").mkdir()
        integration_mailbox = "\n".join(
            [
                "From " + "0" * 40 + " Mon Sep 17 00:00:00 2001",
                "Subject: [PATCH 1/1] hooks",
                "",
                "---",
                integration_payload,
                "-- ",
                "2.51.0",
                "",
            ]
        )
        (integration_create / "patches/0001-hooks.patch").write_text(
            integration_mailbox, encoding="utf-8"
        )
        (integration_create / "patches/series").write_text(
            "0001-hooks.patch\n", encoding="utf-8"
        )
        check(
            "a create-mode integration payload remains integration",
            not verify(integration_create),
        )

        drifted = build(base / "drifted", good, "int a; /* edited on disk */\n")
        check(
            "a source file edited without regenerating fails",
            any("differs from the file on disk" in p for p in verify(drifted)),
        )

        dropped = build(base / "dropped", good, "int a;\n")
        (dropped / "drivers/video/rockchip/mpp/b.c").write_text("int b;\n", encoding="utf-8")
        check(
            "a source file the series never carries fails",
            any("absent from the series" in p for p in verify(dropped)),
        )

        generated = build(base / "generated", good, "int a;\n")
        (generated / "drivers/video/rockchip/mpp/rk_vcodec.mod.c").write_text(
            "generated module metadata\n", encoding="utf-8"
        )
        check("generated .mod.c is not island source", not verify(generated))

        claimed_generated = build(
            base / "claimed-generated",
            good.replace(
                "drivers/video/rockchip/mpp/a.c",
                "drivers/video/rockchip/mpp/rk_vcodec.mod.c",
            ),
            "int a;\n",
        )
        check(
            "a mailbox claiming generated .mod.c fails",
            any("rk_vcodec.mod.c" in problem for problem in verify(claimed_generated)),
        )

        misnumbered = build(
            base / "misnumbered", good.replace("[PATCH 1/1]", "[PATCH 2/7]"), "int a;\n"
        )
        check(
            "a mailbox whose n/T lies fails",
            len(verify(misnumbered)) >= 2,
        )

        # An integration payload the source does not have.
        stray = build(base / "stray", good, "int a;\n")
        (stray / "patches/0002-stray.patch").write_text(
            "\n".join(
                [
                    "From " + "0" * 40 + " Mon Sep 17 00:00:00 2001",
                    "Subject: [PATCH 2/2] stray",
                    "",
                    "---",
                    "diff --git a/drivers/iommu/rockchip-iommu.c b/drivers/iommu/rockchip-iommu.c",
                    "--- a/drivers/iommu/rockchip-iommu.c",
                    "+++ b/drivers/iommu/rockchip-iommu.c",
                    "@@ -1,1 +1,2 @@",
                    " x",
                    "+EXPORT_SYMBOL(y);",
                    "-- ",
                    "2.51.0",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        (stray / "patches/series").write_text(
            "0001-add.patch\n0002-stray.patch\n", encoding="utf-8"
        )
        check(
            "a series hunk with no integration/ source fails",
            any("matches no integration" in p for p in verify(stray)),
        )

        # An empty series beside real source is the silent-drop case.
        silent = base / "silent"
        (silent / "drivers/video/rockchip/mpp").mkdir(parents=True)
        (silent / "drivers/video/rockchip/mpp/a.c").write_text("int a;\n", encoding="utf-8")
        (silent / "patches").mkdir()
        (silent / "patches/series").write_text("", encoding="utf-8")
        check(
            "an empty series beside real source fails",
            any("silently drops" in p for p in verify(silent)),
        )

        # Empty tree, empty series -- the honest today-state.
        nothing = base / "nothing"
        (nothing / "patches").mkdir(parents=True)
        (nothing / "patches/series").write_text("", encoding="utf-8")
        check("an empty series beside an empty tree verifies", not verify(nothing))

        # series/directory disagreement.
        orphaned = build(base / "orphaned", good, "int a;\n")
        (orphaned / "patches/0009-orphan.patch").write_text("x\n", encoding="utf-8")
        try:
            verify(orphaned)
        except ParityError as error:
            check("an unlisted file in patches/ fails", "does not match" in str(error))
        else:
            check("an unlisted file in patches/ fails", False)

    if failures:
        print(f"FAIL: {len(failures)} self-test case(s) failed")
        return 1
    print("PASS: self-test")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv[1:])

    if args.self_test:
        return _self_test()

    try:
        problems = verify(ROOT)
        problems.extend(repository_census_problems(ROOT))
    except ParityError as error:
        print(f"FAIL (independent): {error}")
        return 1

    if problems:
        print("FAIL (independent): the series and its source disagree.")
        for problem in problems:
            print(f"  {problem}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
