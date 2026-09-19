#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# Run: python3 docs/repro/rga-commit-lifetime.py
"""Exercise commit publication and retirement ownership with host sanitizer fixtures.

Retirement is forced at the first unlocked publication boundary, without sleeps.
This checks software ownership only, not actual IRQ, DMA, PM or kernel locking.
"""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
from pathlib import Path

FUNCTIONS = (
    "rga_job_free",
    "rga_job_kref_release",
    "rga_job_put",
    "rga_job_get",
    "rga_job_cleanup",
    "rga_job_insert_todo_list",
    "rga_job_commit",
)
MODES = (0, 1, 2, 3, 4, 5, 10, 11, 12, 13, 14, 15)


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    source = (root / "drivers/video/rockchip/rga3/rga_job.c").read_text()
    bodies: list[str] = []
    for name in FUNCTIONS:
        matches = list(re.finditer(
            rf"^(?:static )?(?:void|int) {name}\([^;{{]*?^\{{.*?^\}}",
            source, re.MULTILINE | re.DOTALL,
        ))
        if len(matches) != 1:
            raise RuntimeError(f"expected one definition: {name}")
        bodies.append(matches[0].group())
    template = Path(__file__).with_suffix(".c.in").read_text()
    output = root / "test-results"
    output.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rga-commit-", dir=output) as directory:
        work = Path(directory)
        test_source = work / "test.c"
        _ = test_source.write_text(
            template.replace("/* PRODUCTION_FUNCTIONS */", "\n\n".join(bodies))
        )
        binary = work / "test"
        subprocess.run(
            ["cc", "-std=gnu11", "-g", "-O1", "-Wall", "-Wextra", "-Werror",
             "-Wno-unused-parameter", "-Wno-unused-function",
             "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
             str(test_source), "-o", str(binary)],
            check=True, timeout=120, env={**os.environ, "TMPDIR": directory},
        )
        environment = {
            **os.environ,
            "TMPDIR": directory,
            "ASAN_OPTIONS": "detect_leaks=1:halt_on_error=1",
        }
        for mode in MODES:
            result = subprocess.run(
                [str(binary), str(mode)], check=False, timeout=60, env=environment,
            )
            if result.returncode != 0:
                print(f"RED: commit ownership violated in mode {mode}")
                return result.returncode
    print(f"GREEN: {len(MODES)} modes balanced, exactly one free, no use-after-free")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
