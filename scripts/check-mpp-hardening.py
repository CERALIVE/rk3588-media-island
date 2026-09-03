#!/usr/bin/env python3
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# ─── How to run ───
# uv run scripts/check-mpp-hardening.py [--self-test]

from __future__ import annotations

import argparse
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Final

ROOT: Final = Path(__file__).resolve().parents[1]


@dataclass(frozen=True, slots=True)
class Sources:
    common: str
    iommu: str
    rkvenc: str
    service: str


@dataclass(frozen=True, slots=True)
class Result:
    name: str
    passed: bool


def between(source: str, start: str, end: str) -> str:
    return source[source.index(start) : source.index(end, source.index(start))]


def optional_between(source: str, start: str, end: str) -> str:
    start_index = source.find(start)
    if start_index < 0:
        return ""
    end_index = source.find(end, start_index)
    return source[start_index:] if end_index < 0 else source[start_index:end_index]


def ordered(source: str, first: str, second: str) -> bool:
    return first in source and second in source and source.index(first) < source.index(second)


def irqsave_blocks_are_atomic(source: str) -> bool:
    lines = source.splitlines()
    for index, line in enumerate(lines):
        if "spin_lock_irqsave(" not in line:
            continue
        tail = lines[index:]
        end = next((offset for offset, candidate in enumerate(tail) if "spin_unlock_irqrestore(" in candidate), len(tail))
        if any("mutex_lock(" in candidate for candidate in tail[:end]):
            return False
    return True


def evaluate_0014(sources: Sources) -> tuple[Result, ...]:
    deinit = between(sources.common, "void mpp_session_deinit(", "static void mpp_session_attach_workqueue")
    reset = between(sources.common, "case MPP_CMD_RESET_SESSION:", "case MPP_CMD_TRANS_FD_TO_IOVA:")
    worker = between(sources.common, "static void mpp_task_worker_default(", "static int mpp_wait_result_default")
    wait = between(sources.common, "static int mpp_wait_result_default(", "static int mpp_wait_result(")
    detach = between(sources.common, "static void mpp_detach_workqueue(", "static int mpp_check_cmd_v1")
    attach_ccu = between(sources.rkvenc, "static int rkvenc_attach_ccu(", "static void rkvenc_detach_ccu(")
    irq_release = optional_between(sources.rkvenc, "static void rkvenc_release_irq(", "static void rkvenc_remove(")
    remove = between(sources.rkvenc, "static void rkvenc_remove(", "static void rkvenc_shutdown(")
    return (
        Result("fwport-0040 unlink-before-private-teardown", ordered(deinit, "list_del_init(&session->service_link)", "session->deinit(session)")),
        Result("fwport-0041 clear-dma-before-reset destroy", ordered(reset, "session->dma = NULL", "mpp_dma_session_destroy(dma)")),
        Result("fwport-0052 worker-device guard", "if (unlikely(!mpp))" in worker and "mpp_taskqueue_pop_pending(queue, task)" in worker),
        Result("fwport-0053 wait-device guard", "if (unlikely(!mpp))" in wait and "mpp_session_pop_pending(session, task)" in wait),
        Result("queue publication removed before device detach", ordered(detach, "queue->cores[mpp->core_id] = NULL", "mpp->queue = NULL")),
        Result("failed CCU publication is unlinked", ordered(attach_ccu, "err_detach_core_locked:", "list_del_rcu(&enc->core_link)")),
        Result("service lifetime pins open files", "srv->mpp_cdev.owner = THIS_MODULE" in sources.service and ".suppress_bind_attrs = true" in sources.service),
        Result("IRQ quiesced before state teardown", ordered(irq_release, "disable_irq", "synchronize_irq") and ordered(irq_release, "synchronize_irq", "devm_free_irq") and ordered(remove, "rkvenc_release_irq", "mpp_dev_remove")),
    )


def evaluate_0015(sources: Sources) -> tuple[Result, ...]:
    init = between(sources.rkvenc, "static int rkvenc_init(", "static int rkvenc_exit(")
    clk_on = between(sources.rkvenc, "static int rkvenc_clk_on(", "static int rkvenc_clk_off(")
    dev_probe = between(sources.common, "int mpp_dev_probe(", "int mpp_dev_remove(")
    power_on = between(sources.common, "int mpp_power_on(", "int mpp_power_off(")
    finish = between(sources.common, "int mpp_task_finish(", "int mpp_task_finalize(")
    reset = between(sources.common, "int mpp_dev_reset(", "void mpp_task_run_begin(")
    return (
        Result("required clock acquisition errors propagate", init.count("if (ret)\n\t\treturn ret;") >= 3),
        Result("reset acquisition errors propagate", init.count("IS_ERR(") >= 3 and "PTR_ERR(" in init),
        Result("required IOMMU acquisition errors propagate", "ret = PTR_ERR(mpp->iommu_info)" in dev_probe and "goto failed" in dev_probe),
        Result("runtime PM and clock failures propagate", "pm_runtime_resume_and_get" in power_on and "return ret" in power_on),
        Result("partial clock enable unwinds", ordered(clk_on, "goto err_core", "clk_disable_unprepare(enc->hclk_info.clk)")),
        Result("finish and recovery reset errors propagate", "ret = mpp->dev_ops->finish" in finish and "reset_ret = mpp_dev_reset" in finish),
        Result("hardware reset error propagates", "reset_ret = mpp->hw_ops->reset" in reset and "return reset_ret" in reset),
    )


