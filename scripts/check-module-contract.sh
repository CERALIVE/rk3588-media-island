#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	return 1
}

require_device_table() {
	local source=$1
	local table=$2

	grep -Fq "MODULE_DEVICE_TABLE(of, ${table});" "$source" ||
		fail "$(basename "$source") does not publish ${table}"
}

check_sources() {
	local root=$1
	local mpp="$root/drivers/video/rockchip/mpp"
	local rga="$root/drivers/video/rockchip/rga3"
	local core_probe

	require_device_table "$mpp/mpp_rkvenc2.c" mpp_rkvenc_dt_match || return 1
	require_device_table "$mpp/mpp_rkvdec2.c" mpp_rkvdec2_dt_match || return 1
	require_device_table "$mpp/mpp_jpgdec.c" mpp_jpgdec_dt_match || return 1
	require_device_table "$rga/rga_drv.c" rga3_dt_ids || return 1
	require_device_table "$rga/rga_drv.c" rga2_dt_ids || return 1

	core_probe="$(awk '
		/^static int rkvenc_core_probe\(/ { active = 1 }
		/^static int rkvenc_probe_default\(/ { active = 0 }
		active { print }
	' "$mpp/mpp_rkvenc2.c")"
	[[ -n "$core_probe" ]] || {
		fail "rkvenc_core_probe was not found"
		return 1
	}
	if grep -Fq IRQF_ONESHOT <<<"$core_probe"; then
		fail "rkvenc_core_probe uses IRQF_ONESHOT without a threaded handler"
		return 1
	fi

	printf 'PASS: source module metadata and IRQ contract\n'
}

require_alias() {
	local aliases=$1
	local module=$2
	local compatible=$3

	grep -Fq "C${compatible}" <<<"$aliases" ||
		fail "$(basename "$module") has no OF alias for ${compatible}"
}

check_modules() {
	local mpp_module=$1
	local rga_module=$2
	local mpp_aliases
	local rga_aliases

	[[ -f "$mpp_module" ]] || fail "missing module: $mpp_module"
	[[ -f "$rga_module" ]] || fail "missing module: $rga_module"
	mpp_aliases="$(modinfo -F alias "$mpp_module")"
	rga_aliases="$(modinfo -F alias "$rga_module")"

	for compatible in \
		rockchip,rkv-encoder-v2 \
		rockchip,rkv-encoder-v2-core \
		rockchip,rkv-encoder-v2-ccu \
		rockchip,rkv-decoder-v2 \
		rockchip,rkv-decoder-v2-ccu \
		rockchip,rkv-jpeg-decoder-v1; do
		require_alias "$mpp_aliases" "$mpp_module" "$compatible" || return 1
	done
	for compatible in rockchip,rga3 rockchip,rga2; do
		require_alias "$rga_aliases" "$rga_module" "$compatible" || return 1
	done

	printf 'PASS: built module OF aliases\n'
}

self_test() {
	local tmp
	local fixture
	local fake_bin

	tmp="$(mktemp -d)"
	trap 'rm -rf "$tmp"' RETURN
	fixture="$tmp/source"
	fake_bin="$tmp/bin"
	mkdir -p "$fixture/drivers/video/rockchip/mpp" \
		"$fixture/drivers/video/rockchip/rga3" "$fake_bin"

	printf '%s\n' \
		'MODULE_DEVICE_TABLE(of, mpp_rkvenc_dt_match);' \
		'static int rkvenc_core_probe(struct platform_device *pdev)' \
		'{' \
		' devm_request_threaded_irq(dev, irq, handler, NULL, 0, name, data);' \
		'}' \
		'static int rkvenc_probe_default(struct platform_device *pdev)' \
		>"$fixture/drivers/video/rockchip/mpp/mpp_rkvenc2.c"
	printf '%s\n' 'MODULE_DEVICE_TABLE(of, mpp_rkvdec2_dt_match);' \
		>"$fixture/drivers/video/rockchip/mpp/mpp_rkvdec2.c"
	printf '%s\n' 'MODULE_DEVICE_TABLE(of, mpp_jpgdec_dt_match);' \
		>"$fixture/drivers/video/rockchip/mpp/mpp_jpgdec.c"
	printf '%s\n' \
		'MODULE_DEVICE_TABLE(of, rga3_dt_ids);' \
		'MODULE_DEVICE_TABLE(of, rga2_dt_ids);' \
		>"$fixture/drivers/video/rockchip/rga3/rga_drv.c"

	check_sources "$fixture" >/dev/null
	if sed -i '/mpp_jpgdec_dt_match/d' \
		"$fixture/drivers/video/rockchip/mpp/mpp_jpgdec.c" && \
		check_sources "$fixture" >/dev/null 2>&1; then
		fail "missing device-table mutation passed"
	fi
	printf '%s\n' 'MODULE_DEVICE_TABLE(of, mpp_jpgdec_dt_match);' \
		>"$fixture/drivers/video/rockchip/mpp/mpp_jpgdec.c"
	sed -i '/devm_request_threaded_irq/s/, 0,/, IRQF_ONESHOT,/' \
		"$fixture/drivers/video/rockchip/mpp/mpp_rkvenc2.c"
	if check_sources "$fixture" >/dev/null 2>&1; then
		fail "IRQF_ONESHOT mutation passed"
	fi

  touch "$tmp/rk_vcodec.ko" "$tmp/rga_multicore.ko"
	cat >"$fake_bin/modinfo" <<'EOF'
#!/usr/bin/env bash
case "${*: -1}" in
*rk_vcodec.ko)
	printf '%s\n' \
		'of:N*T*Crockchip,rkv-encoder-v2' \
		'of:N*T*Crockchip,rkv-encoder-v2-core' \
		'of:N*T*Crockchip,rkv-encoder-v2-ccu' \
		'of:N*T*Crockchip,rkv-decoder-v2' \
		'of:N*T*Crockchip,rkv-decoder-v2-ccu' \
		'of:N*T*Crockchip,rkv-jpeg-decoder-v1'
	;;
*) printf '%s\n' 'of:N*T*Crockchip,rga3' 'of:N*T*Crockchip,rga2' ;;
esac
EOF
	chmod +x "$fake_bin/modinfo"
  PATH="$fake_bin:$PATH" check_modules "$tmp/rk_vcodec.ko" "$tmp/rga_multicore.ko" >/dev/null

	printf 'module-contract self-test: pass:3 fail:0 total:3\n'
}

case "${1:-}" in
--self-test)
	self_test
	;;
--modules)
    [[ $# -eq 3 ]] || fail "usage: $0 --modules <rk_vcodec.ko> <rga_multicore.ko>"
	check_modules "$2" "$3"
	;;
"")
	check_sources "$ROOT"
	;;
*)
    fail "usage: $0 [--self-test | --modules <rk_vcodec.ko> <rga_multicore.ko>]"
	;;
esac
