#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Stage exact driver functions for hardware-free ioctl KUnit translation units.

Run: python3 tests/kunit/stage_ioctl.py KERNEL_TREE
No function body is rewritten. Missing/ambiguous definitions fail the build.
The generated prototypes allow source-order-independent selection. Kernel types
come from the maintained headers, not test replicas of the ABI or session state.
"""

from pathlib import Path
import re
import shutil
import sys
from typing import Final

ROOT: Final = Path(__file__).resolve().parents[2]
DRIVERS: Final = ROOT / "drivers/video/rockchip"
MPP: Final = (
    "mpp_session_kref_release", "mpp_session_get", "mpp_session_put",
    "mpp_compiled_client_mask", "mpp_service_visible_hw_support",
    "task_msgs_reset", "task_msgs_init", "get_task_msgs", "put_task_msgs",
    "clear_task_msgs", "mpp_session_init", "mpp_session_deinit_default",
    "mpp_session_deinit", "mpp_check_cmd_v1", "mpp_get_cmd_butt",
    "__mpp_process_request", "mpp_process_request", "task_msgs_add",
    "mpp_copy_msg_v1", "mpp_collect_msgs", "mpp_msgs_wait",
    "mpp_dev_ioctl_common", "mpp_dev_ioctl", "mpp_dev_open", "mpp_dev_release",
)
RGA_DRV: Final = (
    "rga_session_manager_init", "rga_session_free_remove_idr",
    "rga_session_init", "rga_session_kref_release", "rga_session_put",
    "rga_session_get", "rga_ioctl_import_buffer", "rga_ioctl_release_buffer",
    "rga_ioctl_request_create", "rga_ioctl_request_submit",
    "rga_ioctl_request_cancel", "rga_ioctl_blit", "rga_ioctl",
    "rga_open", "rga_release",
)
RGA_JOB: Final = (
    "rga_request_put_current_mm",
    "rga_request_check", "rga_request_lookup", "rga_request_config_locked",
    "rga_request_free", "rga_request_kref_release", "rga_request_alloc",
    "rga_request_put", "rga_request_release_ref", "rga_request_get",
    "rga_request_release_abort", "rga_request_cancel",
    "rga_request_session_destroy_abort", "rga_request_manager_init",
)


class DefinitionError(RuntimeError):
    """The selected source no longer has one whole, column-zero definition."""

    def __init__(self, name: str, count: int) -> None:
        super().__init__(f"{name}: expected one definition, found {count}")


def definition(source: str, name: str) -> str:
    """Select a complete kernel-style definition, preserving every body byte."""
    pattern = rf"^[\w *]+\n?\b{re.escape(name)}\([^;{{}}]*\)\n\{{\n.*?^\}}"
    matches = tuple(re.finditer(pattern, source, re.MULTILINE | re.DOTALL))
    if len(matches) != 1:
        raise DefinitionError(name, len(matches))
    return matches[0].group()


def emit(destination: Path, groups: tuple[tuple[Path, tuple[str, ...]], ...]) -> None:
    """Emit declarations followed by byte-preserved definitions and line markers."""
    functions: list[tuple[str, str, int]] = []
    for path, names in groups:
        source = path.read_text()
        for name in names:
            body = definition(source, name)
            line = source[:source.index(body)].count("\n") + 1
            functions.append((body, str(path.relative_to(ROOT)), line))
    declarations = [body[:body.index("\n{")] + ";" for body, _, _ in functions]
    bodies = [f'#line {line} "{path}"\n{body}' for body, path, line in functions]
    destination.write_text("\n".join(declarations + bodies) + "\n")


def stage(tree: Path) -> None:
    """Populate only the test/header staging area of an existing kernel tree."""
    target = tree / "drivers/video/rockchip"
    for path in DRIVERS.rglob("*.h"):
        dest = target / path.relative_to(DRIVERS)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, dest)
    shutil.copyfile(ROOT / "include/uapi/linux/rk-mpp.h", tree / "include/uapi/linux/rk-mpp.h")
    tests = target / "kunit"
    shutil.copytree(ROOT / "tests/kunit", tests, dirs_exist_ok=True)
    shutil.copyfile(DRIVERS / "rga3/rga_test.c", target / "rga3/rga_test.c")
    provider = (ROOT / "integration/0002-iommu-rockchip-export-for-mpp.patch").read_text()
    bus_error = re.findall(r"^\+(#define ROCKCHIP_IOMMU_FAULT_BUS_ERROR[^\n]*)$", provider, re.MULTILINE)
    if len(bus_error) != 1:
        raise DefinitionError("ROCKCHIP_IOMMU_FAULT_BUS_ERROR", len(bus_error))
    (tests / "rga_fault_provider.inc").write_text(bus_error[0] + "\n")
    emit(tests / "rga_fault_source.inc", (
        (DRIVERS / "rga3/rga_job.c", (
            "rga_telemetry_record_busy", "rga_telemetry_reset", "rga_job_run",
            "rga_job_timeout_query_state", "rga_job_scheduler_timeout_clean",
        )),
        (DRIVERS / "rga3/rga_iommu.c", (
            "rga_iommu_intr_fault_handler", "rga_iommu_test_prepare",
            "rga_iommu_test_fault",
        )),
        (DRIVERS / "rga3/rga_debugger.c", ("rga_reset_write",)),
    ))
    common = DRIVERS / "mpp/mpp_common.c"
    source = common.read_text()
    structs = re.findall(r"^struct mpp_msg_v1 \{.*?^\};", source, re.MULTILINE | re.DOTALL)
    if len(structs) != 1:
        raise DefinitionError("mpp_msg_v1", len(structs))
    (tests / "ioctl_mpp_types.inc").write_text(structs[0] + "\n")
    job = (DRIVERS / "rga3/rga_job.c").read_text()
    enums = re.findall(r"^enum rga_acquire_fence_state \{.*?^\};", job, re.MULTILINE | re.DOTALL)
    if len(enums) != 1:
        raise DefinitionError("rga_acquire_fence_state", len(enums))
    (tests / "ioctl_rga_types.inc").write_text(enums[0] + "\n")
    emit(tests / "ioctl_mpp_source.inc", ((common, MPP),))
    emit(tests / "telemetry_mpp_source.inc", (
        (DRIVERS / "mpp/mpp_service.c", (
            "mpp_telemetry_atomic64_get", "mpp_debugfs_create_atomic64",
            "mpp_telemetry_init", "mpp_telemetry_remove",
        )),
        (common, ("mpp_dev_remove",)),
    ))
    emit(tests / "ioctl_rga_source.inc", (
        (DRIVERS / "rga3/rga_drv.c", RGA_DRV),
        (DRIVERS / "rga3/rga_job.c", RGA_JOB),
    ))
    # Keep both preprocessor arms: selecting duplicate power definitions by
    # name would hide whether the production PM build is actually exercised.
    power_source = (DRIVERS / "rga3/rga_drv.c").read_text()
    power = re.findall(
        r"^#ifndef RGA_DISABLE_PM\nint rga_power_enable\(.*?^#endif[^\n]*",
        power_source, re.MULTILINE | re.DOTALL,
    )
    if len(power) != 1:
        raise DefinitionError("RGA power block", len(power))
    (tests / "runtime_pm_rga_power.inc").write_text(power[0] + "\n")
    emit(tests / "runtime_pm_rga_jobs.inc", ((DRIVERS / "rga3/rga_job.c", (
        "rga_job_run", "rga_job_next", "rga_request_scheduler_abort",
        "rga_request_scheduler_job_abort",
    )),))
    jpeg_source = (DRIVERS / "mpp/mpp_jpgdec.c").read_text()
    jpeg_types = re.findall(
        r"^struct jpgdec_dev \{.*?^\};", jpeg_source, re.MULTILINE | re.DOTALL,
    )
    if len(jpeg_types) != 1:
        raise DefinitionError("jpgdec_dev", len(jpeg_types))
    (tests / "runtime_pm_jpeg_types.inc").write_text(jpeg_types[0] + "\n")
    emit(tests / "runtime_pm_jpeg_probe.inc", (
        (DRIVERS / "mpp/mpp_jpgdec.c", ("jpgdec_probe",)),
    ))
    for filename, directive in (
        ("Kconfig", 'source "drivers/video/rockchip/kunit/Kconfig"'),
        ("Makefile", "obj-y += rockchip/kunit/"),
    ):
        path = tree / "drivers/video" / filename
        original = path.read_text()
        if directive not in original.splitlines():
            path.write_text(original + "\n" + directive + "\n")


def self_test() -> None:
    """Prove exact-name selection, body preservation, and fail-closed absence."""
    body = 'static int request(int x)\n{\n\t/* } */\n\treturn x + 1;\n}'
    source = 'static int request(int x);\n' + body.replace('request(', '__request(') + '\n' + body
    assert definition(source, "request") == body
    assert definition(source.replace("x + 1", "x + 2"), "request") == body.replace("x + 1", "x + 2")
    for invalid in ("", body + "\n" + body):
        try:
            definition(invalid, "request")
        except DefinitionError:
            continue
        raise AssertionError("missing or duplicate definition was accepted")
    probe = definition((DRIVERS / "rga3/rga_drv.c").read_text(), "rga_drv_probe")
    policy = (
        r"pm_runtime_set_autosuspend_delay\(dev,\s*2000\);.*?"
        r"pm_runtime_use_autosuspend\(dev\);.*?"
        r"pm_runtime_enable\(scheduler->dev\);.*?"
        r"pm_runtime_resume_and_get\(scheduler->dev\)"
    )
    assert re.search(policy, probe, re.DOTALL), "RGA probe must configure autosuspend before get"
    for call in ("set_autosuspend_delay", "use_autosuspend", "enable"):
        mutant = probe.replace(f"pm_runtime_{call}(", f"removed_{call}(")
        assert not re.search(policy, mutant, re.DOTALL), f"missing {call} was accepted"
    print("ioctl staging self-test: PASS")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    else:
        stage(Path(sys.argv[1]).resolve())
