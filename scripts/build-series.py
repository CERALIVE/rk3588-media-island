#!/usr/bin/env python3
"""Generate the island's `git am` mailbox series from source.

WHY THIS EXISTS
---------------
The island is a SOURCE repository. `drivers/video/rockchip/{mpp,rga3}/`,
`include/uapi/linux/` and `integration/` are the truth; `patches/` is an OUTPUT,
exactly like a compiled binary. `rk3588-kernel-patches` consumes the generated
series byte-preserved into its `island/` lane, so the series has to be a real
mailbox `git am` accepts -- not a tarball and not a directory listing.

That inverts the usual relationship: hand-editing `patches/` is a DEFECT rather
than a shortcut, and `--check` is what makes it a red build instead of a silent
divergence.

TWO PATCH CLASSES, AND THEY ARE NOT INTERCHANGEABLE
---------------------------------------------------
* SOURCE -- every tracked kernel source file under the island roots, emitted as
  ONE create-mode patch. These files do not exist in mainline, so the only
  honest diff for them is `/dev/null` -> file.
* INTEGRATION -- `integration/*.patch`, which are diffs against files mainline
  ALREADY has (device-tree hunks, IOMMU provider exports). Their payload is
  carried byte-for-byte; this script only wraps a mail header around it. A
  generator that rewrote an integration hunk would be silently re-authoring a
  change to somebody else's file.

`integration/pending/` is deliberately NOT part of the series. A pending hunk is
linted but does not ship (the RGA flip stages both its DT patches there until the
release that applies them).

DETERMINISM IS A CONTRACT, NOT A NICETY
---------------------------------------
`--check` regenerates into a temp directory and byte-compares, so the generator
may read NOTHING that varies between two runs of the same tree: no clock, no
environment, no `git` invocation, no filesystem order. The author and date below
are therefore fixed constants.

`From:` is the COLLECTION identity, and that is the point. Per-file provenance
lives in `docs/PROVENANCE.md` and in each commit's `Origin:` trailer; stamping a
vendor-imported file with a CeraLive individual's name in the mailbox header
would be a provenance claim this repository explicitly refuses to make.

AN EMPTY SERIES IS A VALID SERIES
---------------------------------
Until the driver import lands, the island roots hold no kernel source and
`integration/` holds no patch, so the generated series is EMPTY: `patches/series`
exists and is empty, and there are no patch files. That is the honest output for
an empty source tree, and it is still checkable -- a stray file dropped into
`patches/` fails `--check` as an orphan, and so does a hand-edited `series`.

Usage
-----
    scripts/build-series.py             regenerate patches/
    scripts/build-series.py --check     rebuild into a temp dir and byte-compare
    scripts/build-series.py --self-test prove the generator on a synthetic tree
"""

from __future__ import annotations

import argparse
import filecmp
import hashlib
import shutil
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

PATCHES_DIR = ROOT / "patches"
INTEGRATION_DIR = ROOT / "integration"
SERIES_FILE_NAME = "series"

# The island roots. A file outside these is not island source, however much it
# looks like kernel code -- `tests/` and `scripts/` are repository tooling and
# have no business in a kernel series.
SOURCE_ROOTS = (
    "drivers/video/rockchip/mpp",
    "drivers/video/rockchip/rga3",
    "include/uapi/linux",
)

# What counts as kernel source. Extension-or-exact-name rather than "everything
# that is not excluded": an allowlist cannot accidentally ship a stray editor
# backup or a scratch file into a kernel the device boots.
SOURCE_SUFFIXES = (".c", ".h", ".S")
SOURCE_EXACT_NAMES = ("Kconfig", "Makefile")

# Scaffolding, never series content.
IGNORED_NAMES = (".gitkeep",)

# Mailbox identity. Fixed, because `--check` byte-compares.
SERIES_AUTHOR = "CeraLive <dev@ceralive.tv>"
SERIES_DATE = "Wed, 2 Sep 2026 00:00:00 +0000"

# The mbox delimiter hex. There is no originating commit for a generated
# collection patch, so this is the null object id -- the same choice the sibling
# patch repository makes for its first-party lane. It is never a borrowed SHA.
NULL_OID = "0" * 40

# git's own canonical mailbox epoch line. `git am` keys its format detection on
# the `From <hex> ` prefix; the date that follows is decorative and constant.
MBOX_EPOCH = "Mon Sep 17 00:00:00 2001"

# The trailing signature `git format-patch` writes. Kept because `git am`
# strips everything after it, so a consumer appending notes cannot corrupt a
# patch body.
SERIES_SIGNATURE = "2.51.0"

SOURCE_PATCH_SLUG = "rk3588-media-island-drivers"


class SeriesError(RuntimeError):
    """A generated series would be wrong, or the tree it came from is."""


