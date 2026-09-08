#!/usr/bin/env python3
"""Stage the pinned rewrite and its real providers into a disposable v7.2 tree."""

from __future__ import annotations

import hashlib
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
FAULT_FILES: Final = (
    ("hooks.patch", "FAULT_HOOKS_PATCH_SHA256"),
    ("mpp_rewrite_fault.h", "FAULT_HEADER_SHA256"),
    ("mpp_rewrite_fault_test.h", "FAULT_TEST_HEADER_SHA256"),
)


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


def verify_fault_overlay(comparison: Path) -> None:
    for name, key in FAULT_FILES:
        digest = hashlib.sha256((comparison / "fault-injection" / name).read_bytes()).hexdigest()
        if digest != pin(comparison / "pins.env", key):
            raise PortError(f"fault overlay digest mismatch: {name}")


def stage_fault_overlay(kernel: Path) -> None:
    verify_fault_overlay(COMPARISON)
    fault = COMPARISON / "fault-injection"
    git(kernel, "apply", "--check", str(fault / "hooks.patch"))
    git(kernel, "apply", str(fault / "hooks.patch"))
    for name in ("mpp_rewrite_fault.h", "mpp_rewrite_fault_test.h"):
        shutil.copyfile(fault / name, kernel / "drivers/video/rockchip/mpp-rewrite" / name)


def verify_snapshot(upstream: Path, tip: str) -> None:
    for module in MODULES:
        source = COMPARISON / module
        expected_names = git(upstream, "ls-tree", "--name-only", f"{tip}:drivers/video/rockchip/{module}")
        if sorted(expected_names.decode().splitlines()) != sorted(p.name for p in source.iterdir()):
            raise PortError(f"snapshot file set differs: {module}")
        for path in source.iterdir():
            if path.read_bytes() != git(upstream, "show", f"{tip}:drivers/video/rockchip/{module}/{path.name}"):
                raise PortError(f"snapshot bytes differ: {module}/{path.name}")


def stage_modules(kernel: Path, fault_seam: bool) -> None:
    for module in MODULES:
        shutil.copytree(COMPARISON / module, kernel / "drivers/video/rockchip" / module)
    if fault_seam:
        stage_fault_overlay(kernel)


def stage(kernel: Path, upstream: Path, fault_seam: bool = True) -> None:
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
    verify_snapshot(upstream, tip)
    if fault_seam:
        verify_fault_overlay(COMPARISON)

    delta = git(upstream, "diff", "--binary", "--full-index", base, tip, "--", *PROVIDERS)
    if not delta:
        raise PortError("provider delta is empty")
    git(kernel, "apply", "--check", "-", payload=delta)
    linkage = COMPARISON / "port-arm64-dma.patch"
    git(kernel, "apply", "--check", str(linkage))
    git(kernel, "apply", "-", payload=delta)
    git(kernel, "apply", str(linkage))
    stage_modules(kernel, fault_seam)
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
        upstream = root / "upstream"
        for module in MODULES:
            shutil.copytree(COMPARISON / module, upstream / "drivers/video/rockchip" / module)
        git(upstream, "init", "-q")
        git(upstream, "add", "drivers")
        git(upstream, "-c", "user.name=fixture", "-c", "user.email=fixture@local",
            "commit", "-qm", "snapshot fixture")
        verify_snapshot(upstream, "HEAD")
        print("PASS (i): snapshot file-set/bytes check with overlay present")
        kernel = root / ".work/linux"
        target = kernel / "drivers/video/rockchip/mpp-rewrite"
        stage_modules(kernel, True)
        for name in ("mpp_rewrite_fault.h", "mpp_rewrite_fault_test.h"):
            if (target / name).read_bytes() != (COMPARISON / "fault-injection" / name).read_bytes():
                raise PortError(f"fault overlay did not stage {name}")
        print("PASS (ii): both overlay headers staged byte-identically")
        damaged = root / "damaged"
        shutil.copytree(COMPARISON / "fault-injection", damaged / "fault-injection")
        shutil.copyfile(COMPARISON / "pins.env", damaged / "pins.env")
        patch = damaged / "fault-injection/hooks.patch"
        text = patch.read_text()
        hunk = text.index("@@ ")
        end = text.index("diff --git ", hunk)
        patch.write_text(text[:text.index("diff --git ")] + text[end:])
        try:
            verify_fault_overlay(damaged)
        except PortError as error:
            if str(error) != "fault overlay digest mismatch: hooks.patch":
                raise
            print("RED (iii): removed independent hunk rejected by pinned digest")
        else:
            raise PortError("accepted fault overlay missing one hunk")
        try:
            stage_fault_overlay(kernel)
        except subprocess.CalledProcessError:
            print("PASS (iv): fault overlay rejects duplicate application")
        else:
            raise PortError("accepted duplicate fault overlay")
        bare = root / ".work/bare"
        stage_modules(bare, False)
        for module in MODULES:
            source = COMPARISON / module
            staged = bare / "drivers/video/rockchip" / module
            if sorted(p.name for p in staged.iterdir()) != sorted(p.name for p in source.iterdir()):
                raise PortError("--no-fault-seam changed snapshot file set")
            for path in source.iterdir():
                if path.read_bytes() != (staged / path.name).read_bytes():
                    raise PortError("--no-fault-seam changed snapshot bytes")
        print("PASS (v): --no-fault-seam staging has neither header; snapshots unchanged")


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return 0
    args = sys.argv[1:]
    fault_seam = "--no-fault-seam" not in args
    if not fault_seam:
        args.remove("--no-fault-seam")
    if len(args) != 2 or any(arg.startswith("--") for arg in args):
        print("usage: port-rewrite.py [--no-fault-seam] KERNEL_TREE UPSTREAM_GIT | --self-test", file=sys.stderr)
        return 2
    stage(Path(args[0]).resolve(), Path(args[1]).resolve(), fault_seam)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (PortError, OSError, subprocess.CalledProcessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1) from error
