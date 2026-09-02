#!/usr/bin/env python3
"""uapi-parity: the MPP ioctl contract, held to its two pinned sources.

`/dev/mpp_service` is an ABI with two ends that were written independently: the
kernel's `include/uapi/linux/rk-mpp.h` and userspace's `osal/inc/mpp_service.h`
in `librockchip-mpp`. They agree on VALUES, not on spellings -- the kernel calls
the payload `void __user *data` and userspace calls it `RK_U64 data_ptr` -- so
the only thing worth asserting is the numbers and the layout.

THREE LAYERS, AND ONLY TWO OF THEM CAN RUN TODAY
------------------------------------------------
1. The pinned expectations in `tests/board/uapi/rk-mpp-uapi.h`, transcribed from
   both sources at their recorded SHAs. Parsed and checked here.
2. An INDEPENDENT re-derivation of the ioctl encoding in Python, so the header's
   own `_Static_assert` and this test cannot both be wrong in the same way. A
   test that only re-read the constant the header defines would prove nothing.
3. The island's own `include/uapi/linux/rk-mpp.h` against (1). That header does
   not exist yet -- the driver import creates it -- so this layer SKIPS with an
   explicit reason and becomes required the moment the file appears.

Layer 3 is deliberately a skip and NOT a pass. A green result for a comparison
that had nothing to compare is the failure mode this file exists to avoid, so
the skip names the missing file and the todo that creates it.

Run: python3 -m unittest discover -s tests/uapi -v
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VENDOR_FIXTURE = ROOT / "tests" / "board" / "uapi" / "rk-mpp-uapi.h"
ISLAND_HEADER = ROOT / "include" / "uapi" / "linux" / "rk-mpp.h"

# The values both pinned sources agree on. Written out rather than read from the
# fixture, because a test that derives its expectations from the file under test
# can only ever prove the file agrees with itself.
EXPECTED_COMMANDS = {
    "MPP_CMD_QUERY_BASE": 0x000,
    "MPP_CMD_PROBE_HW_SUPPORT": 0x000,
    "MPP_CMD_QUERY_HW_ID": 0x001,
    "MPP_CMD_QUERY_CMD_SUPPORT": 0x002,
    "MPP_CMD_INIT_BASE": 0x100,
    "MPP_CMD_INIT_CLIENT_TYPE": 0x100,
    "MPP_CMD_INIT_DRIVER_DATA": 0x101,
    "MPP_CMD_INIT_TRANS_TABLE": 0x102,
    "MPP_CMD_SEND_BASE": 0x200,
    "MPP_CMD_SET_REG_WRITE": 0x200,
    "MPP_CMD_SET_REG_READ": 0x201,
    "MPP_CMD_POLL_BASE": 0x300,
    "MPP_CMD_POLL_HW_FINISH": 0x300,
    "MPP_CMD_CONTROL_BASE": 0x400,
    "MPP_CMD_RESET_SESSION": 0x400,
}

# The three MPP clients the island compiles, and nothing else. Their values are
# the bit positions `MPP_CMD_PROBE_HW_SUPPORT` answers with, so an extra entry
# here would let the harness address silicon no island driver drives.
EXPECTED_CLIENTS = {
    "MPP_CLIENT_RKVDEC": 9,
    "MPP_CLIENT_RKJPEGD": 13,
    "MPP_CLIENT_RKVENC": 16,
}

MPP_REQUEST_BYTES = 24

ENUM_BLOCK = re.compile(r"enum\s+\w+\s*\{(.*?)\}\s*;", re.DOTALL)
ENUMERATOR = re.compile(r"([A-Z][A-Z0-9_]*)\s*(?:=\s*([^,}]+))?")
DEFINE = re.compile(r"^\s*#\s*define\s+([A-Za-z_]\w*)\s+(.+?)\s*$", re.MULTILINE)


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", " ", text)


def parse_enumerators(text: str) -> dict[str, int]:
    """Every enumerator in the file, with C's implicit-increment semantics."""
    values: dict[str, int] = {}
    for block in ENUM_BLOCK.findall(strip_comments(text)):
        cursor = 0
        for name, expression in ENUMERATOR.findall(block):
            if expression is None or not expression.strip():
                values[name] = cursor
            else:
                values[name] = evaluate(expression.strip(), values)
            cursor = values[name] + 1
    return values


def evaluate(expression: str, symbols: dict[str, int]) -> int:
    """A deliberately tiny evaluator: integers, known symbols, `+` and `-`.

    Anything richer would be a C parser, and a C parser in a parity test is a
    second implementation that can disagree with the compiler. The fixture is
    written to stay inside this grammar precisely so the test stays honest.
    """
    total = 0
    sign = 1
    for token in re.findall(r"[+-]|0[xX][0-9a-fA-F]+|\d+|[A-Za-z_]\w*", expression):
        if token == "+":
            sign = 1
        elif token == "-":
            sign = -1
        elif token in symbols:
            total += sign * symbols[token]
        else:
            total += sign * int(token, 0)
    return total


def parse_defines(text: str) -> dict[str, str]:
    return {name: body for name, body in DEFINE.findall(strip_comments(text))}


def ioc(direction: int, type_char: str, number: int, size: int) -> int:
    """Linux's asm-generic `_IOC`, re-derived rather than read back.

    _IOC(dir, type, nr, size) = (dir << 30) | (size << 16) | (type << 8) | nr
    on every architecture this island targets. `_IOW` is direction 1.
    """
    return (direction << 30) | (size << 16) | (ord(type_char) << 8) | number