@dataclass(frozen=True)
class SourceFile:
    """One island source file, addressed by its kernel-tree path."""

    path: str  # repo-relative == kernel-tree-relative, by construction
    text: str
    executable: bool


@dataclass(frozen=True)
class PatchEntry:
    """One generated mailbox file."""

    filename: str
    subject: str
    body: tuple[str, ...]  # description paragraphs, above the `---`
    payload: str  # the diff, byte-exact for INTEGRATION entries


def _is_source_name(name: str) -> bool:
    if name in IGNORED_NAMES:
        return False
    if name in SOURCE_EXACT_NAMES:
        return True
    return name.endswith(SOURCE_SUFFIXES)


def collect_sources(root: Path) -> list[SourceFile]:
    """Every island source file, in stable path order."""
    found: list[SourceFile] = []
    for source_root in SOURCE_ROOTS:
        base = root / source_root
        if not base.is_dir():
            continue
        for candidate in sorted(base.rglob("*")):
            if not candidate.is_file() or not _is_source_name(candidate.name):
                continue
            relative = candidate.relative_to(root).as_posix()
            found.append(
                SourceFile(
                    path=relative,
                    text=candidate.read_text(encoding="utf-8", errors="surrogateescape"),
                    executable=candidate.stat().st_mode & 0o111 != 0,
                )
            )
    found.sort(key=lambda entry: entry.path)
    return found


def blob_id(text: str) -> str:
    """The git blob object id of `text`, so the index line is real."""
    raw = text.encode("utf-8", errors="surrogateescape")
    header = f"blob {len(raw)}\0".encode()
    return hashlib.sha1(header + raw).hexdigest()  # noqa: S324 - git's own object id


def create_mode_diff(entry: SourceFile) -> list[str]:
    """A `/dev/null` -> file diff in git's create-mode shape."""
    mode = "100755" if entry.executable else "100644"
    lines = entry.text.split("\n")
    trailing_newline = lines and lines[-1] == ""
    if trailing_newline:
        lines = lines[:-1]

    out = [
        f"diff --git a/{entry.path} b/{entry.path}",
        f"new file mode {mode}",
        f"index 0000000000000000000000000000000000000000..{blob_id(entry.text)}",
        "--- /dev/null",
        f"+++ b/{entry.path}",
        f"@@ -0,0 +1,{len(lines)} @@",
    ]
    out.extend(f"+{line}" for line in lines)
    if not trailing_newline and lines:
        out.append("\\ No newline at end of file")
    return out


def split_integration(raw: str, filename: str) -> tuple[str, list[str], str]:
    """Split an `integration/` patch into (subject, description, payload).

    The payload starts at the first `diff --git` line and is carried onward
    VERBATIM. Everything above it is prose the author wrote to explain the hunk,
    optionally opening with a `Subject:` line.
    """
    lines = raw.split("\n")
    payload_start = None
    for index, line in enumerate(lines):
        if line.startswith("diff --git "):
            payload_start = index
            break
    if payload_start is None:
        raise SeriesError(
            f"integration/{filename}: no `diff --git` line -- an integration patch "
            "must be a git-format diff against a mainline file"
        )

    preamble = lines[:payload_start]
    subject = ""
    description: list[str] = []
    for line in preamble:
        if not subject and line.startswith("Subject:"):
            subject = line[len("Subject:") :].strip()
            continue
        description.append(line)

    if not subject:
        subject = subject_from_filename(filename)

    while description and not description[0].strip():
        description.pop(0)
    while description and not description[-1].strip():
        description.pop()

    payload = "\n".join(lines[payload_start:])
    return subject, description, payload


def subject_from_filename(filename: str) -> str:
    """`0010-arm64-dts-rk3588-mpp-nodes.patch` -> a readable subject."""
    stem = filename[: -len(".patch")] if filename.endswith(".patch") else filename
    parts = stem.split("-")
    if parts and parts[0].isdigit():
        parts = parts[1:]
    return " ".join(parts) if parts else stem


def collect_integration(root: Path) -> list[tuple[str, str]]:
    """`integration/*.patch` in lexical (apply) order. `pending/` is excluded."""
    base = root / "integration"
    if not base.is_dir():
        return []
    return [
        (path.name, path.read_text(encoding="utf-8", errors="surrogateescape"))
        for path in sorted(base.glob("*.patch"))
    ]


