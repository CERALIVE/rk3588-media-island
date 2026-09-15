#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# Run: python3 docs/repro/rga-routing.py
"""Compile the maintained memory classifier and core selector without hardware."""
from __future__ import annotations

import os
import re
import subprocess
import tempfile
from pathlib import Path


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    driver = root / "drivers/video/rockchip/rga3"
    bodies: list[str] = []
    for filename, names in (
        ("rga_mm.c", ("rga_dma_max_segment_size", "rga_mm_lookup_rga2_support",
                      "rga_mm_prepare_channel", "rga_mm_prepare_job_info")),
        ("rga_job.c", ("rga_job_judgment_support_core",)),
        ("rga_policy.c", ("rga_job_assign",)),
    ):
        text = (driver / filename).read_text()
        for name in names:
            matches = list(re.finditer(
                rf"^[\w *]+\b{name}\([^)]*\)\s*\{{.*?^\}}",
                text, re.MULTILINE | re.DOTALL,
            ))
            if len(matches) != 1:
                raise RuntimeError(f"expected one definition: {name}")
            bodies.append(matches[0].group())
    template = Path(__file__).with_suffix(".c.in").read_text()
    output = root / "test-results"
    output.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rga-routing-", dir=output) as directory:
        work = Path(directory)
        source = work / "test.c"
        _ = source.write_text(template.replace("/* PRODUCTION_FUNCTIONS */", "\n".join(bodies)))
        subprocess.run(
            ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
             "-Wno-unused-parameter", "-Wno-sign-compare", str(source),
             "-o", str(work / "test")],
            check=True, timeout=30, env={**os.environ, "TMPDIR": directory},
        )
        return subprocess.run([str(work / "test")], check=False, timeout=30).returncode


if __name__ == "__main__":
    raise SystemExit(main())