class VendorFixtureTests(unittest.TestCase):
    """Layer 1 + 2 -- runnable today, and non-vacuous today."""

    @classmethod
    def setUpClass(cls) -> None:
        if not VENDOR_FIXTURE.is_file():
            raise unittest.SkipTest(f"{VENDOR_FIXTURE} is missing")
        cls.text = VENDOR_FIXTURE.read_text(encoding="utf-8")
        cls.enumerators = parse_enumerators(cls.text)
        cls.defines = parse_defines(cls.text)

    def test_every_expected_command_is_present_with_its_pinned_value(self) -> None:
        for name, expected in sorted(EXPECTED_COMMANDS.items()):
            with self.subTest(command=name):
                self.assertIn(name, self.enumerators, f"{name} is absent from the fixture")
                self.assertEqual(
                    self.enumerators[name],
                    expected,
                    f"{name} drifted: the pinned kernel and libmpp sources both say "
                    f"{expected:#05x}",
                )

    def test_the_fixture_adds_no_command_the_island_has_not_pinned(self) -> None:
        commands = {
            name for name in self.enumerators if name.startswith("MPP_CMD_")
        }
        self.assertEqual(
            commands - set(EXPECTED_COMMANDS),
            set(),
            "the fixture carries a command this test has no pinned value for -- "
            "add it to EXPECTED_COMMANDS with its source, or drop it",
        )

    def test_the_ioctl_magic_is_the_letter_v(self) -> None:
        self.assertEqual(self.defines.get("MPP_IOC_MAGIC"), "'v'")

    def test_mpp_ioc_cfg_v1_matches_an_independent_ioc_derivation(self) -> None:
        derived = ioc(direction=1, type_char="v", number=1, size=4)
        self.assertEqual(
            derived,
            0x40047601,
            "the re-derivation itself drifted; _IOW('v', 1, unsigned int) is fixed",
        )
        self.assertIn("MPP_IOC_CFG_V1", self.defines)
        self.assertRegex(
            self.text,
            rf"_Static_assert\(\s*MPP_IOC_CFG_V1\s*==\s*{derived:#010x}u",
            "the fixture's own compile-time assertion no longer names the value an "
            "independent _IOC derivation produces",
        )

    def test_the_request_struct_is_pinned_at_its_lp64_size(self) -> None:
        self.assertRegex(
            self.text,
            rf"_Static_assert\(sizeof\(struct mpp_request\) == {MPP_REQUEST_BYTES}",
            "struct mpp_request must stay 4+4+4+4+8 = 24 bytes on LP64; the kernel "
            "and libmpp declarations differ in spelling only",
        )

    def test_exactly_the_three_compiled_clients_are_listed(self) -> None:
        clients = {
            name: value
            for name, value in self.enumerators.items()
            if name.startswith("MPP_CLIENT_")
        }
        self.assertEqual(
            clients,
            EXPECTED_CLIENTS,
            "exactly RKVENC2, RKVDEC2 and JPGDEC are compiled. A fourth client "
            "advertises silicon the island does not drive; a missing one leaves a "
            "compiled client the harness cannot address.",
        )

    def test_each_client_bit_matches_its_probe_hw_support_position(self) -> None:
        for name, value in sorted(EXPECTED_CLIENTS.items()):
            with self.subTest(client=name):
                self.assertRegex(
                    self.text,
                    rf"{name}\s*=\s*{value},\s*/\*\s*bit\s+{1 << value:#010x}\s*\*/",
                    f"{name}'s recorded PROBE_HW_SUPPORT bit must be 1 << {value}",
                )


class IslandHeaderParityTests(unittest.TestCase):
    """Layer 3 -- SKIPPED until the driver import creates the island header.

    This is a skip and not a pass, on purpose. Reporting green for a comparison
    with nothing on one side is exactly the false result a parity gate exists to
    prevent, so the reason names the file and what creates it.
    """

    @classmethod
    def setUpClass(cls) -> None:
        if not ISLAND_HEADER.is_file():
            raise unittest.SkipTest(
                "NO-HEADER-YET: include/uapi/linux/rk-mpp.h does not exist. The "
                "driver import creates it; until then there is no island-side ABI "
                "to compare against the pinned vendor fixture, and this suite "
                "refuses to report a pass for a comparison it did not make."
            )
        cls.island = parse_enumerators(ISLAND_HEADER.read_text(encoding="utf-8"))
        cls.island_defines = parse_defines(ISLAND_HEADER.read_text(encoding="utf-8"))

    def test_island_command_values_match_the_pinned_sources(self) -> None:
        for name, expected in sorted(EXPECTED_COMMANDS.items()):
            with self.subTest(command=name):
                self.assertIn(
                    name,
                    self.island,
                    f"{name} is absent from the island UAPI header -- libmpp sends it",
                )
                self.assertEqual(self.island[name], expected)

    def test_island_ioctl_magic_matches(self) -> None:
        self.assertEqual(self.island_defines.get("MPP_IOC_MAGIC"), "'v'")

    def test_island_adds_no_command_outside_the_pinned_contract(self) -> None:
        commands = {name for name in self.island if name.startswith("MPP_CMD_")}
        self.assertEqual(
            commands - set(EXPECTED_COMMANDS),
            set(),
            "the island header adds a command neither pinned source carries; a new "
            "ioctl value is an ABI change and needs its own record",
        )


if __name__ == "__main__":
    unittest.main()
