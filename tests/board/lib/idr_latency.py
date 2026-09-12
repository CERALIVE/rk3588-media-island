#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Score with idr-latency.sh --score: encoder-input timeline to muxed IDR PTS."""

import json
import re
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Final

PTS_MODULUS: Final = 1 << 33
REQUEST_COUNT: Final = 20


@dataclass(frozen=True, slots=True)
class DrillError(Exception):
    reason: str

    def __str__(self) -> str:
        return self.reason


@dataclass(frozen=True, slots=True)
class Frame:
    pts: int
    idr: bool


@dataclass(frozen=True, slots=True)
class InputFrame:
    mono_ns: int
    pts: int


@dataclass(frozen=True, slots=True)
class Request:
    identifier: int
    send_ns: int
    ack_ns: int


@dataclass(frozen=True, slots=True)
class Measurement:
    request_id: int
    first_eligible_pts: int
    idr_pts: int | None
    latency_frames: int | None


def nal_frame(payload: bytes, codec: str) -> bool:
    """Require exactly one picture; parameter sets and extra slices are not frames."""
    nals = re.split(b"\x00\x00\x00?\x01", payload)
    if len(nals) < 2 or nals[0].strip(b"\0"):
        raise DrillError("not an Annex-B access unit")
    pictures = 0
    idr = False
    picture_kind: int | None = None
    for nal in nals[1:]:
        if len(nal) < 2 or nal[0] & 0x80:
            raise DrillError("truncated/invalid NAL header")
        match codec:
            case "hevc":
                kind = (nal[0] >> 1) & 63
                is_picture_slice = kind <= 31
                if nal[1] & 7 == 0 or (nal[0] & 1) or (nal[1] >> 3):
                    raise DrillError("invalid or multilayer HEVC header")
                if kind <= 31:
                    if len(nal) < 3:
                        raise DrillError("truncated HEVC slice")
                    pictures += bool(nal[2] & 0x80)
                    idr |= kind in (19, 20)
            case "h264":
                kind = nal[0] & 31
                is_picture_slice = kind in (1, 5)
                if kind in (1, 5):
                    # first_mb_in_slice is ue(v); zero is the single leading 1 bit.
                    pictures += bool(nal[1] & 0x80)
                    idr |= kind == 5
                elif kind in (2, 3, 4, 20, 21):
                    raise DrillError("partitioned/extended AVC is outside this drill")
            case _:
                raise DrillError(f"unsupported codec: {codec}")
        if is_picture_slice:
            if picture_kind is not None and kind != picture_kind:
                raise DrillError("inconsistent NAL slice kinds in one picture")
            picture_kind = kind
    if pictures != 1:
        raise DrillError(f"expected one picture per demuxed packet, found {pictures}")
    return idr


def read_frames(recording: Path) -> list[Frame]:
    command = ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_streams",
               "-show_packets", "-show_data", "-show_entries",
               "stream=codec_name,time_base:packet=pts,dts,size,data", "-of", "json", str(recording)]
    result = subprocess.run(command, check=True, capture_output=True, text=True, timeout=120)
    if result.stderr.strip():
        raise DrillError(f"ffprobe reported corruption: {result.stderr.strip()}")
    document = json.loads(result.stdout)
    streams = document.get("streams", [])
    if len(streams) != 1 or streams[0].get("time_base") != "1/90000":
        raise DrillError("one MPEG-TS video stream with 90 kHz PTS required")
    frames: list[Frame] = []
    for packet in document.get("packets", []):
        pts = int(packet["pts"])
        if int(packet["dts"]) != pts:
            raise DrillError("reordered output is outside the zero-B-frame drill")
        data = bytearray()
        for line in packet["data"].splitlines():
            if line.strip():
                hexadecimal = line.split(":", 1)[1].split("  ", 1)[0]
                data.extend(bytes.fromhex(hexadecimal))
        if len(data) != int(packet["size"]):
            raise DrillError("packet hexdump length mismatch")
        frames.append(Frame(pts % PTS_MODULUS, nal_frame(bytes(data), streams[0]["codec_name"])))
    if not frames or len({frame.pts for frame in frames}) != len(frames):
        raise DrillError("empty recording or duplicate output PTS")
    return frames


def read_inputs(path: Path) -> list[InputFrame]:
    rows: list[InputFrame] = []
    for line in path.read_text().splitlines():
        mono_ns, pts = map(int, line.split("\t"))
        if mono_ns < 0 or pts < 0 or (rows and mono_ns <= rows[-1].mono_ns):
            raise DrillError("input timestamps must be nonnegative and strictly increasing")
        rows.append(InputFrame(mono_ns, pts % PTS_MODULUS))
    if not rows or len({row.pts for row in rows}) != len(rows):
        raise DrillError("empty/duplicate input timeline")
    return rows


def read_requests(path: Path) -> list[Request]:
    rows: list[Request] = []
    for line in path.read_text().splitlines():
        identifier, sent, ack, applied = map(int, line.split("\t"))
        if identifier != len(rows) + 1 or applied != 1 or sent < 0 or ack < sent:
            raise DrillError("missing, rejected, or invalid request acknowledgement")
        if rows and sent <= rows[-1].ack_ns:
            raise DrillError("overlapping requests cannot be attributed")
        rows.append(Request(identifier, sent, ack))
    if len(rows) != REQUEST_COUNT:
        raise DrillError(f"expected {REQUEST_COUNT} acknowledged requests, got {len(rows)}")
    return rows


def score(recording: Path, timeline: Path, requests: Path, pts_offset: int) -> list[Measurement]:
    """The four inputs are distinct evidence artifacts plus their clock alignment."""
    frames = read_frames(recording)
    inputs = read_inputs(timeline)
    calls = read_requests(requests)
    expected = [(frame.pts + pts_offset) % PTS_MODULUS for frame in inputs]
    if expected != [frame.pts for frame in frames]:
        raise DrillError("input/output PTS sequences differ: loss, misalignment, or incomplete trace")
    rows: list[Measurement] = []
    for index, request in enumerate(calls):
        start = next((i for i, frame in enumerate(inputs) if frame.mono_ns >= request.send_ns), None)
        if start is None or start == 0:
            raise DrillError("request is not bracketed by the captured input timeline")
        end_ns = calls[index + 1].send_ns if index + 1 < len(calls) else inputs[-1].mono_ns + 1
        found = next((i for i in range(start, len(inputs))
                      if inputs[i].mono_ns < end_ns and frames[i].idr), None)
        rows.append(Measurement(request.identifier, frames[start].pts,
                                frames[found].pts if found is not None else None,
                                found - start + 1 if found is not None else None))
    return rows


if __name__ == "__main__":
    try:
        measurements = score(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), int(sys.argv[4]))
        passed = all(row.latency_frames == 1 for row in measurements)
        print(json.dumps({"verdict": "PASS" if passed else "FAIL", "requests": [asdict(row) for row in measurements]}))
        sys.exit(0 if passed else 1)
    except (DrillError, OSError, ValueError, KeyError, IndexError, subprocess.SubprocessError) as error:
        print(f"INCOMPLETE: {error}", file=sys.stderr)
        sys.exit(1)
