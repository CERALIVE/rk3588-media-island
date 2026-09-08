#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(realpath "$here/../../../..")
if (($# < 2 || $# > 3)); then
	printf 'usage: %s STAGED_KERNEL BUILD_DIR [FILTER]\n' "$0" >&2
	exit 2
fi
kernel=$(realpath "$1")
build=$(realpath -m "$2")
for path in "$kernel" "$build"; do
	case "$path" in
	"$root/.work/"*) ;;
	*) printf 'FAIL: test paths must be under repo .work/\n' >&2; exit 2 ;;
	esac
done
filter=${3:-'*mpp*rewrite*'}
(
	cd -- "$kernel"
	python3 tools/testing/kunit/kunit.py run --arch arm64 \
		--cross_compile aarch64-linux-gnu- --kunitconfig="$here/.kunitconfig" \
		--build_dir="$build" --jobs="${KUNIT_JOBS:-12}" \
		--make_options=KCFLAGS=-Werror --timeout=180 "$filter"
)
if grep -Eq 'WARNING:|BUG:|Oops:|KASAN:|DEBUG_LOCKS_WARN_ON|possible circular locking' "$build/test.log"; then
	printf 'FAIL: kernel diagnostics in %s/test.log despite KTAP result\n' "$build" >&2
	exit 1
fi
printf 'PASS: KUnit and kernel diagnostic scan (%s)\n' "$filter"
