# RKVENC fault campaign

This ledger records whether each CeraLive hardening intent was already present
in the imported yisding source or required a CeraLive fix. Board-only results
remain pending until the later board gate; workstation KUnit and script
self-tests are not presented as hardware evidence.

## Intent ledger

| Intent | Terminal state | Imported overlap | Permanent evidence |
|---|---|---|---|
| `0008` DMA max-segment size and register-derived IOVA guardrail | **RED → fix → GREEN** | No yisding member sets the device DMA maximum; the imported translator added an unchecked offset to the mapped IOVA | `mpp_iova_offset_guardrail_test` was RED at 10/11 and is GREEN at 11/11 after rejecting offsets outside `[iova, iova+len)`; `mpp_dev_probe()` now sets and reads back `DMA_BIT_MASK(32)` before runtime-PM setup |
| `0013` deterministic negative-path instrumentation | **RED → fix → GREEN** | No fwport member provides one-shot fault controls or consumed counters | `mpp_fault_flag_is_one_shot_test` and `mpp_fault_delay_is_one_shot_test` exercise the production atomic consume helpers used by six opt-in debugfs controls; hooks cover service/CCU attach, IRQ request, clock enable after PM acquisition, RKVENC2 session allocation, and task-completion delay |
| `0016` request shape and result-window bounds | **RED → fix → GREEN** | `fwport-0054`, local commit `4eb6e05`, stable patch-id `58dbb9c8f035bde19094933b48d1dbc7b3df749e`; `fwport-0076`, local commit `e83b415`, stable patch-id `2d2b3598b8213d71cc692151d2bc12c4fe1f9182` | `mpp_req_shape_rejects_*`, `mpp_req_result_window_uses_actual_buffer_test`, and decoder/JPGDEC boundary cases in `tests/kunit/mpp_request_bounds_test.c` |
| `0022` class coverage, element and request-count bounds | **RED → fix → GREEN** | `fwport-0062`, local commit `6ed2da0`, stable patch-id `3e228bc54c1b53228a2cf98f53a840edf163962f`; `fwport-0076` as above | Explicit `mpp_req_hevc_sqi_scl_span_test` accepts the 3,228-byte SQI+SCL programme with its 24-byte map hole; `mpp_req_class_overrun_rejected_test` requires `-EINVAL`; element/count cases remain permanent |
| `0026`-class decoder/JPGDEC bounds | **RED → fix → GREEN** | Shared request validation from `fwport-0054`/`0076`; no claim that HDMI-RX patch `0026` is an MPP change | `mpp_req_rkvdec2_bounds_test` and `mpp_req_jpgdec_bounds_test` exercise the production helper used by `mpp_check_req()` |

Rows for `0014`–`0015` and `0019`–`0021` are added with their
terminal evidence by the board/lifecycle part of this campaign; an absent row
is not a pass.

## Test-first transcript

Intent `0013` began with a model of the imported read-only flag behavior. The
one-shot test detected that an armed fault fired twice, never disarmed, and did
not increment its consumed counter:

```text
rockchip-mpp-request-bounds: pass:11 fail:0 skip:0 total:11
rockchip-mpp-fault-injection: pass:0 fail:1 skip:0 total:1
Testing complete. Ran 12 tests: passed: 11, failed: 1
FAILED: mpp_fault_flag_is_one_shot_test
```

After commit `18bd843` added the atomic production helper and wired the six
test-only controls into RKVENC2, the identical KUnit command reported:

```text
rockchip-mpp-request-bounds: pass:11 fail:0 skip:0 total:11
rockchip-mpp-fault-injection: pass:2 fail:0 skip:0 total:2
Testing complete. Ran 13 tests: passed: 13, failed: 0
```

Intent `0008` first ran against an extracted helper preserving the imported
unchecked behavior:

```text
INTENT_0008_RED_RC=1
rockchip-mpp-request-bounds: pass:10 fail:1 skip:0 total:11
FAILED: mpp_iova_offset_guardrail_test
```

After the guardrail and DMA segment-size probe fix, the same suite reported
`pass:11 fail:0 total:11`.

The extracted helper initially preserved the imported behaviour. Running the
pinned Linux 7.2 KUnit suite before the fix produced:

```text
RED_AGAINST_IMPORT_RC=1
rockchip-mpp-request-bounds: pass:5 fail:5 skip:0 total:10
FAILED: mpp_req_shape_rejects_unaligned_test
FAILED: mpp_req_element_count_rejects_odd_size_test
FAILED: mpp_req_result_window_uses_actual_buffer_test
FAILED: mpp_req_class_overrun_rejected_test
FAILED: mpp_req_jpgdec_bounds_test
```

After enforcing dword alignment, complete elements, actual class-buffer
windows, and the class-map clipping rule, the identical command produced:

```text
rockchip-mpp-request-bounds: pass:10 fail:0 skip:0 total:10
Testing complete. Ran 10 tests: passed: 10
```

Command:

```sh
./.work/linux/tools/testing/kunit/kunit.py run \
  --kunitconfig="$PWD/tests/kunit" \
  --build_dir="$PWD/.work/kunit"
```

## Non-vacuity mutations

Three independent mutations were applied one at a time to the production
helper, copied into the pinned tree, run through the same KUnit command, and
then restored before the next mutation:

```text
remove dword-alignment guard:
  pass:8 fail:2 total:10; MUTATION_ALIGNMENT_RC=1
  failed unaligned-shape and JPGDEC-alignment cases

remove whole-element remainder guard:
  pass:9 fail:1 total:10; MUTATION_ELEMENTS_RC=1
  failed mpp_req_element_count_rejects_odd_size_test

bypass class-map coverage check:
  pass:9 fail:1 total:10; MUTATION_COVERAGE_RC=1
  failed mpp_req_class_overrun_rejected_test
```

These mutations prove the tests are sensitive to their named guarantees. They
do not substitute for the required GREEN-ON-IMPORT fwport-revert proofs in the
remaining lifecycle rows.

## Board boundary

No board was accessed for this change. The cold-boot per-codec encode and
runtime fault campaign remain hardware-gated; their later transcripts must name
the board, kernel build, and island revision.
