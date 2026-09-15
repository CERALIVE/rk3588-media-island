#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# From this checkout: uv run docs/repro/rga-import-order.py
# Or use the installed python3; this script needs only the standard library.
# Exit 1 = reproduced defect, 2 = invalid fixture/build, 0 = no finding.
"""Compile maintained import functions with a bounded host DMA boundary fixture."""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Final

FUNCTIONS: Final = (
    "rga_mm_check_memory_limit",
    "rga_mm_check_range_sgt",
    "rga_mm_check_contiguous_sgt",
    "rga_mm_map_dma_buffer",
)


def main() -> int:
    """Run only host code, keeping all generated files inside this checkout."""
    root = Path(__file__).resolve().parents[2]
    source = root / "drivers/video/rockchip/rga3/rga_mm.c"
    raw = source.read_bytes()
    text = raw.decode("utf-8")
    bodies: list[str] = []
    for name in FUNCTIONS:
        pattern = rf"^static[^\n]*\b{re.escape(name)}\([^)]*\)\s*\{{.*?^\}}"
        matches = list(re.finditer(pattern, text, re.MULTILINE | re.DOTALL))
        if len(matches) != 1:
            print(f"INVALID: expected one complete definition of {name}")
            return 2
        bodies.append(matches[0].group())
    template = Path(__file__).with_suffix(".c.in").read_text(encoding="utf-8")
    marker = "/* PRODUCTION_FUNCTIONS */"
    if template.count(marker) != 1:
        print("INVALID: fixture insertion marker missing or duplicated")
        return 2
    compiler = shutil.which("cc")
    if compiler is None:
        print("INVALID: host C compiler cc is unavailable")
        return 2
    output = root / "test-results"
    output.mkdir(exist_ok=True)
    print(f"source_sha256={hashlib.sha256(raw).hexdigest()}", flush=True)
    with tempfile.TemporaryDirectory(
        prefix="rga-import-order-", dir=output
    ) as directory:
        work = Path(directory)
        translation_unit = work / "repro.c"
        executable = work / "repro"
        _ = translation_unit.write_text(
            template.replace(marker, "\n\n".join(bodies)), encoding="utf-8"
        )
        build = subprocess.run(
            [
                compiler,
                "-std=c11",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-Wno-sign-compare",
                str(translation_unit),
                "-o",
                str(executable),
            ],
            check=False,
            timeout=30,
            env={**os.environ, "TMPDIR": str(work)},
        )
        if build.returncode != 0:
            print("INVALID: fixture did not compile")
            return 2
        result = subprocess.run([str(executable)], check=False, timeout=10)
        return result.returncode if result.returncode in (0, 1, 2) else 2


if __name__ == "__main__":
    try:
        exit_code = main()
    except (OSError, UnicodeError, subprocess.TimeoutExpired) as error:
        print(f"INVALID: {error}")
        exit_code = 2
    raise SystemExit(exit_code)
