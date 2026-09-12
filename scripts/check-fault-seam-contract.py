#!/usr/bin/env python3
"""Check maintained debugfs consumers and execute the required CI summary."""

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


@dataclass(frozen=True, slots=True)
class ContractError(Exception):
    reason: str

    def __str__(self) -> str:
        return self.reason


@dataclass(frozen=True, slots=True)
class Sources:
    production: str
    harnesses: tuple[str, ...]


def surface(text: str) -> frozenset[str]:
    text = re.sub(r"/\*.*?\*/|//[^\n]*", "", text, flags=re.S)
    flags = re.findall(r'\bmpp_rkvenc_test_add_flag\(\s*"([^"]+)"', text)
    formats = re.findall(r'snprintf\([^;]*?"(%s[^"]+)"\s*,\s*name\)', text)
    if not flags or len(formats) != 1:
        raise ContractError("B: missing flag registrations or counter format")
    direct = re.findall(r'\bdebugfs_create_\w+\(\s*"([^"]+)"', text)
    names = flags + [formats[0] % name for name in flags] + direct
    if names.count("rkvenc-test") != 1 or len(names) != len(set(names)):
        raise ContractError("B: missing root or duplicate debugfs registration")
    return frozenset(names) - {"rkvenc-test"}


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
        raise ContractError("C: no harness-consumed literals found")
    return frozenset(names)


def check_harnesses(sources: Sources) -> None:
    production = surface(sources.production)
    for index, text in enumerate(sources.harnesses):
        missing = harness_names(text) - production
        if missing:
            raise ContractError(f"C: harness {index} consumes unknown entries {sorted(missing)}")
    print("PASS C: both harness name sets are subsets of production (including derived counters)")


def expect_red(name: str, check: Callable[[], None]) -> None:
    try:
        check()
    except ContractError as error:
        print(f"RED {name}: {error}")
    else:
        raise ContractError(f"self-test accepted mutation: {name}")


def check_ci_summary() -> None:
    workflow = (ROOT / ".github/workflows/ci.yml").read_text()
    summary = workflow.split("\n  ci-summary:\n", 1)[1]
    if "CODE_CHANGED: ${{ needs.changes.outputs.code }}" not in summary:
        raise ContractError("CI: code-change output missing from required summary")
    script = re.search(r"(?m)^        run: \|\n((?:          [^\n]*\n|\n)+)", summary)
    if script is None:
        raise ContractError("CI: missing executable summary step")
    for code, results, expected in (
        ("true", "success success", 0), ("false", "success skipped", 0),
        ("true", "success skipped", 1), ("true", "success failure", 1),
        ("false", "success failure", 1), ("true", "success cancelled", 1),
    ):
        result = subprocess.run(["bash", "-c", script[1]], check=False, capture_output=True,
                                env={**os.environ, "CODE_CHANGED": code, "RESULTS": results})
        if result.returncode != expected:
            raise ContractError(f"CI: code={code} results={results} expected={expected} actual={result.returncode}")
    print("PASS CI: required summary rejects code skips/failures/cancellations; docs skips allowed")


def self_test(sources: Sources) -> None:
    for index in range(len(sources.harnesses)):
        harnesses = list(sources.harnesses)
        harnesses[index] += '\narm fail_unpublished_once 1\n'
        expect_red(f"unknown harness literal {index}", lambda: check_harnesses(replace(sources, harnesses=tuple(harnesses))))
    print("PASS: fault-seam contract self-test; fixtures are synthetic, not execution evidence")


def main() -> int:
    args = sys.argv[1:]
    if args not in ([], ["--self-test"]):
        print("usage: check-fault-seam-contract.sh [--self-test]", file=sys.stderr)
        return 2
    sources = Sources(
        (ROOT / "drivers/video/rockchip/mpp/mpp_rkvenc_test.c").read_text(),
        tuple((ROOT / "tests/board" / name).read_text() for name in ("fault-matrix.sh", "fault-controls-probe.sh")),
    )
    check_harnesses(sources)
    check_ci_summary()
    if args:
        self_test(sources)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ContractError, OSError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1) from error
