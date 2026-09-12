#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Use idr-latency.sh --request under the external board lock, on the engine host."""

import json
import socket
import sys
import time
from pathlib import Path
from typing import BinaryIO

from idr_latency import DrillError, REQUEST_COUNT


def receive(stream: BinaryIO, identifier: int) -> str:
    for _ in range(1000):
        line = stream.readline(1048577)
        if not line or len(line) > 1048576 or not line.endswith(b"\n"):
            raise DrillError("IPC EOF or oversized/incomplete response")
        response = json.loads(line)
        if "id" not in response:
            continue
        if response["id"] != identifier or response.get("jsonrpc") != "2.0" or "error" in response:
            raise DrillError(f"IPC rejected/mismatched response: {line.decode().strip()}")
        return json.dumps(response["result"])
    raise DrillError("IPC event budget exceeded")


def request_keyframes(address: str, output: Path, interval: float = 1.0) -> None:
    with output.open("x") as transcript, socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(address)
        with connection.makefile("rb") as incoming:
            hello = {"jsonrpc": "2.0", "id": 0, "method": "hello",
                     "params": {"protocol": "cerastream-ipc/1", "client": "island-idr-latency/1"}}
            connection.sendall(json.dumps(hello).encode() + b"\n")
            if json.loads(receive(incoming, 0)).get("protocol") != "cerastream-ipc/1":
                raise DrillError("IPC protocol mismatch")
            for identifier in range(1, REQUEST_COUNT + 1):
                request = json.dumps({"jsonrpc": "2.0", "id": identifier, "method": "request-keyframe"}).encode() + b"\n"
                sent = time.monotonic_ns()
                connection.sendall(request)
                result = json.loads(receive(incoming, identifier))
                acknowledged = time.monotonic_ns()
                applied = result.get("applied") is True
                transcript.write(f"{identifier}\t{sent}\t{acknowledged}\t{int(applied)}\n")
                transcript.flush()
                if not applied:
                    raise DrillError(f"request {identifier} was not applied")
                if identifier < REQUEST_COUNT:
                    time.sleep(interval)


if __name__ == "__main__":
    try:
        request_keyframes(sys.argv[1], Path(sys.argv[2]))
    except (DrillError, OSError, ValueError, KeyError, IndexError) as error:
        print(f"INCOMPLETE: {error}", file=sys.stderr)
        sys.exit(1)
