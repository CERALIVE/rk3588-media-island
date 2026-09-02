#!/usr/bin/env python3
"""Has an upstream the island is pinned to moved? Report only -- never act.

`docs/REFERENCES.md` anchors the island to immutable objects. Upstream keeps
moving anyway, and the risk is not that a pin goes stale -- it is that nobody
notices for six months and the next rebase is a cliff instead of a step.

ISSUE-ONLY, BY DESIGN. This script and the workflow that runs it never edit
`docs/REFERENCES.md`, never open a pull request, and never dispatch a build.
Bumping a pin means re-reading the series, re-running the shim census and
re-verifying the licence inventory; a robot that moved a SHA would be asserting
it had done all three. A human decides every bump, exactly as the sibling
modem-stack watch decides every ModemManager bump.

EXIT CODES
----------
    0   every watched upstream is still at its pinned object
    10  at least one has moved -- the workflow opens or updates ONE issue
    >0  the check could not complete; the workflow fails loudly rather than
        reporting "current", because a silent watch reads exactly like an
        up-to-date one

Usage
-----
    scripts/check-upstream-freshness.py [--issue-body PATH]
    scripts/check-upstream-freshness.py --self-test
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REFERENCES = ROOT / "docs" / "REFERENCES.md"

EXIT_CURRENT = 0
EXIT_BEHIND = 10
EXIT_ERROR = 2

SHA = re.compile(r"\b([0-9a-f]{40})\b")


@dataclass(frozen=True)
class Watched:
    """One upstream, its pinned object, and what a move would mean here."""

    label: str
    url: str
    ref: str
    reference_row: str
    consequence: str


# The paths the later cherry-pick step draws from are what make these two the
# ones worth watching: `rock-5b-ysp` carries the forward-port patch record and
# `linux-rock5b` carries the tree it exports. A move in either is a candidate
# for the island's own series; a move anywhere else in those repositories is not.
WATCHED = (
    Watched(
        label="yisding/rock-5b-ysp (forward-port patch record)",
        url="https://github.com/yisding/rock-5b-ysp.git",
        ref="refs/heads/main",
        reference_row="Forward-port patch record",
        consequence=(
            "new or revised members under "
            "`kernel-drivers/patches/forward-port-rk3588/` are the input the "
            "island's later cherry-pick step reads. Review the diff before "
            "moving the pin; a new member may be a fix the island already "
            "carries, or one it must adopt."
        ),
    ),
    Watched(
        label="yisding/linux-rock5b (realized maintained series)",
        url="https://github.com/yisding/linux-rock5b.git",
        ref="refs/heads/rk3588-video-6.18",
        reference_row="Realized maintained series",
        consequence=(
            "the branch tip the patch record exports from. It moving without "
            "the patch record moving means the export is stale upstream, which "
            "is worth knowing before trusting either."
        ),
    ),
)


class FreshnessError(RuntimeError):
    """The check could not be completed, so it reports nothing."""


def pinned_shas(doc: Path) -> dict[str, str]:
    """`REFERENCES.md` row label -> the 40-hex object it pins."""
    if not doc.is_file():
        raise FreshnessError(f"{doc} is missing -- there are no pins to compare")
    found: dict[str, str] = {}
    for raw in doc.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if len(cells) < 2:
            continue
        match = SHA.search(cells[-1])
        if match:
            found[cells[0]] = match.group(1)
    if not found:
        raise FreshnessError(f"{doc} pins no 40-character object at all")
    return found


def resolve(url: str, ref: str) -> str:
    try:
        result = subprocess.run(
            ["git", "ls-remote", url, ref],
            capture_output=True,
            text=True,
            check=True,
            timeout=120,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise FreshnessError(f"could not resolve {ref} in {url}: {error}") from error
    line = result.stdout.strip().split("\n")[0]
    if not line:
        raise FreshnessError(f"{url} has no {ref}")
    return line.split()[0]


def compare(
    doc: Path, resolver=resolve
) -> tuple[list[tuple[Watched, str, str]], list[Watched]]:
    pins = pinned_shas(doc)
    moved: list[tuple[Watched, str, str]] = []
    current: list[Watched] = []

    for entry in WATCHED:
        pinned = next(
            (sha for label, sha in pins.items() if label.startswith(entry.reference_row)),
            None,
        )
        if pinned is None:
            raise FreshnessError(
                f"{doc} has no row starting '{entry.reference_row}' -- the watch "
                "cannot compare a pin it cannot find"
            )
        head = resolver(entry.url, entry.ref)
        if head != pinned:
            moved.append((entry, pinned, head))
        else:
            current.append(entry)
    return moved, current


def issue_body(moved: list[tuple[Watched, str, str]]) -> str:
    lines = [
        "The scheduled upstream watch found at least one pinned object behind its",
        "upstream branch tip.",
        "",
        "**This issue is a report. Nothing was changed.** `docs/REFERENCES.md` is",
        "untouched, no build was dispatched, and no pull request was opened —",
        "moving a pin means re-reading the series, re-running the shim census and",
        "re-verifying the licence inventory, and a robot cannot assert it did any",
        "of those. A human decides every bump.",
        "",
    ]
    for entry, pinned, head in moved:
        lines += [
            f"### {entry.label}",
            "",
            f"- watched ref: `{entry.ref}`",
            f"- pinned in `docs/REFERENCES.md`: `{pinned}`",
            f"- upstream tip: `{head}`",
            f"- compare: {entry.url[:-4]}/compare/{pinned}...{head}",
            "",
            f"Why it matters: {entry.consequence}",
            "",
        ]
    lines += [
        "---",
        "",
        "This issue is opened once and UPDATED on every later run, and closed",
        "automatically once every watched pin is current again. A second issue",
        "would train everyone to ignore both.",
    ]
    return "\n".join(lines) + "\n"


def _self_test() -> int:
    """Offline, through the resolver seam -- the watch must not need network."""
    failures: list[str] = []

    def check(name: str, condition: bool) -> None:
        print(f"  [{'ok' if condition else 'FAIL'}] {name}")
        if not condition:
            failures.append(name)

    print("self_test=check-upstream-freshness")

    pins = pinned_shas(REFERENCES)
    check("docs/REFERENCES.md pins objects", len(pins) >= 4)
    for entry in WATCHED:
        check(
            f"a pinned row exists for {entry.reference_row}",
            any(label.startswith(entry.reference_row) for label in pins),
        )

    pinned_values = {
        entry.reference_row: next(
            sha for label, sha in pins.items() if label.startswith(entry.reference_row)
        )
        for entry in WATCHED
    }

    def unchanged(url: str, ref: str) -> str:
        del ref
        entry = next(candidate for candidate in WATCHED if candidate.url == url)
        return pinned_values[entry.reference_row]

    moved, current = compare(REFERENCES, resolver=unchanged)
    check("an unmoved upstream reports current", not moved and len(current) == len(WATCHED))

    def one_moved(url: str, ref: str) -> str:
        if url == WATCHED[0].url:
            return "f" * 40
        return unchanged(url, ref)

    moved, current = compare(REFERENCES, resolver=one_moved)
    check("a moved upstream is reported", len(moved) == 1 and len(current) == 1)

    body = issue_body(moved)
    check("the issue body names the moved upstream", WATCHED[0].label in body)
    check("the issue body carries both objects", "f" * 40 in body)
    check(
        "the issue body states that nothing was changed",
        "Nothing was changed" in body and "no build was dispatched" in body,
    )

    def exploding(url: str, ref: str) -> str:
        del url, ref
        raise FreshnessError("network is down")

    try:
        compare(REFERENCES, resolver=exploding)
    except FreshnessError:
        check("an unresolvable upstream raises rather than reporting current", True)
    else:
        check("an unresolvable upstream raises rather than reporting current", False)

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
        return _self_test()

    try:
        moved, current = compare(REFERENCES)
    except FreshnessError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return EXIT_ERROR

    for entry in current:
        print(f"current: {entry.label} is still at its pinned object")
    for entry, pinned, head in moved:
        print(f"behind:  {entry.label} pinned {pinned[:12]}, upstream {head[:12]}")

    if not moved:
        return EXIT_CURRENT

    if args.issue_body:
        args.issue_body.write_text(issue_body(moved), encoding="utf-8")
    return EXIT_BEHIND


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
