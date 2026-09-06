#!/usr/bin/env python3
"""Check production wiring separately from the UML helper tests."""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Final

ROOT: Final = Path(__file__).resolve().parent.parent
MPP: Final = "drivers/video/rockchip/mpp/"
FILES: Final = (
    "mpp_common.c", "mpp_common.h", "mpp_rkvenc2.c",
    "mpp_rkvdec2_link.c", "mpp_iommu.c", "mpp_iommu.h",
)


def body(source: str, function: str) -> str:
    match = re.search(r"\b" + re.escape(function) + r"\([^;{}]*\)\s*\{", source)
    if match is None:
        return ""
    depth = 1
    start = match.end()
    for end in range(start, len(source)):
        if source[end] == "{":
            depth += 1
        if source[end] == "}":
            depth -= 1
        if depth == 0:
            return source[start:end]
    return ""


def check(sources: dict[str, str]) -> list[str]:
    problems: list[str] = []
    required = (
        ("mpp_rkvenc2.c", "rkvenc2_task_timeout_process", "mpp_dump_task"),
        ("mpp_common.c", "mpp_task_timeout_work", "mpp_dump_task"),
        ("mpp_common.c", "mpp_task_run_begin", "media_recovery_started"),
        ("mpp_common.c", "mpp_hw_recover", "media_recovery_claim"),
        ("mpp_common.c", "mpp_dev_reset", "mpp_hw_recover"),
        ("mpp_rkvdec2_link.c", "rkvdec2_link_reset", "mpp_hw_recover"),
        ("mpp_rkvdec2_link.c", "rkvdec2_soft_ccu_reset", "mpp_hw_recover"),
        ("mpp_rkvdec2_link.c", "rkvdec2_hard_ccu_reset", "mpp_hw_recover"),
        ("mpp_rkvdec2_link.c", "rkvdec2_ccu_timeout_work", "mpp_dump_task"),
        ("mpp_rkvdec2_link.c", "rkvdec2_soft_ccu_iommu_fault_handle", "mpp_dump_task"),
        ("mpp_rkvdec2_link.c", "rkvdec2_hard_ccu_iommu_fault_handle", "mpp_dump_task"),
        ("mpp_iommu.c", "mpp_dma_map_kernel", "&buffer->map"),
        ("mpp_iommu.c", "mpp_dma_unmap_kernel", "media_dma_vunmap(dmabuf, &buffer->map)"),
    )
    for filename, function, call in required:
        if call not in body(sources[filename], function):
            problems.append(f"{filename}:{function}: missing {call}")
    if "struct iosys_map map;" not in sources["mpp_iommu.h"]:
        problems.append("mpp_dma_buffer must retain the exporter map")
    for filename, function, _ in required:
        if "timeout" not in function and "fault_handle" not in function:
            continue
        if re.search(r"\b(?:mpp_err|dev_err|dev_warn|pr_err|pr_warn)\(",
                     body(sources[filename], function)):
            problems.append(f"{filename}:{function}: unbounded fault diagnostic")
    return problems


def main() -> int:
    sources = {name: (ROOT / MPP / name).read_text() for name in FILES}
    problems = check(sources)
    if "--self-test" in sys.argv:
        mutations = (
            ("mpp_rkvenc2.c", "mpp_dump_task", "missing_snapshot"),
            ("mpp_rkvdec2_link.c", "mpp_hw_recover", "private_reset"),
            ("mpp_common.c", "media_recovery_started", "missing_epoch"),
            ("mpp_iommu.h", "struct iosys_map map;", "void *lost_map;"),
            ("mpp_common.c", "pr_err_ratelimited", "pr_err"),
        )
        for filename, old, new in mutations:
            mutated = sources | {filename: sources[filename].replace(old, new)}
            if not check(mutated):
                problems.append(f"mutation escaped: {filename} {old}")
        print(f"modernization mutations: {len(mutations)} exercised")
    for problem in problems:
        print(f"FAIL: {problem}")
    if not problems:
        print("PASS: production timeout, recovery and mapping wiring")
    return int(bool(problems))


if __name__ == "__main__":
    raise SystemExit(main())
