#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# Run: python3 docs/repro/rga-table-lifetime.py
"""Exercise maintained table construction and teardown with host DMA fixtures."""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
from pathlib import Path


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    driver = root / "drivers/video/rockchip/rga3"
    mm = (driver / "rga_mm.c").read_text()
    iommu = (driver / "rga_iommu.c").read_text()
    bodies: list[str] = []
    for name, text, required in (
        ("rga_mmu_buf_get_try", iommu, False),
        ("rga_mmu_buf_get", iommu, False),
        ("rga_mm_free_page_table", mm, False),
        ("rga_mm_set_mmu_base", mm, True),
        ("rga_mm_unmap_channel_job_buffer", mm, True),
    ):
        matches = list(re.finditer(
            rf"^[\w *]+\b{name}\([^)]*\)\s*\{{.*?^\}}",
            text, re.MULTILINE | re.DOTALL,
        ))
        if len(matches) != 1:
            if required or matches:
                raise RuntimeError(f"expected one definition: {name}")
            continue
        bodies.append(matches[0].group())
    template = Path(__file__).with_suffix(".c.in").read_text()
    output = root / "test-results"
    output.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rga-table-", dir=output) as directory:
        work = Path(directory)
        source = work / "test.c"
        _ = source.write_text(template.replace("/* PRODUCTION_FUNCTIONS */", "\n".join(bodies)))
        subprocess.run(
            ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
             "-Wno-unused-parameter", "-Wno-unused-function", str(source),
             "-o", str(work / "test")],
            check=True, timeout=30, env={**os.environ, "TMPDIR": directory},
        )
        return subprocess.run([str(work / "test")], check=False, timeout=30).returncode


if __name__ == "__main__":
    raise SystemExit(main())
