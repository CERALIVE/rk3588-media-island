# RKVDEC-v1 diagnostic comparison

**Verdict: pre-existing dormant-code port errors, not a modernization regression.**
RKVDEC-v1 is intentionally unselected by project policy. This audit does not
enable it or change its source to make unrelated diagnostics disappear.

## Compared inputs

- Before this PR: `10894bc5347bfd0ce37ed9e6adb6d64949b5ba1c` (`origin/main`
  when the comparison ran).
- PR source: `0ec331c907820c7e32d1157ca6a23cadd5829366`.
- File: `drivers/video/rockchip/mpp/mpp_rkvdec.c`, **not** the selected
  `mpp_rkvdec2.c`.
- Each revision's own MPP source and headers were extracted independently.
  Both were checked against the same configured arm64 Linux v7.2 headers at
  `8d3ae59288f1e7d58d76558a6ee96d533bc5019f`.
- Standalone `aarch64-linux-gnu-gcc` syntax checking used the recorded MPP Kbuild
  flags, replacing object compilation with `-fsyntax-only`. Both commands exited
  **1** with the same eight source/API error classes below. These are genuine
  compiler errors if the file is compiled, not missing-include messages.

## Normalized comparison

Line numbers are one-based. The PR adds eight lines before these unchanged call
sites, so a line-number shift is not a new diagnostic.

| Diagnostic | Base line | PR line | Result |
|---|---:|---:|---|
| `mpp_translate_reg_address`: argument 5 is a pointer but the API expects `u32 reg_cnt` | 645 | 653 | Identical |
| `mpp_translate_reg_address`: expected 6 arguments, supplied 5 | 644 | 652 | Identical |
| `mpp_translate_reg_offset_info`: expected 4 arguments, supplied 3 | 649 | 657 | Identical |
| `iommu_map`: expected 6 arguments, supplied 5 | 1215 | 1223 | Identical |
| `rockchip_pmu_pd_is_on`: implicit declaration | 1446 | 1454 | Identical |
| `rockchip_pmu_pd_on`: implicit declaration | 1448 | 1456 | Identical |
| `rockchip_pmu_pd_off`: implicit declaration | 1471 | 1479 | Identical |
| `.remove = rkvdec_remove`: `int` callback supplied to the mainline `void` callback slot | 1920 | 1928 | Identical |

Representative compiler output from **both** runs:

```text
error: too few arguments to function 'mpp_translate_reg_address'; expected 6, have 5
error: too few arguments to function 'mpp_translate_reg_offset_info'; expected 4, have 3
error: too few arguments to function 'iommu_map'; expected 6, have 5
error: implicit declaration of function 'rockchip_pmu_pd_is_on'
error: implicit declaration of function 'rockchip_pmu_pd_on'
error: implicit declaration of function 'rockchip_pmu_pd_off'
error: initialization of 'void (*)(struct platform_device *)' from incompatible pointer type 'int (*)(struct platform_device *)'
```

## History evidence

Every failing caller above blames to the pre-PR import commit **`ef617115`** in
both revisions. The MPP translator's added count parameters blame to
**`e83b4155`**, also before this PR. Linux v7.2's `iommu_map` requires its trailing
allocation flags, and `struct platform_driver.remove` returns `void`; the
retained v1 caller still uses the older signatures.

Examples that reproduce the relevant history without changing a checkout:

```bash
git blame 10894bc -L 644,650 -- drivers/video/rockchip/mpp/mpp_rkvdec.c
git blame 0ec331c -L 652,658 -- drivers/video/rockchip/mpp/mpp_rkvdec.c
git blame 10894bc -L 642,656 -- drivers/video/rockchip/mpp/mpp_common.h
git diff 10894bc 0ec331c -- drivers/video/rockchip/mpp/mpp_rkvdec.c
git show 7f3fd7a -- drivers/video/rockchip/mpp/mpp_rkvdec.c
```

The files are **not byte-identical** across this PR. `7f3fd7a` changes the
scaling-list function to bounded, reservation-protected `iosys_map` access;
`mpp_common.h` also gains private modernization helpers and state. Neither
change adds to or worsens the normalized compiler diagnostic set. The scaling
function itself produced no new error in the comparison.

Raw comparison artifacts are retained under the audit checkout's
`.work/rkvdec-v1-audit/`: `base-gcc.command`, `pr-gcc.command`, `base-gcc.log`,
`pr-gcc.log`, `blame.log`, `common-base.blame`, `common-pr.blame`, and
`rkvdec.diff.log`. Clang reproduction also found the same source errors; initial
IncludeCleaner failures were excluded as tooling setup errors, not used as
evidence of source parity.

This is an out-of-scope, intentionally unselected client—not an unfinished
modernization acceptance item and not a reason to add stubs or enable a fourth
MPP client. Any future v1 port needs its own explicit authorization and tests.
