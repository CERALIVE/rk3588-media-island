#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -uo pipefail

root=$(realpath "$(dirname "${BASH_SOURCE[0]}")/..") || exit 1
exec python3 "$root/scripts/fault-seam-parity.py" "$@"
