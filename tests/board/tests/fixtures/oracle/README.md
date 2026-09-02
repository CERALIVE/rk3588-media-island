# The encode-corruption oracle fixture

`testsrc2-640x360-30fps-60f.nv12` — 60 frames of raw NV12, 640×360, 30 fps.
Exactly 20 736 000 bytes (`640 × 360 × 3 / 2 × 60`).

## Why a file and not `videotestsrc`

The defect this fixture exists to detect is **content-sensitive**. A live
pattern source varies its output between runs, between boards and between
GStreamer versions, which would make the per-run PSNR spread meaningless — and
that spread is the entire verdict. The input must be one fixed sequence of
bytes, identical on the dev host, on the Rock 5B+, on the Orange Pi 5+, and in
every later island comparison.

`encode-psnr-oracle.sh` asserts the checksum before every run and refuses to
score without it. A measurement taken against an unverified input is not a
measurement.

## How it was generated

Generated once, on a dev host, and then never regenerated:

```bash
ffmpeg -f lavfi -i "testsrc2=size=640x360:rate=30:duration=2" \
       -pix_fmt nv12 -f rawvideo testsrc2-640x360-30fps-60f.nv12
sha256sum testsrc2-640x360-30fps-60f.nv12 > testsrc2-640x360-30fps-60f.nv12.sha256
```

`testsrc2` is the source yisding's own reproduction used. Do **not** regenerate
this file to "refresh" it: a new checksum invalidates every previously recorded
row, because those rows were scored against different bytes.

## Recorded properties

| property | value |
|---|---|
| resolution | 640×360 |
| pixel format | NV12 (4:2:0, two planes) |
| frame rate | 30/1 |
| frames | 60 |
| bytes | 20 736 000 |
| SHA-256 | see `testsrc2-640x360-30fps-60f.nv12.sha256` |

## Reference scores

Taken on the dev host with `libx264 -qp 26 -g 30 -bf 0`, which is what
`encode-psnr-oracle.sh --self-test` reproduces. They are the calibration for
the 35 dB floor: a clean fixed-QP encode sits far above it, and a genuinely
degraded one sits far below.

| stream | mean PSNR | frames < 35 dB | verdict |
|---|---|---|---|
| straight encode | 48.72 dB | 0 / 60 | CLEAN |
| temporally smeared (`tmix=frames=8`) | 25.17 dB | 59 / 60 | DIRTY |

The smeared stream also reproduces the real defect's **bimodal** shape: the one
frame above the floor is the head of the sequence, where the smear window has
not filled yet. That is the same "low body with high islands" signature the
hardware defect shows.
