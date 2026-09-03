# Orange Pi 5+ telemetry capture

Captured verbatim on 2026-09-03 during todo 16 scenario 1, two concurrent
4K30 H.265 GStreamer processes. The board ran Linux
`7.2.0-ceralive-rk3588` built from island branch commit
`b85c63e97cbcd293cf384ac149d3370e4f4d953b`; the deployed `Image` SHA-256
was `e93fcfcab6ce7e523fd6073dffb2dd4bc25d390ef6db5ad4077c01a388af1186`.
`load_interval` was set to 1000 ms.

The three `load-*.txt` files and `sessions-summary-2-sessions.txt` are direct
`cat` captures with no normalization. The live `sessions-summary` contains
additional IOVA and encoder-table rows beyond the abbreviated format currently
documented in `docs/TELEMETRY.md`; the fixture intentionally preserves that
measured schema drift.

`rga-load.txt` is empty because `/proc/rkrga/load` did not exist. RGA ownership
remains pending until the later RGA flip, so `rga3` is intentionally not loaded
on this MPP-only image. The failed read was retained as a measured missing
surface rather than replaced with fabricated content.
