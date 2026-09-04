# librga 2.2.0 compatibility with the island RGA ABI

The island deliberately reports `DRIVER_VERSION` **1.3.11**. Raising that value
without implementing the corresponding Rockchip driver contract would make
librga select behavior the kernel has not earned.

## Verification coordinate and method

Radxa's librga 2.2.0 source was verified at immutable commit
[`73300181798b48301f44ef44f232f85ec4c67948`](https://github.com/tsukumijima/librga-rockchip/tree/73300181798b48301f44ef44f232f85ec4c67948);
its `meson.build` declares version 2.2.0. The audit searched `core/` and
`im2d_api/` for `RGA_IOC_GET_DRVIER_VERSION`, `1.3.13`, `1.3.11`, `1.3.0`,
`1.2.4`, `RGA_DRIVER_FEATURE_USER_CLOSE_FENCE`, and every close of an input
fence. No `1.3.13` or `1.3.11` runtime predicate exists in that source.

## Version-dependent call paths

| librga call path | Predicate in 2.2.0 | Result for island 1.3.11 | Difference below 1.3.13 |
|---|---|---|---|
| `NormalRgaOpen()` multicore probe | `RGA_IOC_GET_DRVIER_VERSION` returns success | Multicore mode; hardware-version query follows | None based on 1.3.13; only ioctl failure selects the legacy `RGA2_GET_VERSION` / `RGA_GET_VERSION` fallback |
| `RgaInit()` → `rga_check_driver()` | binding-table floor 1.2.4 | Accepted | None between 1.2.4 and 1.3.13 |
| `rga_set_driver_feature()` | driver version is greater than 1.3.0 | `RGA_DRIVER_FEATURE_USER_CLOSE_FENCE` enabled | Drivers at or below 1.3.0 omit this feature; 1.3.11 does not |
| normal blit input-fence completion | user-close-fence feature set | request advertises `user_close_fence`; librga closes the input fence after submit | Same behavior through the whole `(1.3.0, 1.3.13)` interval |
| `RgaColorFill()` input-fence completion | user-close-fence feature set | same as normal blit | Same behavior through the whole `(1.3.0, 1.3.13)` interval |
| `RgaCollorPalette()` input-fence completion | user-close-fence feature set | same as normal blit | Same behavior through the whole `(1.3.0, 1.3.13)` interval |

Therefore **no librga 2.2.0 call path behaves differently merely because the
island reports 1.3.11 rather than at least 1.3.13**. The effective thresholds
are ioctl success, driver floor 1.2.4, and user-close-fence `> 1.3.0`.

Primary source locations at the immutable coordinate:

- [`core/NormalRga.cpp` lines 63-66 and 86-132](https://github.com/tsukumijima/librga-rockchip/blob/73300181798b48301f44ef44f232f85ec4c67948/core/NormalRga.cpp)
- [`im2d_api/src/im2d_hardware.h` driver binding table](https://github.com/tsukumijima/librga-rockchip/blob/73300181798b48301f44ef44f232f85ec4c67948/im2d_api/src/im2d_hardware.h)
- [`im2d_api/src/im2d_impl.cpp` version comparison and driver check](https://github.com/tsukumijima/librga-rockchip/blob/73300181798b48301f44ef44f232f85ec4c67948/im2d_api/src/im2d_impl.cpp)
