#!/usr/bin/env python3
"""shim-lint: a compile can never succeed by stubbing a REAL-DEPENDENCY.

This implements, step for step, the "Todo-7 CI check specification" at the end of
`docs/COMPAT.md`. That document is the MACHINE-OWNED allow/deny list -- this
script parses its table rather than carrying a second copy of the symbol set, so
editing a row's `class` cell changes what compiles.

    1. Parse the table; collect every symbol whose class cell is exactly
       `REAL-DEPENDENCY`. Rows are taken individually; no wildcard is inferred.
    2. Scan every island-local compatibility header. A REAL-DEPENDENCY symbol may
       be DECLARED there, but may not be `static inline`, macro-defined, or given
       a function body. A body returning 0/false/NULL/ERR_PTR(...)/-ENODEV fails,
       and an empty `void` body fails too. This is STRUCTURAL -- the header is
       lexed, comments and literals are blanked, and the declarator is walked to
       its `{` or `;`. A return-text grep would miss `{ }` and would fire on a
       comment quoting the stub it warns about.
    3. Every REAL-DEPENDENCY must resolve to a NON-compat definition. The
       authoritative half of this is the LINK -- `cross-compile-modules` builds
       the modules against the pinned kernel with `integration/` applied, and an
       unresolved symbol is a modpost failure. This script runs the static half:
       a REAL-DEPENDENCY the island calls must have a definition site available
       (island non-compat source, or an `integration/` patch that exports it).
       Neither half alone is sufficient, which is why both exist.
    4. Independently reject any `<soc/rockchip/*.h>` include absent from the
       table, and any `rockchip_*` lexical-census symbol absent from the table,
       so source growth FAILS CLOSED until its semantics are classified.
    5. `--self-test` carries the specification's own negative fixture: a
       synthetic `static inline int rockchip_iommu_enable(struct device *dev)
       { return 0; }` must be named, cited to its REAL-DEPENDENCY row, and
       refused -- with a declared-only control that must pass.

Usage
-----
    scripts/check-compat-shims.py
    scripts/check-compat-shims.py --self-test
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COMPAT_DOC = ROOT / "docs" / "COMPAT.md"

ISLAND_SOURCE_ROOTS = (
    "drivers/video/rockchip/mpp",
    "drivers/video/rockchip/rga3",
    "include/uapi/linux",
)

REAL_DEPENDENCY = "REAL-DEPENDENCY"

# COMPAT.md's own required lexical command, as a regex: `rockchip_[a-z_]*(`,
# extended only to recurse and to tolerate whitespace before the parenthesis.
CENSUS = re.compile(r"\brockchip_[a-z0-9_]*(?=\s*\()")
SOC_INCLUDE = re.compile(r"#\s*include\s*[<\"](soc/rockchip/[A-Za-z0-9_./-]+\.h)[>\"]")
BACKTICKED = re.compile(r"`([^`]+)`")


class ShimLintError(RuntimeError):
    """The table itself could not be read; nothing downstream is trustworthy."""


@dataclass(frozen=True)
class TableRow:
    symbol: str
    klass: str
    line: int

    @property
    def is_header_row(self) -> bool:
        return self.symbol.endswith(".h")


# --------------------------------------------------------------------------
# Step 1 -- parse docs/COMPAT.md as the allow/deny list
# --------------------------------------------------------------------------


def parse_table(doc: Path) -> list[TableRow]:
    if not doc.is_file():
        raise ShimLintError(f"{doc} is missing -- shim-lint has no allow/deny list")

    rows: list[TableRow] = []
    symbol_index = class_index = None

    for number, raw in enumerate(doc.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw.strip()
        if not line.startswith("|"):
            symbol_index = class_index = None
            continue

        cells = [cell.strip() for cell in line.strip("|").split("|")]

        if symbol_index is None:
            # A header row names its own columns, so the column ORDER is read
            # rather than assumed. A positional index would silently read the
            # wrong cell the day a column is inserted.
            lowered = [cell.lower() for cell in cells]
            if "symbol" in lowered and any(cell.startswith("class") for cell in lowered):
                symbol_index = lowered.index("symbol")
                class_index = next(
                    index for index, cell in enumerate(lowered) if cell.startswith("class")
                )
            continue

        if all(set(cell) <= set("-: ") for cell in cells if cell):
            continue  # the ---|--- rule under the header
        if class_index is None or len(cells) <= max(symbol_index, class_index):
            continue

        symbol_cell = cells[symbol_index]
        match = BACKTICKED.search(symbol_cell)
        if match is None:
            continue
        rows.append(
            TableRow(symbol=match.group(1).strip(), klass=cells[class_index], line=number)
        )

    if not rows:
        raise ShimLintError(f"{doc} contains no shim table rows")
    return rows


def real_dependency_symbols(rows: list[TableRow]) -> dict[str, int]:
    """Function symbols classed exactly REAL-DEPENDENCY, name -> doc line."""
    return {
        row.symbol: row.line
        for row in rows
        if not row.is_header_row and row.klass == REAL_DEPENDENCY
    }


# --------------------------------------------------------------------------
# Step 2 -- structural detection of a body in a compat header
# --------------------------------------------------------------------------


def blank_comments_and_literals(text: str) -> str:
    """Replace comment and literal CONTENT with spaces, preserving offsets.

    Offsets are preserved so a finding can still report a real line number, and
    so a comment that quotes the very stub this lint forbids cannot trip it --
    which a plain grep over the raw text would do.
    """
    out = list(text)
    index = 0
    length = len(text)
    while index < length:
        char = text[index]
        if char == "/" and index + 1 < length and text[index + 1] == "*":
            end = text.find("*/", index + 2)
            end = length if end == -1 else end + 2
            for position in range(index, end):
                if out[position] != "\n":
                    out[position] = " "
            index = end
            continue
        if char == "/" and index + 1 < length and text[index + 1] == "/":
            end = text.find("\n", index)
            end = length if end == -1 else end
            for position in range(index, end):
                out[position] = " "
            index = end
            continue
        if char in "\"'":
            quote = char
            position = index + 1
            while position < length:
                if text[position] == "\\":
                    position += 2
                    continue
                if text[position] == quote:
                    position += 1
                    break
                position += 1
            for blank in range(index + 1, min(position - 1, length)):
                if out[blank] != "\n":
                    out[blank] = " "
            index = position
            continue
        index += 1
    return "".join(out)


def _matching_paren(text: str, open_index: int) -> int | None:
    depth = 0
    for index in range(open_index, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return index
    return None


def _declarator_start(text: str, name_index: int) -> int:
    for index in range(name_index - 1, -1, -1):
        if text[index] in ";}{":
            return index + 1
    return 0


def declarator_prefix(text: str, name_index: int) -> str:
    """The declarator text before `name`, with preprocessor lines removed.

    A header guard carries no `;`, so walking back from the first declaration in
    a file lands at byte 0 and drags `#ifndef`/`#define` into the prefix. That
    made `int rockchip_iommu_enable(struct device *dev);` read as a CALL rather
    than a prototype -- found by mutating a real compat header, not by review.
    """
    raw = text[_declarator_start(text, name_index) : name_index]
    lines = raw.split("\n")
    last_directive = max(
        (index for index, line in enumerate(lines) if line.lstrip().startswith("#")),
        default=-1,
    )
    return "\n".join(lines[last_directive + 1 :])


ATTRIBUTE_TAIL = re.compile(r"\s*(__attribute__\s*\([^;{]*\)|__always_inline|__maybe_unused)*\s*")


def classify_occurrence(text: str, name: str, name_index: int) -> str | None:
    """`macro` / `static-inline` / `body` for a bad occurrence, else None."""
    if re.search(r"#\s*define\s*$", text[_declarator_start(text, name_index) : name_index]):
        return "macro"
    prefix = declarator_prefix(text, name_index)

    open_index = text.find("(", name_index + len(name))
    if open_index == -1:
        return None
    close_index = _matching_paren(text, open_index)
    if close_index is None:
        return None

    tail = text[close_index + 1 :]
    trimmed = ATTRIBUTE_TAIL.match(tail)
    rest = tail[trimmed.end() :] if trimmed else tail.lstrip()
    has_body = rest.startswith("{")

    # `static inline` is refused whether or not a body follows: the spec names it
    # separately because a `static inline` declaration is a compat-header stub
    # waiting for a body, and the compile that follows would bind to it.
    is_static_inline = bool(re.search(r"\bstatic\b", prefix)) and bool(
        re.search(r"\binline\b", prefix)
    )

    if has_body and is_static_inline:
        return "static-inline"
    if has_body:
        return "body"
    if is_static_inline:
        return "static-inline"
    return None


def compat_headers(root: Path) -> list[Path]:
    """Every island-local compatibility header.

    Shims NEST at `drivers/video/rockchip/mpp/compat/`; a root-level `compat/`
    would move them out from under both the Makefile and this lint, so any
    `compat/` directory under the island roots is scanned rather than one exact
    path.
    """
    found: list[Path] = []
    for source_root in ISLAND_SOURCE_ROOTS:
        base = root / source_root
        if not base.is_dir():
            continue
        for candidate in sorted(base.rglob("*.h")):
            if "compat" in candidate.relative_to(base).parts:
                found.append(candidate)
    return found


def island_sources(root: Path) -> list[Path]:
    found: list[Path] = []
    for source_root in ISLAND_SOURCE_ROOTS:
        base = root / source_root
        if not base.is_dir():
            continue
        for candidate in sorted(base.rglob("*")):
            if candidate.is_file() and candidate.suffix in (".c", ".h", ".S"):
                found.append(candidate)
    return found


def scan_compat_bodies(root: Path, wanted: dict[str, int]) -> list[str]:
    problems: list[str] = []
    for header in compat_headers(root):
        raw = header.read_text(encoding="utf-8", errors="surrogateescape")
        text = blank_comments_and_literals(raw)
        relative = header.relative_to(root).as_posix()
        for name, doc_line in sorted(wanted.items()):
            for match in re.finditer(rf"\b{re.escape(name)}\b", text):
                verdict = classify_occurrence(text, name, match.start())
                if verdict is None:
                    continue
                line = text.count("\n", 0, match.start()) + 1
                reason = {
                    "macro": "is macro-defined",
                    "body": "is given a function body",
                    "static-inline": "is `static inline`",
                }[verdict]
                problems.append(
                    f"{relative}:{line}: `{name}` {reason} in a compat header. "
                    f"docs/COMPAT.md:{doc_line} classes it {REAL_DEPENDENCY}, so a "
                    "compat definition would let the build succeed against a stub "
                    "instead of the real provider."
                )
    return problems


# --------------------------------------------------------------------------
# Step 3 (static half) -- a called REAL-DEPENDENCY needs a real definition site
# --------------------------------------------------------------------------


def integration_exported_symbols(root: Path) -> set[str]:
    """Symbols an `integration/` patch adds as an export or a definition."""
    exported: set[str] = set()
    base = root / "integration"
    if not base.is_dir():
        return exported
    for path in sorted(base.rglob("*.patch")):
        for line in path.read_text(encoding="utf-8", errors="surrogateescape").splitlines():
            if not line.startswith("+"):
                continue
            for match in re.finditer(r"EXPORT_SYMBOL(?:_GPL)?\s*\(\s*([A-Za-z_]\w*)", line):
                exported.add(match.group(1))
            for match in CENSUS.finditer(line[1:]):
                if re.search(r"\b(?:int|void|bool|long|unsigned|struct)\b", line):
                    exported.add(match.group(0))
    return exported


# A declarator prefix that is a type and nothing else. `return`/`if`/... read as
# identifiers to a regex, so they are excluded by name -- otherwise
# `return rockchip_iommu_enable(dev);` would be filed as a prototype and the
# call site it really is would never be counted.
TYPE_PREFIX = re.compile(r"^[A-Za-z_][A-Za-z0-9_ \t*]*$")
STATEMENT_KEYWORDS = frozenset(
    {"return", "if", "while", "for", "switch", "case", "do", "else", "goto", "sizeof"}
)


def is_prototype(text: str, name_index: int) -> bool:
    """True when this occurrence declares the function rather than calling it."""
    stripped = " ".join(declarator_prefix(text, name_index).split())
    if not stripped:
        return False
    if TYPE_PREFIX.match(stripped) is None:
        return False
    last = stripped.replace("*", " ").split()
    return not (last and last[-1] in STATEMENT_KEYWORDS)


def scan_definition_sites(root: Path, wanted: dict[str, int]) -> list[str]:
    compat = {path.resolve() for path in compat_headers(root)}
    called: set[str] = set()
    defined_outside_compat: set[str] = set()

    for source in island_sources(root):
        text = blank_comments_and_literals(
            source.read_text(encoding="utf-8", errors="surrogateescape")
        )
        in_compat = source.resolve() in compat
        for match in CENSUS.finditer(text):
            name = match.group(0)
            if name not in wanted:
                continue
            verdict = classify_occurrence(text, name, match.start())
            if verdict is None and not is_prototype(text, match.start()):
                called.add(name)
            if in_compat:
                continue
            if verdict in ("body", "static-inline"):
                defined_outside_compat.add(name)

    exported = integration_exported_symbols(root)
    problems: list[str] = []
    for name in sorted(called - defined_outside_compat - exported):
        problems.append(
            f"`{name}` is called by island source and classed {REAL_DEPENDENCY} "
            f"(docs/COMPAT.md:{wanted[name]}), but nothing in the island's own "
            "non-compat source and no integration/ patch provides it. The link in "
            "cross-compile-modules is the authoritative half of this check; this "
            "static half exists so the gap is named before a 25-minute build."
        )
    return problems


# --------------------------------------------------------------------------
# Step 4 -- include and census closure
# --------------------------------------------------------------------------


def scan_closure(root: Path, rows: list[TableRow]) -> list[str]:
    header_rows = {row.symbol for row in rows if row.is_header_row}
    symbol_rows = {row.symbol for row in rows if not row.is_header_row}

    problems: list[str] = []
    for source in island_sources(root):
        relative = source.relative_to(root).as_posix()
        raw = source.read_text(encoding="utf-8", errors="surrogateescape")
        text = blank_comments_and_literals(raw)

        for number, line in enumerate(text.splitlines(), start=1):
            include = SOC_INCLUDE.search(line)
            if include and include.group(1) not in header_rows:
                problems.append(
                    f"{relative}:{number}: includes <{include.group(1)}>, which has "
                    "no row in docs/COMPAT.md. Classify it (STUB-SAFE or "
                    f"{REAL_DEPENDENCY}) before the build may consume it."
                )

        for match in CENSUS.finditer(text):
            name = match.group(0)
            if name in symbol_rows:
                continue
            number = text.count("\n", 0, match.start()) + 1
            problems.append(
                f"{relative}:{number}: `{name}` has no row in docs/COMPAT.md. The "
                "census is mechanically closed on purpose -- source growth fails "
                "closed until its semantics are classified."
            )
    return problems


# --------------------------------------------------------------------------


def run(root: Path, announce: bool = True) -> list[str]:
    rows = parse_table(COMPAT_DOC if root == ROOT else root / "docs" / "COMPAT.md")
    wanted = real_dependency_symbols(rows)
    problems = scan_compat_bodies(root, wanted)
    problems += scan_definition_sites(root, wanted)
    problems += scan_closure(root, rows)

    if not problems and announce:
        headers = len(compat_headers(root))
        sources = len(island_sources(root))
        if sources == 0:
            print(
                f"OK: {len(wanted)} {REAL_DEPENDENCY} symbol(s) read from "
                "docs/COMPAT.md. NO-SOURCE-YET -- 0 island source file(s) and "
                f"{headers} compat header(s), so steps 2-4 have nothing to scan and "
                "pass vacuously. They become required the moment the driver import "
                "lands; --self-test proves them non-vacuously today."
            )
        else:
            print(
                f"OK: {len(wanted)} {REAL_DEPENDENCY} symbol(s) checked across "
                f"{headers} compat header(s) and {sources} island source file(s); "
                "no stub, no unclassified include, no unclassified census symbol."
            )
    return problems


# --------------------------------------------------------------------------
# Step 5 -- the specification's own negative fixture, plus its control
# --------------------------------------------------------------------------


def _self_test() -> int:
    failures: list[str] = []

    def check(name: str, condition: bool) -> None:
        print(f"  [{'ok' if condition else 'FAIL'}] {name}")
        if not condition:
            failures.append(name)

    print("self_test=check-compat-shims")

    rows = parse_table(COMPAT_DOC)
    wanted = real_dependency_symbols(rows)
    check(
        "docs/COMPAT.md parses and classes rockchip_iommu_enable REAL-DEPENDENCY",
        "rockchip_iommu_enable" in wanted,
    )
    check(
        "the STUB-SAFE majority is not swept into the deny list",
        0 < len(wanted) < len([row for row in rows if not row.is_header_row]),
    )
    check(
        "header rows are not mistaken for symbols",
        all(not name.endswith(".h") for name in wanted),
    )

    with tempfile.TemporaryDirectory() as scratch:
        base = Path(scratch)

        def island(name: str, header_body: str, source_body: str = "") -> Path:
            tree = base / name
            compat = tree / "drivers/video/rockchip/mpp/compat/soc/rockchip"
            compat.mkdir(parents=True)
            (compat / "rockchip_iommu.h").write_text(header_body, encoding="utf-8")
            (tree / "docs").mkdir(parents=True)
            (tree / "docs/COMPAT.md").write_text(
                COMPAT_DOC.read_text(encoding="utf-8"), encoding="utf-8"
            )
            if source_body:
                (tree / "drivers/video/rockchip/mpp/mpp_iommu.c").write_text(
                    source_body, encoding="utf-8"
                )
            return tree

        # THE SPECIFICATION'S FIXTURE, verbatim.
        stub = island(
            "stub",
            "#ifndef _COMPAT_ROCKCHIP_IOMMU_H\n"
            "#define _COMPAT_ROCKCHIP_IOMMU_H\n"
            "static inline int rockchip_iommu_enable(struct device *dev) { return 0; }\n"
            "#endif\n",
        )
        found = run(stub, announce=False)
        check(
            "the injected stub is refused",
            any("rockchip_iommu_enable" in problem for problem in found),
        )
        check(
            "the refusal cites the REAL-DEPENDENCY row",
            any(
                "rockchip_iommu_enable" in problem
                and "docs/COMPAT.md:" in problem
                and REAL_DEPENDENCY in problem
                for problem in found
            ),
        )

        # Every other body shape the spec enumerates.
        for label, body in (
            ("an empty void body", "static inline void rockchip_iommu_mask_irq(int x) { }\n"),
            (
                "an -ENODEV body",
                "static inline int rockchip_iommu_disable(struct device *d)\n{\n\treturn -ENODEV;\n}\n",
            ),
            (
                "an ERR_PTR body",
                "static inline void *rockchip_iommu_force_reset(int x) { return ERR_PTR(-ENODEV); }\n",
            ),
            (
                "a macro definition",
                "#define rockchip_iommu_unmask_irq(dev) do { } while (0)\n",
            ),
            (
                "a non-static body",
                "int rockchip_iommu_prepare_irq(struct device *dev)\n{\n\treturn 0;\n}\n",
            ),
        ):
            tree = island(label.replace(" ", "-"), body)
            check(f"{label} is refused", bool(run(tree, announce=False)))

        # CONTROLS -- these must PASS, or the lint is a blunt instrument.
        # The header guard is load-bearing in this fixture, not decoration. A
        # guard carries no `;`, so walking the declarator back from the first
        # declaration in the file reaches byte 0 and drags `#ifndef`/`#define`
        # into the prefix. That made a prototype read as a call site until an
        # on-disk mutation of the real compat header exposed it.
        declared = island(
            "declared-only",
            "#ifndef _COMPAT_SOC_ROCKCHIP_ROCKCHIP_IOMMU_H\n"
            "#define _COMPAT_SOC_ROCKCHIP_ROCKCHIP_IOMMU_H\n"
            "int rockchip_iommu_enable(struct device *dev);\n"
            "void rockchip_iommu_disable(struct device *dev);\n"
            "#endif\n",
        )
        check(
            "a bare declaration behind a header guard is allowed",
            not run(declared, announce=False),
        )

        commented = island(
            "commented",
            "/* Do not write:\n"
            " * static inline int rockchip_iommu_enable(struct device *d) { return 0; }\n"
            " */\n"
            "int rockchip_iommu_enable(struct device *dev);\n",
        )
        check(
            "a comment quoting the forbidden stub does not trip the lint",
            not run(commented, announce=False),
        )

        stubsafe = island(
            "stub-safe",
            "static inline int rockchip_pmu_idle_request(struct device *d, bool idle)\n"
            "{\n\treturn 0;\n}\n",
        )
        check("a STUB-SAFE symbol may keep its stub body", not run(stubsafe, announce=False))

        # Step 4 closure, both arms.
        unclassified_include = island(
            "unclassified-include",
            "int rockchip_iommu_enable(struct device *dev);\n",
            "#include <soc/rockchip/rockchip_invented.h>\n",
        )
        check(
            "an unclassified <soc/rockchip/*.h> include is refused",
            any("rockchip_invented.h" in p for p in run(unclassified_include, announce=False)),
        )

        unclassified_symbol = island(
            "unclassified-symbol",
            "int rockchip_iommu_enable(struct device *dev);\n",
            "void probe(void) { rockchip_brand_new_thing(1); }\n",
        )
        check(
            "an unclassified rockchip_* census symbol is refused",
            any("rockchip_brand_new_thing" in p for p in run(unclassified_symbol, announce=False)),
        )

        classified_include = island(
            "classified-include",
            "int rockchip_iommu_enable(struct device *dev);\n",
            "#include <soc/rockchip/rockchip_iommu.h>\n"
            "void probe(void) { rockchip_iommu_enable(0); }\n",
        )
        found = run(classified_include, announce=False)
        check(
            "a classified include is accepted",
            not any("rockchip_iommu.h" in p and "no row" in p for p in found),
        )
        check(
            "a called REAL-DEPENDENCY with no provider is named (step 3, static half)",
            any("no integration/ patch provides it" in p for p in found),
        )

        provided = island(
            "provided",
            "int rockchip_iommu_enable(struct device *dev);\n",
            "#include <soc/rockchip/rockchip_iommu.h>\n"
            "void probe(void) { rockchip_iommu_enable(0); }\n",
        )
        (provided / "integration").mkdir()
        (provided / "integration/0002-iommu-exports.patch").write_text(
            "diff --git a/drivers/iommu/rockchip-iommu.c b/drivers/iommu/rockchip-iommu.c\n"
            "+EXPORT_SYMBOL(rockchip_iommu_enable);\n",
            encoding="utf-8",
        )
        check(
            "an integration/ export satisfies the static half",
            not any("no integration/ patch provides it" in p for p in run(provided, announce=False)),
        )

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
        problems = run(ROOT)
    except ShimLintError as error:
        print(f"FAIL: {error}")
        return 1

    if problems:
        print("FAIL: shim-lint refused this tree.")
        for problem in problems:
            print(f"  {problem}")
        print()
        print(
            "A compile must never succeed by silently replacing a REAL-DEPENDENCY "
            "with a compatibility stub. Fix the source, or -- if the semantics "
            "genuinely changed -- change the row in docs/COMPAT.md, which is the "
            "machine-owned allow/deny list this gate reads."
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