def evaluate_0019(sources: Sources) -> tuple[Result, ...]:
    return (
        Result("worker never takes a mutex under spin_lock_irqsave", irqsave_blocks_are_atomic(sources.common) and irqsave_blocks_are_atomic(sources.rkvenc)),
        Result("static dma-buf importer uses unlocked entry points", "dma_buf_map_attachment_unlocked(" in sources.iommu and "dma_buf_unmap_attachment_unlocked(" in sources.iommu and "dma_buf_map_attachment(" not in sources.iommu and "dma_buf_unmap_attachment(" not in sources.iommu),
    )


def evaluate_0020(sources: Sources) -> tuple[Result, ...]:
    register = between(sources.common, "int mpp_dev_register_srv(", "irqreturn_t mpp_dev_irq(")
    unregister = optional_between(sources.common, "void mpp_dev_unregister_srv(", "int mpp_dev_register_srv(")
    remove = between(sources.rkvenc, "static void rkvenc_remove(", "static void rkvenc_shutdown(")
    return (
        Result("core unbind withdraws service publication", "srv->sub_devices[device_type] = NULL" in unregister and "clear_bit(device_type, &srv->hw_support)" in unregister),
        Result("RKVENC2 remove unpublishes before teardown", ordered(remove, "mpp_dev_unregister_srv", "rkvenc_release_irq")),
        Result("successful rebind republishes service", "srv->sub_devices[device_type] = mpp" in register and "set_bit(device_type, &srv->hw_support)" in register),
    )


def evaluate_0021(sources: Sources) -> tuple[Result, ...]:
    run = between(sources.common, "static int mpp_task_run(", "void mpp_dev_load(")
    fail_running = between(sources.common, "static void mpp_taskqueue_fail_running(", "static void\nmpp_taskqueue_trigger_work(")
    worker = between(sources.common, "static void mpp_task_worker_default(", "static int mpp_wait_result_default(")
    running = between(sources.common, "static void try_process_running_task(", "static void mpp_task_worker_default(")
    free_task = between(sources.common, "void mpp_free_task(", "static void mpp_task_timeout_work(")
    prepare = between(sources.rkvenc, "static void *rkvenc2_prepare(", "static int rkvenc2_patch_dchs(")
    iommu_attach = between(sources.iommu, "int mpp_iommu_attach(", "static int mpp_iommu_attach_current_domain(")
    after_isr = running.split("mpp->dev_ops->isr(mpp);", maxsplit=1)[-1]
    return (
        Result("failed hw_run releases resources exactly once", run.count("mpp_power_off(mpp)") >= 4 and "mpp_taskqueue_fail_running(queue, task)" in worker and "mpp_task_finish" not in fail_running),
        Result("worker does not reread a released task", "mpp_task" not in after_isr and ordered(fail_running, "wake_up(&task->wait)", "mpp_taskqueue_pop_running(queue, task)") and "if (mpp && mpp->dev_ops->free_task)" in free_task),
        Result("secondary dispatch requires a usable IOMMU domain", "!mpp->iommu_info || !mpp->iommu_info->domain" in prepare and "!info->domain || !info->group" in iommu_attach),
    )


EVALUATORS: Final = {
    "0014": evaluate_0014,
    "0015": evaluate_0015,
    "0019": evaluate_0019,
    "0020": evaluate_0020,
    "0021": evaluate_0021,
}


def load_sources() -> Sources:
    base = ROOT / "drivers/video/rockchip/mpp"
    return Sources(
        common=(base / "mpp_common.c").read_text(),
        iommu=(base / "mpp_iommu.c").read_text(),
        rkvenc=(base / "mpp_rkvenc2.c").read_text(),
        service=(base / "mpp_service.c").read_text(),
    )


def report(intent: str, results: tuple[Result, ...]) -> int:
    passed = sum(result.passed for result in results)
    for result in results:
        print(f"{'PASS' if result.passed else 'FAIL'}: {result.name}")
    print(f"mpp-hardening-{intent}: pass:{passed} fail:{len(results) - passed} total:{len(results)}")
    return 0 if passed == len(results) else 1


def self_test() -> int:
    sources = load_sources()
    baseline = evaluate_0014(sources)
    if len(baseline) != 8:
        return 1
    mutations = (
        replace(sources, common=sources.common.replace("list_del_init(&session->service_link);", "", 1)),
        replace(sources, common=sources.common.replace("session->dma = NULL;", "")),
        replace(sources, service=sources.service.replace("srv->mpp_cdev.owner = THIS_MODULE;", "", 1)),
    )
    for mutation in mutations:
        if all(result.passed for result in evaluate_0014(mutation)):
            return 1
    print("mpp-hardening self-test: pass:3 fail:0 total:3")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--intent", choices=tuple(EVALUATORS))
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    intent = args.intent or "all"
    results = tuple(
        result
        for name, evaluator in EVALUATORS.items()
        if args.intent is None or name == args.intent
        for result in evaluator(load_sources())
    )
    return report(intent, results)


if __name__ == "__main__":
    raise SystemExit(main())
