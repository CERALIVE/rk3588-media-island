#!/usr/bin/env python3
"""Check source inventories and completed KTAP, without importing the producer."""

from __future__ import annotations

import os
import re
import subprocess
import sys
from collections.abc import Callable
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Final

ROOT: Final = Path(__file__).resolve().parent.parent
OVERLAY: Final = ROOT / "island/comparison/rewrite/fault-injection"
SUITE: Final = "rk-mpp-rewrite-fault"
PARITY: Final = (
    ("mpp_fault_flag_is_one_shot_test", "rk_mpp_fault_hang_once_kunit"),
    ("mpp_fault_delay_is_one_shot_test", "rk_mpp_fault_retained_completion_kunit"),
    *((f"mpp_fault_target_{name}_test", f"rk_mpp_fault_target_{name}_kunit") for name in (
        "zero_matches_any", "matches_only_named_pid", "clears_after_consume",
        "does_not_consume_unarmed", "written_concurrently_is_kept",
    )),
)


@dataclass(frozen=True, slots=True)
class ParityError(Exception):
    reason: str

    def __str__(self) -> str:
        return self.reason


@dataclass(frozen=True, slots=True)
class Sources:
    production: str
    overlay: str
    harnesses: tuple[str, ...]
    cases: frozenset[str]
    production_cases: frozenset[str]


def case_names(text: str) -> frozenset[str]:
    return frozenset(re.findall(r"KUNIT_CASE\((\w+)\)", text))


def surface(text: str) -> frozenset[str]:
    text = re.sub(r"/\*.*?\*/|//[^\n]*", "", text, flags=re.S)
    flags = re.findall(r'\b(?:mpp_rkvenc_test|rk_mpp_fault)_add_flag\(\s*(?:fault->root,\s*)?"([^"]+)"', text)
    formats = re.findall(r'snprintf\([^;]*?"(%s[^"]+)"\s*,\s*name\)', text)
    if not flags or len(formats) != 1:
        raise ParityError("B: missing flag registrations or counter format")
    direct = re.findall(r'\bdebugfs_create_\w+\(\s*"([^"]+)"', text)
    names = flags + [formats[0] % name for name in flags] + direct
    if names.count("rkvenc-test") != 1 or len(names) != len(set(names)):
        raise ParityError("B: missing root or duplicate debugfs registration")
    return frozenset(names) - {"rkvenc-test"}


def check_surface(sources: Sources) -> frozenset[str]:
    production = surface(sources.production)
    overlay = surface(sources.overlay)
    if overlay != production | {"sessions"} or "sessions" in production:
        raise ParityError(f"B: debugfs mismatch missing={sorted(production - overlay)} extra={sorted(overlay - production - {'sessions'})}")
    print(f"PASS B: {len(production)} production entries == overlay minus sessions")
    return production


def harness_names(text: str) -> frozenset[str]:
    # The drill deliberately manufactures a bad filename in self_test(); it is
    # a mutation producer, not a consumed operator name. Do not source scripts.
    runtime = re.sub(r"^self_test\(\) \{\n.*?^\}", "", text, flags=re.M | re.S)
    runtime = re.sub(r"^\s*#.*$", "", runtime, flags=re.M)
    names = set(re.findall(r"\b(?:fail_\w+|hang_task_\w+|inject_iommu_fault_\w+|delay_task_completion_\w+|delay_consumed\w*|target_session_pid\w*)\b", runtime))
    for body in re.findall(r"\bFAULT_SEAM_ENTRIES=\((.*?)\)", runtime, re.S):
        names.update(re.findall(r"\b[a-z][a-z0-9_]+\b", body))
    for body in re.findall(r"\bKNOB=\((.*?)\)", runtime, re.S):
        knobs = re.findall(r"\]=[\"']?([a-z][a-z0-9_]+)", body)
        names.update(knobs)
        names.update(f"{knob}_consumed" for knob in knobs)
    if not names:
        raise ParityError("C: no harness-consumed literals found")
    return frozenset(names)


def check_harnesses(sources: Sources) -> None:
    production = surface(sources.production)
    for index, text in enumerate(sources.harnesses):
        missing = harness_names(text) - production
        if missing:
            raise ParityError(f"C: harness {index} consumes unknown entries {sorted(missing)}")
    print("PASS C: both harness name sets are subsets of production (including derived counters)")


def check_ktap(text: str, sources: Sources) -> None:
    if re.search(r"WARNING:|BUG:|Oops:|KASAN:|DEBUG_LOCKS_WARN_ON|possible circular locking|Bail out!", text):
        raise ParityError("A: kernel diagnostic or KTAP bailout")
    text = re.sub(r"^\[\s*\d+\.\d+\]\s?", "", text, flags=re.M)
    starts = list(re.finditer(rf"^( +)# Subtest: {SUITE}$", text, re.M))
    if len(starts) != 1:
        raise ParityError("A: missing or duplicate seam suite")
    start = starts[0]
    results = list(re.finditer(rf"^(ok|not ok) \d+ {SUITE}(.*)$", text[start.end():], re.M))
    if len(results) != 1:
        raise ParityError("A: missing or duplicate suite result")
    result = results[0]
    if result[1] != "ok" or result[2].strip():
        raise ParityError("A: failed or skipped suite result")
    block = text[start.end():start.end() + result.start()]
    indent = re.escape(start[1])
    rows = re.findall(rf"^{indent}(ok|not ok) (\d+) (\w+)(.*)$", block, re.M)
    plans = re.findall(rf"^{indent}1\.\.(\d+)$", block, re.M)
    names = [name for _, _, name, _ in rows]
    if (len(plans) != 1 or int(plans[0]) != len(rows)
            or [int(number) for _, number, _, _ in rows] != list(range(1, len(rows) + 1))
            or len(names) != len(set(names)) or set(names) != sources.cases
            or any(status != "ok" or suffix.strip() for status, _, _, suffix in rows)):
        raise ParityError(f"A: incomplete/nonpassing case set; missing={sorted(sources.cases - set(names))}")
    summary = rf"^\s*# {SUITE}: pass:{len(rows)} fail:0 skip:0 total:{len(rows)}$"
    if len(re.findall(summary, block, re.M)) != 1 or re.search(r"^\s*not ok\b", text, re.M):
        raise ParityError("A: missing/duplicate clean summary or failing KTAP result")
    print("CASE-NAME PARITY TABLE (production UML -> rewrite arm64 QEMU)")
    for production, overlay in PARITY:
        if production not in sources.production_cases or overlay not in names:
            raise ParityError(f"A: missing parity pair {production} -> {overlay}")
        print(f"  {production} -> {overlay}: ok")
    print(f"PASS A: completed {len(rows)}-case {SUITE}; nine controls plus selector coverage")


