#!/usr/bin/env python3
"""Stage the pinned rewrite and its real providers into a disposable v7.2 tree."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Final

ROOT: Final = Path(__file__).resolve().parent.parent
COMPARISON: Final = ROOT / "island/comparison/rewrite"
PROVIDERS: Final = (
    "drivers/iommu/dma-iommu.c",
    "drivers/iommu/rockchip-iommu.c",
    "drivers/iommu/vsi-iommu.c",
    "include/linux/iommu.h",
    "include/soc/rockchip/rockchip_iommu.h",
    "include/soc/rockchip/vsi_iommu.h",
    "include/uapi/linux/rk-mpp.h",
)
MODULES: Final = ("mpp-rewrite", "rga-rewrite")


@dataclass(frozen=True, slots=True)
class PortError(Exception):
    reason: str

    def __str__(self) -> str:
        return self.reason


def pin(path: Path, name: str) -> str:
    matches = re.findall(rf'^{name}="?([a-zA-Z0-9:/._-]+)"?', path.read_text(), re.M)
    if len(matches) != 1:
        raise PortError(f"missing or ambiguous {name} in {path.name}")
    return matches[0]


def git(repo: Path, *args: str, payload: bytes | None = None) -> bytes:
    return subprocess.run(
        ["git", "-C", str(repo), *args], input=payload, stdout=subprocess.PIPE,
        check=True, env={**os.environ, "GIT_MASTER": "1"},
    ).stdout


def require_scratch(root: Path, destination: Path) -> None:
    scratch = root.resolve() / ".work"
    resolved = destination.resolve()
    if resolved == scratch or not resolved.is_relative_to(scratch):
        raise PortError("destination must be a disposable kernel under this repo's .work/")


def stage(kernel: Path, upstream: Path) -> None:
    require_scratch(ROOT, kernel)
    expected = pin(ROOT / "kernel-pin.env", "KERNEL_COMMIT")
    if git(kernel, "rev-parse", "HEAD").decode().strip() != expected:
        raise PortError("kernel HEAD is not the pinned final kernel")
    if git(kernel, "status", "--porcelain"):
        raise PortError("kernel tree must be pristine before comparison staging")
    base = pin(COMPARISON / "pins.env", "REWRITE_BASE")
    tip = pin(COMPARISON / "pins.env", "REWRITE_COMMIT")
    for coordinate in (base, tip):
        if git(upstream, "rev-parse", f"{coordinate}^{{commit}}").decode().strip() != coordinate:
            raise PortError("rewrite source coordinate mismatch")
    for module in MODULES:
        source = COMPARISON / module
        expected_names = git(upstream, "ls-tree", "--name-only", f"{tip}:drivers/video/rockchip/{module}")
        if sorted(expected_names.decode().splitlines()) != sorted(p.name for p in source.iterdir()):
            raise PortError(f"snapshot file set differs: {module}")
        for path in source.iterdir():
            if path.read_bytes() != git(upstream, "show", f"{tip}:drivers/video/rockchip/{module}/{path.name}"):
                raise PortError(f"snapshot bytes differ: {module}/{path.name}")

    delta = git(upstream, "diff", "--binary", "--full-index", base, tip, "--", *PROVIDERS)
    if not delta:
        raise PortError("provider delta is empty")
    git(kernel, "apply", "--check", "-", payload=delta)
    linkage = COMPARISON / "port-arm64-dma.patch"
    git(kernel, "apply", "--check", str(linkage))
    git(kernel, "apply", "-", payload=delta)
    git(kernel, "apply", str(linkage))
    for module in MODULES:
        shutil.copytree(COMPARISON / module, kernel / "drivers/video/rockchip" / module)
    with (kernel / "drivers/video/Kconfig").open("a") as stream:
        for module in MODULES:
            stream.write(f'\nsource "drivers/video/rockchip/{module}/Kconfig"\n')
    with (kernel / "drivers/video/Makefile").open("a") as stream:
        stream.write("\nobj-$(CONFIG_ROCKCHIP_MPP_REWRITE) += rockchip/mpp-rewrite/\n")
        stream.write("obj-$(CONFIG_ROCKCHIP_RGA_REWRITE) += rockchip/rga-rewrite/\n")
    print(f"STAGED: rewrite={tip} base={base} target={expected}; comparison only")


def self_test() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        require_scratch(root, root / ".work/linux")
        for forbidden in (root, root / "drivers", root / ".work", root.parent / "linux"):
            try:
                require_scratch(root, forbidden)
            except PortError:
                continue
            raise PortError(f"accepted non-scratch destination: {forbidden}")
        (root / ".work").mkdir()
        (root / ".work/escape").symlink_to(root)
        try:
            require_scratch(root, root / ".work/escape/linux")
        except PortError:
            print("PASS: scratch destination admission and symlink escape refusal")
        else:
            raise PortError("accepted symlink escape")


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return 0
    if len(sys.argv) != 3:
        print("usage: port-rewrite.py KERNEL_TREE UPSTREAM_GIT | --self-test", file=sys.stderr)
        return 2
    stage(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (PortError, OSError, subprocess.CalledProcessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1) from error
