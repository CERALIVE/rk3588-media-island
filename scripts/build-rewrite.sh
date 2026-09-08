#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
source kernel-pin.env
source island/comparison/rewrite/pins.env
export GIT_MASTER=1 ARCH=$ISLAND_ARCH CROSS_COMPILE=$ISLAND_CROSS_COMPILE
export CC="ccache ${ISLAND_CROSS_COMPILE}gcc"
jobs=${REWRITE_BUILD_JOBS:-4}
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || exit 2
kernel=$root/.work/linux-rewrite
sparse=$root/.work/sparse-rewrite/sparse
[[ -x "$sparse" ]] || { printf 'FAIL: pinned sparse build absent\n' >&2; exit 1; }

make -C "$kernel" -j"$jobs" defconfig
"$kernel/scripts/kconfig/merge_config.sh" -m -O "$kernel" "$kernel/.config" \
  .work/rewrite-edge.fragment .work/rewrite-edge-test.fragment
"$kernel/scripts/config" --file "$kernel/.config" \
  --disable ROCKCHIP_MPP_SERVICE --disable ROCKCHIP_MULTI_RGA \
  --disable VIDEO_ROCKCHIP_RGA --module ROCKCHIP_MPP_REWRITE \
  --enable ROCKCHIP_MPP_REWRITE_FAULT_INJECTION \
  --module ROCKCHIP_RGA_REWRITE --enable ROCKCHIP_IOMMU --module VSI_IOMMU \
  --disable LOCALVERSION_AUTO --set-str LOCALVERSION -ceralive-rk3588-test-rewrite
make -C "$kernel" -j"$jobs" olddefconfig modules_prepare
for setting in CONFIG_ROCKCHIP_MPP_REWRITE=m CONFIG_ROCKCHIP_RGA_REWRITE=m \
  CONFIG_ROCKCHIP_IOMMU=y CONFIG_VSI_IOMMU=m CONFIG_KASAN=y CONFIG_PROVE_LOCKING=y; do
  grep -qx "$setting" "$kernel/.config" || { printf 'FAIL: dropped %s\n' "$setting"; exit 1; }
done
if grep -E '^CONFIG_(ROCKCHIP_MPP_SERVICE|ROCKCHIP_MULTI_RGA|VIDEO_ROCKCHIP_RGA)=[ym]$' "$kernel/.config"; then
  printf 'FAIL: competing production driver enabled\n' >&2; exit 1
fi
"$kernel/scripts/checker-valid.sh" "$sparse" --arch=arm64 -m64 -mlittle-endian | grep -qx 1
make -C "$kernel" -j"$jobs" vmlinux KCFLAGS=-Werror
cp "$kernel/vmlinux.symvers" "$kernel/Module.symvers"
make -C "$kernel" -j"$jobs" drivers/iommu/vsi-iommu.ko KCFLAGS=-Werror
awk '$3 == "drivers/iommu/vsi-iommu"' "$kernel/Module.symvers" > "$kernel/rewrite-provider.symvers"
test -s "$kernel/rewrite-provider.symvers"
cp "$kernel/vmlinux.symvers" "$kernel/Module.symvers"
for module in mpp-rewrite rga-rewrite; do
  make -C "$kernel" -j"$jobs" M="drivers/video/rockchip/$module" \
    KBUILD_EXTRA_SYMBOLS="$kernel/rewrite-provider.symvers" \
    modules KCFLAGS=-Werror C=2 CHECK="$sparse" CF=-Wsparse-error
done
for module in rockchip-mpp-rewrite rockchip-rga-rewrite; do
  case "$module" in
    rockchip-mpp-rewrite) path=mpp-rewrite ;;
    rockchip-rga-rewrite) path=rga-rewrite ;;
  esac
  file="$kernel/drivers/video/rockchip/$path/$module.ko"
  test -s "$file"
  modinfo -F alias "$file" | grep '^of:'
  sha256sum "$file"
done
printf 'PASS: rewrite modules linked with real providers and sparse\n'
