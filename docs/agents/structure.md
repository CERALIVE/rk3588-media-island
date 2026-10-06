<!-- Moved verbatim from AGENTS.md on 2026-10-05 by lean-rules-docs-landing-latam -->

## STRUCTURE

```
rk3588-media-island/
├── kernel-pin.env               # MIRROR of rk3588-kernel-patches' kernel coordinate
├── drivers/video/rockchip/
│   ├── mpp/                     # MPP service + RKVENC2/RKVDEC2/JPGDEC
│   │   └── compat/              # compat shims NEST HERE — there is no root-level compat/
│   └── rga3/                    # multi_rga
├── include/uapi/linux/          # UAPI headers the drivers publish
├── integration/                 # applied patches: build hooks, providers, MPP DT ownership
│   └── pending/                 # linted but unshipped RGA2/RGA3 ownership flips
├── patches/                     # GENERATED series — never hand-edited
├── scripts/                     # series generation, provenance, lint tooling
│   ├── build-series.py          # drivers/ + integration/ -> patches/ ; --check byte-compares
│   ├── verify-series-parity.py  # the SECOND, independent opinion — never imports the generator
│   ├── check-compat-shims.py    # shim-lint: the docs/COMPAT.md 5-step specification
│   ├── check-dt-ownership.py    # dt-ownership-lint: the one-compatible rule
│   ├── check-upstream-freshness.py  # the issue-only watch's comparison
│   └── check-action-pins.sh     # every `uses:` against gh api releases/latest
├── tests/
│   ├── board/                   # hardware-gated drills, probes and fixtures
│   ├── kunit/                   # in-kernel unit tests
│   └── fuzz/                    # UAPI fuzz targets
└── docs/
    ├── COMPAT.md                # shim + external-symbol inventory; ALSO the shim-lint input
    ├── KEEP-STUB.md             # deliberate stubs and their reopening conditions
    ├── OWNERSHIP.md             # silicon ownership table; ALSO the dt-ownership-lint input
    ├── REFERENCES.md            # every pinned coordinate
    ├── PROVENANCE.md            # per-file import ledger
    ├── VENDOR-BACKLOG.md        # exhaustive post-donor vendor PICK/SKIP ledger
    ├── UPSTREAM-STATUS.md       # mainline movement; the issue-only watch
    ├── TELEMETRY.md             # tracefs/debugfs schemas + frozen proc formats
    └── BOARD-QUALIFICATION.md   # what real hardware must demonstrate
```