def build_entries(root: Path) -> list[PatchEntry]:
    sources = collect_sources(root)
    integration = collect_integration(root)

    entries: list[PatchEntry] = []
    ordinal = 0

    if sources:
        ordinal += 1
        payload_lines: list[str] = []
        for source in sources:
            payload_lines.extend(create_mode_diff(source))
        entries.append(
            PatchEntry(
                filename=f"{ordinal:04d}-{SOURCE_PATCH_SLUG}.patch",
                subject="video: rockchip: add the CeraLive RK3588 media island",
                body=(
                    "The Rockchip MPP service with its three compiled clients "
                    "(RKVENC2, RKVDEC2, JPGDEC), the multi_rga 2D engine driver, "
                    "and the UAPI headers they publish.",
                    "",
                    f"{len(sources)} file(s), added under paths mainline does not "
                    "carry, so every hunk is a create-mode diff.",
                    "",
                    "GENERATED from the rk3588-media-island source tree by "
                    "scripts/build-series.py. The source is the truth and this "
                    "series is its output; per-file provenance is docs/PROVENANCE.md "
                    "and the originating commits' Origin: trailers, never this "
                    "mailbox header.",
                ),
                payload="\n".join(payload_lines),
            )
        )

    for filename, raw in integration:
        ordinal += 1
        subject, description, payload = split_integration(raw, filename)
        entries.append(
            PatchEntry(
                filename=f"{ordinal:04d}-{filename[:-len('.patch')].lstrip('0123456789-')}.patch"
                if filename.endswith(".patch")
                else f"{ordinal:04d}-{filename}.patch",
                subject=subject,
                body=(
                    *description,
                    "",
                    "Patches a file mainline already carries. The payload below is "
                    f"carried byte-for-byte from integration/{filename}; "
                    "scripts/build-series.py adds the mail header and nothing else, "
                    "and scripts/verify-series-parity.py proves that independently.",
                ),
                payload=payload,
            )
        )

    return entries


def render(entry: PatchEntry, ordinal: int, total: int) -> str:
    header = [
        f"From {NULL_OID} {MBOX_EPOCH}",
        f"From: {SERIES_AUTHOR}",
        f"Date: {SERIES_DATE}",
        f"Subject: [PATCH {ordinal}/{total}] {entry.subject}",
        "",
        *entry.body,
        "",
        "---",
    ]
    payload = entry.payload.rstrip("\n")
    trailer = ["-- ", SERIES_SIGNATURE, ""]
    return "\n".join([*header, payload, *trailer])


def write_series(root: Path, destination: Path) -> list[str]:
    entries = build_entries(root)
    total = len(entries)

    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)

    names: list[str] = []
    for index, entry in enumerate(entries, start=1):
        (destination / entry.filename).write_text(
            render(entry, index, total), encoding="utf-8", errors="surrogateescape"
        )
        names.append(entry.filename)

    series_body = "".join(f"{name}\n" for name in names)
    (destination / SERIES_FILE_NAME).write_text(series_body, encoding="utf-8")
    return names


def compare_trees(generated: Path, committed: Path) -> list[str]:
    """Every difference between the two trees, as human-readable reasons."""
    if not committed.is_dir():
        return [f"{committed.name}/ does not exist -- run scripts/build-series.py"]

    want = {path.name for path in generated.iterdir()}
    have = {path.name for path in committed.iterdir()}

    problems = [f"{name}: missing from patches/" for name in sorted(want - have)]
    problems += [
        f"{name}: present in patches/ but not generated from source "
        "(hand-added, or its source was removed)"
        for name in sorted(have - want)
    ]
    for name in sorted(want & have):
        if not filecmp.cmp(generated / name, committed / name, shallow=False):
            problems.append(f"{name}: differs from what the source generates")
    return problems


def run_check(root: Path) -> int:
    with tempfile.TemporaryDirectory() as scratch:
        generated = Path(scratch) / "patches"
        names = write_series(root, generated)
        problems = compare_trees(generated, root / "patches")

    if problems:
        print("FAIL: patches/ is not what the source generates.")
        for problem in problems:
            print(f"  {problem}")
        print()
        print("patches/ is GENERATED. Change drivers/ or integration/, then run")
        print("scripts/build-series.py -- never the other way round.")
        return 1

    if not names:
        print(
            "OK: patches/ matches the source. NO-SOURCE-YET -- the island roots hold "
            "no kernel source and integration/ holds no patch, so the series is "
            "empty by construction. It becomes a real series when the driver import "
            "lands; the check is already live and an orphan in patches/ fails it now."
        )
    else:
        print(f"OK: patches/ matches the source ({len(names)} patch(es)).")
    return 0


