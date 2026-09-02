#!/usr/bin/env python3
"""Verify the manifest-driven replay inventory for yisding's fwport series.

The source import deliberately does not run ``git am`` in this repository.
Instead, every path named by the pinned 0001..0097 patch record is classified
in ``docs/IMPORT-MANIFEST.tsv`` before any member is replayed.  This tool makes
that classification closed in both directions: a new upstream path, a stale
manifest row, or a wrong member census is an error.

Usage:
    scripts/import-manifest.py --patch-dir /path/to/forward-port-rk3588
    scripts/import-manifest.py --self-test
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from collections import defaultdict
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Final

ROOT: Final = Path(__file__).resolve().parent.parent
MANIFEST: Final = ROOT / "docs" / "IMPORT-MANIFEST.tsv"
PATCH_GLOB: Final = "rk3588-fwport-*.patch"
PATCH_NAME: Final = re.compile(r"^rk3588-fwport-(\d{4})-.+\.patch$")
DIFF_HEADER: Final = re.compile(r"^diff --git a/(\S+) b/(\S+)$")
MEMBER_LIST: Final = re.compile(r"^\d{4}(?:,\d{4})*$")
EXPECTED_MEMBERS: Final = tuple(f"{member:04d}" for member in range(1, 98))
SOURCE_ROOTS: Final = (
    "drivers/video/rockchip/mpp/",
    "drivers/video/rockchip/rga3/",
)
SOURCE_FILES: Final = frozenset({"include/uapi/linux/rk-mpp.h"})
HEADER: Final = ("path", "class", "members")


class ManifestError(RuntimeError):
    """The patch record or manifest cannot be trusted as an import input."""


@dataclass(frozen=True, slots=True)
class PatchInventory:
    """The exact patch members that touch each diff path."""

    members_by_path: Mapping[str, tuple[str, ...]]


@dataclass(frozen=True, slots=True)
class ManifestEntry:
    """One parsed path-classification row."""

    path: str
    classification: str
    members: tuple[str, ...]


def _member(path: Path) -> str:
    match = PATCH_NAME.fullmatch(path.name)
    if match is None:
        raise ManifestError(f"unexpected patch filename: {path.name}")
    return match.group(1)


def collect_patch_inventory(patch_dir: Path) -> PatchInventory:
    """Parse every diff header from the contiguous 0001..0097 series."""
    patches = sorted(patch_dir.glob(PATCH_GLOB))
    members = tuple(_member(path) for path in patches)
    if members != EXPECTED_MEMBERS:
        missing = sorted(set(EXPECTED_MEMBERS) - set(members))
        extra = sorted(set(members) - set(EXPECTED_MEMBERS))
        raise ManifestError(
            "fwport series is not contiguous 0001..0097 "
            f"(missing={','.join(missing) or '-'}; extra={','.join(extra) or '-'})"
        )

    found: defaultdict[str, set[str]] = defaultdict(set)
    for patch, member in zip(patches, members, strict=True):
        for line in patch.read_text(
            encoding="utf-8", errors="surrogateescape"
        ).splitlines():
            match = DIFF_HEADER.fullmatch(line)
            if match is None:
                continue
            before, after = match.groups()
            if before != after:
                raise ManifestError(
                    f"{patch.name}: rename-style diff path is unsupported: "
                    f"a/{before} -> b/{after}"
                )
            found[after].add(member)

    if not found:
        raise ManifestError(f"{patch_dir}: no diff paths found")
    return PatchInventory(
        members_by_path={
            path: tuple(sorted(path_members))
            for path, path_members in sorted(found.items())
        }
    )


def _parse_classification(path: str, classification: str, line: int) -> None:
    is_source_path = path in SOURCE_FILES or path.startswith(SOURCE_ROOTS)
    if classification == "SOURCE":
        if not is_source_path:
            raise ManifestError(
                f"{MANIFEST}:{line}: SOURCE path is outside the island roots: {path}"
            )
        return
    if classification == "INTEGRATION":
        if is_source_path:
            raise ManifestError(
                f"{MANIFEST}:{line}: island-owned path cannot be INTEGRATION: {path}"
            )
        return
    if classification.startswith("DROP:") and classification.removeprefix("DROP:"):
        return
    raise ManifestError(
        f"{MANIFEST}:{line}: class must be SOURCE, INTEGRATION, or DROP:<reason>"
    )


def parse_manifest(path: Path = MANIFEST) -> tuple[ManifestEntry, ...]:
    """Parse the TSV boundary and reject malformed or duplicate rows."""
    lines = path.read_text(encoding="utf-8").splitlines()
    data = [
        (number, raw)
        for number, raw in enumerate(lines, start=1)
        if raw and not raw.startswith("#")
    ]
    if not data or tuple(data[0][1].split("\t")) != HEADER:
        raise ManifestError(f"{path}: expected TSV header {'/'.join(HEADER)}")

    entries: list[ManifestEntry] = []
    seen: set[str] = set()
    for number, raw in data[1:]:
        cells = raw.split("\t")
        if len(cells) != len(HEADER):
            raise ManifestError(f"{path}:{number}: expected exactly three TSV columns")
        manifest_path, classification, member_text = cells
        if manifest_path in seen:
            raise ManifestError(f"{path}:{number}: duplicate path: {manifest_path}")
        if MEMBER_LIST.fullmatch(member_text) is None:
            raise ManifestError(f"{path}:{number}: malformed member list: {member_text}")
        members = tuple(member_text.split(","))
        if members != tuple(sorted(set(members))):
            raise ManifestError(f"{path}:{number}: members are not unique and sorted")
        _parse_classification(manifest_path, classification, number)
        entries.append(ManifestEntry(manifest_path, classification, members))
        seen.add(manifest_path)
    return tuple(entries)


def verify_manifest(
    patch_dir: Path, manifest_path: Path = MANIFEST
) -> tuple[str, ...]:
    """Return every disagreement between the patch union and the manifest."""
    inventory = collect_patch_inventory(patch_dir).members_by_path
    entries = {entry.path: entry for entry in parse_manifest(manifest_path)}
    problems = [
        f"{path}: appears in the fwport series but has no manifest class"
        for path in sorted(set(inventory) - set(entries))
    ]
    problems.extend(
        f"{path}: manifest row is stale; no fwport member touches it"
        for path in sorted(set(entries) - set(inventory))
    )
    for path in sorted(set(inventory) & set(entries)):
        if inventory[path] != entries[path].members:
            problems.append(
                f"{path}: members are {','.join(entries[path].members)} in the manifest, "
                f"but {','.join(inventory[path])} in the patch record"
            )
    return tuple(problems)


def _write_fixture_series(root: Path) -> Path:
    patch_dir = root / "patches"
    patch_dir.mkdir()
    for member in EXPECTED_MEMBERS:
        body = ""
        if member == "0001":
            body = (
                "diff --git a/drivers/video/rockchip/mpp/a.c "
                "b/drivers/video/rockchip/mpp/a.c\n"
            )
        (patch_dir / f"rk3588-fwport-{member}-fixture.patch").write_text(
            body, encoding="utf-8"
        )
    return patch_dir


def _self_test() -> int:
    failures: list[str] = []

    def check(name: str, condition: bool) -> None:
        print(f"  [{'ok' if condition else 'FAIL'}] {name}")
        if not condition:
            failures.append(name)

    print("self_test=import-manifest")
    with tempfile.TemporaryDirectory() as scratch:
        root = Path(scratch)
        patch_dir = _write_fixture_series(root)
        manifest = root / "manifest.tsv"
        manifest.write_text(
            "path\tclass\tmembers\n"
            "drivers/video/rockchip/mpp/a.c\tSOURCE\t0001\n",
            encoding="utf-8",
        )
        check("a closed manifest passes", not verify_manifest(patch_dir, manifest))

        manifest.write_text("path\tclass\tmembers\n", encoding="utf-8")
        check(
            "an unclassified diff path fails",
            any("no manifest class" in item for item in verify_manifest(patch_dir, manifest)),
        )

        manifest.write_text(
            "path\tclass\tmembers\n"
            "drivers/video/rockchip/mpp/a.c\tSOURCE\t0002\n",
            encoding="utf-8",
        )
        check(
            "a wrong member census fails",
            any("members are" in item for item in verify_manifest(patch_dir, manifest)),
        )

        next(patch_dir.glob("rk3588-fwport-0097-*.patch")).unlink()
        try:
            collect_patch_inventory(patch_dir)
        except ManifestError as error:
            check("a non-contiguous series fails", "missing=0097" in str(error))
        else:
            check("a non-contiguous series fails", False)

    if failures:
        print(f"FAIL: {len(failures)} self-test case(s) failed")
        return 1
    print("PASS: self-test")
    return 0


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--patch-dir", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv[1:])
    if args.self_test:
        return _self_test()
    if args.patch_dir is None:
        parser.error("--patch-dir is required unless --self-test is used")

    try:
        problems = verify_manifest(args.patch_dir)
    except (ManifestError, OSError) as error:
        print(f"FAIL: {error}")
        return 1
    if problems:
        print("FAIL: import manifest does not cover the pinned fwport series.")
        for problem in problems:
            print(f"  {problem}")
        return 1
    entries = parse_manifest()
    classes = {entry.classification.split(":", maxsplit=1)[0] for entry in entries}
    print(
        f"OK: {len(entries)} unique diff path(s) across 97 members; "
        f"classes={','.join(sorted(classes))}; none unclassified."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
