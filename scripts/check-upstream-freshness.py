#!/usr/bin/env python3
"""Report new path-scoped Rockchip media commits without changing a pin."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import tempfile
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Final

ROOT: Final = Path(__file__).resolve().parent.parent
REFERENCES: Final = ROOT / "docs" / "REFERENCES.md"
EXIT_CURRENT: Final = 0
EXIT_BEHIND: Final = 10
EXIT_ERROR: Final = 2
SHA: Final = re.compile(r"\b([0-9a-f]{40})\b")
WATCH_PATHS: Final = (
    "drivers/video/rockchip/mpp",
    "drivers/video/rockchip/rga3",
    "include/uapi/linux/rk-mpp.h",
)


@dataclass(frozen=True, slots=True)
class Target:
    label: str
    url: str
    ref: str
    reference_row: str
    paths: tuple[str, ...] = WATCH_PATHS


@dataclass(frozen=True, slots=True)
class Commit:
    sha: str
    date: str
    subject: str


@dataclass(frozen=True, slots=True)
class Movement:
    target: Target
    pinned: str
    head: str
    commits: tuple[Commit, ...]


WATCHED: Final = (
    Target(
        "rockchip-linux/kernel develop-6.1",
        "https://github.com/rockchip-linux/kernel.git",
        "refs/heads/develop-6.1",
        "Vendor backlog review baseline",
    ),
    Target(
        "armbian/linux-rockchip rk-6.1-rkr6.1 mirror",
        "https://github.com/armbian/linux-rockchip.git",
        "refs/heads/rk-6.1-rkr6.1",
        "Armbian rkr6.1 media-watch baseline",
    ),
    Target(
        "armbian/linux-rockchip rk-6.1-rkr7.2 mirror",
        "https://github.com/armbian/linux-rockchip.git",
        "refs/heads/rk-6.1-rkr7.2",
        "Armbian rkr7.2 media-watch baseline",
    ),
)


@dataclass(frozen=True, slots=True)
class FreshnessError(RuntimeError):
    detail: str

    def __str__(self) -> str:
        return self.detail


def pinned_shas(doc: Path) -> dict[str, str]:
    if not doc.is_file():
        raise FreshnessError(f"{doc} is missing")
    found: dict[str, str] = {}
    for line in doc.read_text(encoding="utf-8").splitlines():
        if not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        match = SHA.search(cells[-1])
        if match:
            found[cells[0]] = match.group(1)
    return found


def run(command: list[str], cwd: Path | None = None) -> str:
    try:
        result = subprocess.run(
            command,
            cwd=cwd,
            capture_output=True,
            text=True,
            check=True,
            timeout=600,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise FreshnessError(f"command failed: {' '.join(command)}: {error}") from error
    return result.stdout


def resolve(target: Target, pinned: str) -> Movement:
    remote = run(["git", "ls-remote", target.url, target.ref]).strip().split()
    if not remote:
        raise FreshnessError(f"{target.url} has no {target.ref}")
    head = remote[0]
    if head == pinned:
        return Movement(target, pinned, head, ())

    with tempfile.TemporaryDirectory(prefix="island-upstream-watch-") as directory:
        checkout = Path(directory) / "kernel"
        run(
            [
                "git",
                "clone",
                "--filter=blob:none",
                "--no-checkout",
                "--single-branch",
                "--shallow-since=2025-12-25",
                "--branch",
                target.ref.removeprefix("refs/heads/"),
                target.url,
                str(checkout),
            ]
        )
        try:
            run(["git", "cat-file", "-e", f"{pinned}^{{commit}}"], checkout)
        except FreshnessError:
            run(["git", "fetch", "--depth=1", "origin", pinned], checkout)
        output = run(
            [
                "git",
                "log",
                "--reverse",
                "--format=%H|%as|%s",
                f"{pinned}..{head}",
                "--",
                *target.paths,
            ],
            checkout,
        )
    commits = tuple(
        Commit(*line.split("|", 2)) for line in output.splitlines() if line
    )
    return Movement(target, pinned, head, commits)


Resolver = Callable[[Target, str], Movement]


def compare(doc: Path, resolver: Resolver = resolve) -> tuple[Movement, ...]:
    pins = pinned_shas(doc)
    movements: list[Movement] = []
    for target in WATCHED:
        pinned = next(
            (sha for label, sha in pins.items() if label.startswith(target.reference_row)),
            None,
        )
        if pinned is None:
            raise FreshnessError(f"{doc} has no row starting {target.reference_row!r}")
        movement = resolver(target, pinned)
        if movement.commits:
            movements.append(movement)
    return tuple(movements)


def issue_body(movements: tuple[Movement, ...]) -> str:
    lines = [
        "The weekly media-path watch found new vendor or mirror commits.",
        "",
        "**Issue only:** no pin, source file, build, or pull request was changed.",
        "",
        "Watched paths are exactly:",
        *[f"- `{path}`" for path in WATCH_PATHS],
        "",
    ]
    for movement in movements:
        lines.extend(
            [
                f"## {movement.target.label}",
                "",
                f"`{movement.pinned}` → `{movement.head}`",
                "",
                "| Commit | Date | Subject |",
                "|---|---|---|",
                *[
                    f"| `{commit.sha}` | {commit.date} | {commit.subject} |"
                    for commit in movement.commits
                ],
                "",
            ]
        )
    lines.append("A human must classify every row in `docs/VENDOR-BACKLOG.md`.")
    return "\n".join(lines) + "\n"


def self_test() -> int:
    failures: list[str] = []

    def check(name: str, condition: bool) -> None:
        print(f"  [{'ok' if condition else 'FAIL'}] {name}")
        if not condition:
            failures.append(name)

    check(
        "three vendor branches share the exact media path scope",
        len(WATCHED) == 3 and all(target.paths == WATCH_PATHS for target in WATCHED),
    )

    def current(target: Target, pinned: str) -> Movement:
        return Movement(target, pinned, pinned, ())

    check("no path commits reports current", not compare(REFERENCES, current))

    def one_moved(target: Target, pinned: str) -> Movement:
        commits = (
            (Commit("f" * 40, "2026-09-03", "fixture media fix"),)
            if target == WATCHED[0]
            else ()
        )
        return Movement(target, pinned, "e" * 40, commits)

    moved = compare(REFERENCES, one_moved)
    body = issue_body(moved)
    check("one path movement produces one report", len(moved) == 1)
    check("fixture commit is rendered", "fixture media fix" in body)
    check("all exact watched paths are rendered", all(path in body for path in WATCH_PATHS))
    check("report remains issue-only", "Issue only" in body and "pull request" in body)
    if failures:
        print(f"FAIL: {len(failures)} self-test case(s) failed")
        return 1
    print("PASS: self-test")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--issue-body", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv[1:])
    if args.self_test:
        return self_test()
    try:
        movements = compare(REFERENCES)
    except FreshnessError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return EXIT_ERROR
    if not movements:
        print("current: no new commits touch the watched media paths")
        return EXIT_CURRENT
    if args.issue_body:
        args.issue_body.write_text(issue_body(movements), encoding="utf-8")
    return EXIT_BEHIND


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