def _self_test() -> int:
    """Prove the generator on a synthetic tree, with no island source present.

    Non-vacuity: the real tree is empty today, so a green `--check` proves only
    that nothing generates nothing. These cases exercise the paths that will
    carry real content, and each of them fails if its half of the generator is
    removed.
    """
    failures: list[str] = []

    def check(name: str, condition: bool) -> None:
        status = "ok" if condition else "FAIL"
        print(f"  [{status}] {name}")
        if not condition:
            failures.append(name)

    print("self_test=build-series")
    with tempfile.TemporaryDirectory() as scratch:
        fake = Path(scratch) / "island"
        source_dir = fake / "drivers/video/rockchip/mpp"
        source_dir.mkdir(parents=True)
        (source_dir / "mpp_service.c").write_text("int probe(void);\n", encoding="utf-8")
        (source_dir / ".gitkeep").write_text("", encoding="utf-8")
        (fake / "integration").mkdir(parents=True)
        (fake / "integration" / "0002-iommu-exports.patch").write_text(
            "Subject: iommu: rockchip: export provider control\n"
            "\n"
            "Needed by mpp_iommu.c.\n"
            "\n"
            "diff --git a/drivers/iommu/rockchip-iommu.c b/drivers/iommu/rockchip-iommu.c\n"
            "--- a/drivers/iommu/rockchip-iommu.c\n"
            "+++ b/drivers/iommu/rockchip-iommu.c\n"
            "@@ -1,1 +1,2 @@\n"
            " static int rk_iommu_enable(void)\n"
            "+EXPORT_SYMBOL(rockchip_iommu_enable);\n",
            encoding="utf-8",
        )
        (fake / "integration" / "pending").mkdir()
        (fake / "integration" / "pending" / "0020-rga.patch").write_text(
            "diff --git a/x b/x\n", encoding="utf-8"
        )

        first = Path(scratch) / "out-a"
        second = Path(scratch) / "out-b"
        names = write_series(fake, first)
        write_series(fake, second)

        check("a source file and an integration patch make two entries", len(names) == 2)
        check(
            "the source patch comes first",
            bool(names) and names[0].startswith("0001-"),
        )
        check("two runs of one tree are byte-identical", not compare_trees(first, second))

        source_patch = (first / names[0]).read_text(encoding="utf-8")
        check(
            "an island file is a create-mode hunk",
            "new file mode 100644" in source_patch
            and "--- /dev/null" in source_patch
            and "+int probe(void);" in source_patch,
        )
        check(".gitkeep is not series content", ".gitkeep" not in source_patch)
        check(
            "the mailbox is git-am shaped",
            source_patch.startswith(f"From {NULL_OID} {MBOX_EPOCH}\n")
            and "\nSubject: [PATCH 1/2] " in source_patch
            and source_patch.endswith(f"-- \n{SERIES_SIGNATURE}\n"),
        )

        integration_patch = (first / names[1]).read_text(encoding="utf-8")
        check(
            "an integration payload is carried byte-for-byte",
            "+EXPORT_SYMBOL(rockchip_iommu_enable);\n" in integration_patch,
        )
        check(
            "an explicit Subject: wins over the filename",
            "Subject: [PATCH 2/2] iommu: rockchip: export provider control"
            in integration_patch,
        )
        check(
            "integration/pending/ does not ship",
            all("rga" not in name for name in names),
        )

        series_text = (first / SERIES_FILE_NAME).read_text(encoding="utf-8")
        check(
            "series lists every patch in apply order",
            series_text == "".join(f"{name}\n" for name in names),
        )

        # A hand-edit is what --check exists to catch.
        (second / names[0]).write_text("tampered\n", encoding="utf-8")
        check("a hand-edited patch is detected", bool(compare_trees(first, second)))
        (second / "0099-invented.patch").write_text("x\n", encoding="utf-8")
        check(
            "an orphan file in patches/ is detected",
            any("0099-invented" in problem for problem in compare_trees(first, second)),
        )

        # An empty tree is a valid, empty series -- not an error.
        empty = Path(scratch) / "empty-island"
        empty.mkdir()
        empty_out = Path(scratch) / "out-empty"
        check("an empty source tree yields an empty series", not write_series(empty, empty_out))
        check(
            "an empty series still writes the series file",
            (empty_out / SERIES_FILE_NAME).read_text(encoding="utf-8") == "",
        )

        # A malformed integration patch must fail closed.
        broken = Path(scratch) / "broken-island"
        (broken / "integration").mkdir(parents=True)
        (broken / "integration" / "0001-prose.patch").write_text(
            "just words\n", encoding="utf-8"
        )
        try:
            build_entries(broken)
        except SeriesError:
            check("an integration file with no diff fails closed", True)
        else:
            check("an integration file with no diff fails closed", False)

    if failures:
        print(f"FAIL: {len(failures)} self-test case(s) failed")
        return 1
    print("PASS: self-test")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="regenerate into a temp dir and byte-compare against patches/",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="prove the generator against a synthetic island tree",
    )
    args = parser.parse_args(argv[1:])

    if args.self_test:
        return _self_test()

    try:
        if args.check:
            return run_check(ROOT)
        names = write_series(ROOT, PATCHES_DIR)
    except SeriesError as error:
        print(f"FAIL: {error}")
        return 1

    print(f"Wrote {len(names)} patch(es) + {SERIES_FILE_NAME} to patches/.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