def expect_red(name: str, check: Callable[[], frozenset[str] | None]) -> None:
    try:
        check()
    except ParityError as error:
        print(f"RED {name}: {error}")
    else:
        raise ParityError(f"self-test accepted mutation: {name}")


def check_ci_summary() -> None:
    workflow = (ROOT / ".github/workflows/ci.yml").read_text()
    summary = workflow.split("\n  ci-summary:\n", 1)[1]
    if ("      - kunit-rewrite-fault\n" not in summary
            or "CODE_CHANGED: ${{ needs.changes.outputs.code }}" not in summary):
        raise ParityError("CI: parity job or code-change output missing from required summary")
    script = re.search(r"(?m)^        run: \|\n((?:          [^\n]*\n|\n)+)", summary)
    if script is None:
        raise ParityError("CI: missing executable summary step")
    for code, results, expected in (
        ("true", "success success", 0), ("false", "success skipped", 0),
        ("true", "success skipped", 1), ("true", "success failure", 1),
        ("false", "success failure", 1), ("true", "success cancelled", 1),
    ):
        result = subprocess.run(["bash", "-c", script[1]], check=False, capture_output=True,
                                env={**os.environ, "CODE_CHANGED": code, "RESULTS": results})
        if result.returncode != expected:
            raise ParityError(f"CI: code={code} results={results} expected={expected} actual={result.returncode}")
    print("PASS CI: required summary rejects code skips/failures/cancellations; docs skips allowed")


def self_test(sources: Sources) -> None:
    check_ci_summary()
    fixtures = ROOT / "tests/fixtures/kunit"
    passing = (fixtures / "rewrite-fault-pass.ktap").read_text()
    check_ktap(passing, sources)
    expect_red("missing-case fixture", lambda: check_ktap((fixtures / "rewrite-fault-missing-case.ktap").read_text(), sources))
    renamed = replace(sources, overlay=sources.overlay.replace('"fail_irq_request_once"', '"renamed_irq_once"'))
    expect_red("renamed knob", lambda: check_surface(renamed))
    for index in range(len(sources.harnesses)):
        harnesses = list(sources.harnesses)
        harnesses[index] += '\narm fail_unpublished_once 1\n'
        expect_red(f"unknown harness literal {index}", lambda: check_harnesses(replace(sources, harnesses=tuple(harnesses))))
    for name, damaged in (
        ("not-ok", passing.replace("    ok 1 ", "    not ok 1 ")),
        ("skipped", passing.replace("rk_mpp_fault_service_attach_once_kunit\n", "rk_mpp_fault_service_attach_once_kunit # SKIP\n")),
        ("truncated", passing.rsplit("ok 1 rk-mpp-rewrite-fault", 1)[0]),
        ("wrong-suite", passing.replace(SUITE, "unrelated-suite")),
        ("lockdep", passing + "\nWARNING: possible circular locking\n"),
        ("wrong-plan", passing.replace("    1..15", "    1..14")),
        ("duplicate-suite-result", passing + "ok 2 rk-mpp-rewrite-fault\n"),
        ("duplicate-suite-summary", passing.replace("# Totals:", "# rk-mpp-rewrite-fault: pass:15 fail:0 skip:0 total:15\n# Totals:")),
    ):
        expect_red(name, lambda: check_ktap(damaged, sources))
    expect_red("counter-format", lambda: check_surface(replace(sources, overlay=sources.overlay.replace('"%s_consumed"', '"%s_count"'))))
    print("PASS: fault-seam parity self-test; fixtures are synthetic, not execution evidence")


def main() -> int:
    args = sys.argv[1:]
    selftest = "--self-test" in args
    if selftest:
        args.remove("--self-test")
    log = None
    if len(args) == 2 and args[0] == "--ktap-log":
        log = Path(args[1])
    elif args:
        print("usage: check-fault-seam-parity.sh [--ktap-log PATH] [--self-test]", file=sys.stderr)
        return 2
    sources = Sources(
        (ROOT / "drivers/video/rockchip/mpp/mpp_rkvenc_test.c").read_text(),
        (OVERLAY / "mpp_rewrite_fault.h").read_text(),
        tuple((ROOT / "tests/board" / name).read_text() for name in ("fault-matrix.sh", "fault-controls-probe.sh")),
        case_names((OVERLAY / "mpp_rewrite_fault_test.h").read_text()),
        case_names((ROOT / "tests/kunit/mpp_fault_injection_test.c").read_text()),
    )
    check_surface(sources)
    check_harnesses(sources)
    if log is not None:
        check_ktap(log.read_text(), sources)
    if selftest:
        self_test(sources)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ParityError, OSError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1) from error
