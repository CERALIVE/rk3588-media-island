#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Run through idr-latency.sh --self-test; fixtures are real recorded MPEG-TS."""

import json
import socket
import subprocess
import tempfile
from pathlib import Path
from threading import Thread


def self_test() -> None:
    from idr_latency import DrillError, nal_frame, read_frames, score
    from idr_rpc import request_keyframes

    # Given: two slices of one HEVC IDR, and a CRA (which is NOT an IDR).
    assert nal_frame(b"\0\0\1\x26\x01\x80\0\0\1\x26\x01\x00", "hevc")
    assert not nal_frame(b"\0\0\1\x2a\x01\x80", "hevc")
    assert nal_frame(b"\0\0\1\x65\x80", "h264")
    for malformed in (b"", b"\0\0\1\x26", b"\0\0\1\x26\x01\x80\0\0\1\x26\x01\x80"):
        try:
            nal_frame(malformed, "hevc")
        except DrillError:
            continue
        raise AssertionError("malformed/ambiguous access unit accepted")

    # Given: a non-IDR first slice followed by an IDR continuation slice.
    # When: parsing either codec. Then: reject corruption, never score an IDR.
    for codec, payload in (
        ("h264", b"\0\0\1\x41\x80\0\0\1\x65\x40"),
        ("hevc", b"\0\0\1\x02\x01\x80\0\0\1\x26\x01\x00"),
    ):
        try:
            nal_frame(payload, codec)
        except DrillError:
            continue
        raise AssertionError(f"mixed {codec} slice kinds accepted as an IDR")

    with tempfile.TemporaryDirectory(prefix="idr-selftest-") as directory:
        root = Path(directory)
        for codec, encoder in (("h264", "libx264"), ("hevc", "libx265")):
            recording = root / f"{codec}.ts"
            params = ["-x264-params", "scenecut=0:keyint=10:min-keyint=10"]
            if codec == "hevc":
                params = ["-x265-params", "pools=1:frame-threads=1:scenecut=0:keyint=10:min-keyint=10:open-gop=0:log-level=error"]
            command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                       "testsrc2=size=64x64:rate=30", "-frames:v", "210", "-c:v", encoder,
                       "-threads", "1", "-bf", "0", *params, "-f", "mpegts", str(recording)]
            subprocess.run(command, check=True, timeout=60, capture_output=True)
            frames = read_frames(recording)
            # Then: the NAL parser (not ffprobe key_frame flags) finds the known GOPs.
            assert len(frames) == 210
            assert [i for i, frame in enumerate(frames) if frame.idr] == list(range(0, 210, 10))

            timeline = root / "input.tsv"
            requests = root / "requests.tsv"
            timeline.write_text("".join(f"{i * 1000 + 1000}\t{frame.pts}\n" for i, frame in enumerate(frames)))
            requests.write_text("".join(f"{i}\t{i * 10000 + 500}\t{i * 10000 + 600}\t1\n" for i in range(1, 21)))
            # When: request is sent between input 9 and 10, then 19 and 20, etc.
            rows = score(recording, timeline, requests, 0)
            assert len(rows) == 20 and all(row.latency_frames == 1 for row in rows)

            # Given: move request 1 back one input frame. Then: retain its FAIL=2.
            text = requests.read_text()
            requests.write_text(text.replace("1\t10500\t10600", "1\t9500\t9600"))
            rows = score(recording, timeline, requests, 0)
            assert rows[0].latency_frames == 2
            assert len(rows) == 20
            requests.write_text(text)

            # Given: missing output/input or failed acknowledgement never passes.
            for broken in (text.replace("\t1\n", "\t0\n", 1), "", text.rsplit("\n", 2)[0] + "\n"):
                requests.write_text(broken)
                try:
                    score(recording, timeline, requests, 0)
                except DrillError:
                    continue
                raise AssertionError("incomplete/rejected request set accepted")
            requests.write_text(text)
            timeline.write_text(timeline.read_text().split("\n", 1)[1])
            try:
                score(recording, timeline, requests, 0)
            except DrillError:
                pass
            else:
                raise AssertionError("incomplete input timeline accepted")
            print(f"PASS recorded {codec}: 210 frames, 21 IDRs, 20 latency=1; late/incomplete negatives")

        # Given: a real UDS peer verifies handshake, method, ids and NDJSON framing.
        address = str(root / "control.sock")
        received: list[str] = []
        failures: list[str] = []
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(address)
            listener.listen(1)
            listener.settimeout(5)

            def serve() -> None:
                try:
                    connection, _ = listener.accept()
                    with connection, connection.makefile("rwb", buffering=0) as stream:
                        for index in range(21):
                            message = json.loads(stream.readline())
                            received.append(message["method"])
                            result = {"protocol": "cerastream-ipc/1"} if index == 0 else {"applied": True}
                            # An unsolicited event and split response exercise the reader.
                            stream.write(b'{"jsonrpc":"2.0","method":"event"}\n')
                            reply = json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}).encode() + b"\n"
                            stream.write(reply[:7])
                            stream.write(reply[7:])
                except (OSError, ValueError, KeyError) as error:
                    failures.append(str(error))

            thread = Thread(target=serve)
            thread.start()
            request_keyframes(address, root / "sent.tsv", interval=0)
            thread.join(timeout=5)
            assert not thread.is_alive() and not failures
            assert received == ["hello"] + ["request-keyframe"] * 20
            assert len((root / "sent.tsv").read_text().splitlines()) == 20
            print("PASS real UDS: hello + 20 request-keyframe acknowledgements")


if __name__ == "__main__":
    self_test()
