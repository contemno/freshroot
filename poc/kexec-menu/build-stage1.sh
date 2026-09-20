#!/bin/bash
# build-stage1.sh — build the stage-1 menu initramfs and UKI inside a guest
# tree's chroot (zero host-distro coupling: the tree's own dracut, kernel
# and ukify are used).
#
# Usage:
#   build-stage1.sh --tree DIR --out-uki FILE
#       [--kver K] [--test-keyfile FILE] [--cmdline "..."] [--out-initramfs FILE]
#
# The tree must contain: dracut, systemd-ukify, systemd-boot-efi, and a
# kernel (/boot/vmlinuz-<kver> in-tree). The 90freshroot-menu module is
# copied in for the build and removed afterwards — snapshot trees must not
# ship the PoC module.
set -euo pipefail

MODDIR="$(cd "$(dirname "$0")" && pwd)/dracut-module/90freshroot-menu"
TREE=""
KVER=""
TEST_KEYFILE=""
OUT_UKI=""
OUT_INITRAMFS=""
CMDLINE="console=ttyS0,115200n8 root=freshroot rd.freshroot.timeout=5 loglevel=4"

die() { echo "build-stage1: FATAL: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tree)          TREE="$2"; shift ;;
        --kver)          KVER="$2"; shift ;;
        --test-keyfile)  TEST_KEYFILE="$2"; shift ;;
        --cmdline)       CMDLINE="$2"; shift ;;
        --out-uki)       OUT_UKI="$2"; shift ;;
        --out-initramfs) OUT_INITRAMFS="$2"; shift ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

[[ -n "$TREE" && -d "$TREE" ]] || die "--tree DIR is required"
[[ -n "$OUT_UKI" ]] || die "--out-uki FILE is required"

if [[ -z "$KVER" ]]; then
    KVER=$(find "$TREE/boot" -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' 2>/dev/null \
           | sed 's/^vmlinuz-//' | sort -V | tail -1) || KVER=""
    [[ -n "$KVER" ]] || die "no vmlinuz-* in ${TREE}/boot — pass --kver"
fi
[[ -f "$TREE/boot/vmlinuz-$KVER" ]] || die "missing ${TREE}/boot/vmlinuz-${KVER}"
[[ -x "$TREE/usr/bin/dracut" || -x "$TREE/usr/sbin/dracut" ]] || die "dracut not installed in tree"
[[ -x "$TREE/usr/bin/ukify" || -x "$TREE/usr/lib/systemd/ukify" ]] || die "systemd-ukify not installed in tree"

MOD_DST="$TREE/usr/lib/dracut/modules.d/90freshroot-menu"
cleanup() {
    rm -rf "$MOD_DST" "$TREE/tmp/freshroot-stage1.img" "$TREE/tmp/freshroot-menu.efi" \
           "$TREE/tmp/freshroot-test-keyfile" 2>/dev/null || true
}
trap cleanup EXIT

echo "build-stage1: injecting menu module into the tree"
rm -rf "$MOD_DST"
cp -a "$MODDIR" "$MOD_DST"

DRACUT_ARGS=(
    --force --kver "$KVER"
    --no-hostonly --no-hostonly-cmdline
    --omit "systemd systemd-initrd dracut-systemd systemd-cryptsetup plymouth resume network network-legacy network-manager ifcfg url-lib nfs iscsi lvm mdraid fips"
    --add "freshroot-menu"
    --add-drivers "virtio_blk virtio_pci virtio_scsi sd_mod nvme ahci dm_crypt btrfs vfat ext4"
    --compress zstd
)
if [[ -n "$TEST_KEYFILE" ]]; then
    [[ -f "$TEST_KEYFILE" ]] || die "--test-keyfile: no such file: $TEST_KEYFILE"
    cp "$TEST_KEYFILE" "$TREE/tmp/freshroot-test-keyfile"
    DRACUT_ARGS+=(--include /tmp/freshroot-test-keyfile /etc/freshroot/test-keyfile)
fi

echo "build-stage1: building stage-1 initramfs (dracut, non-systemd, kver ${KVER})"
chroot "$TREE" dracut "${DRACUT_ARGS[@]}" /tmp/freshroot-stage1.img \
    || die "dracut failed"

echo "build-stage1: assembling UKI (ukify)"
chroot "$TREE" ukify build \
    --linux "/boot/vmlinuz-${KVER}" \
    --initrd /tmp/freshroot-stage1.img \
    --cmdline "$CMDLINE" \
    --output /tmp/freshroot-menu.efi \
    || die "ukify failed"

install -D -m 0644 "$TREE/tmp/freshroot-menu.efi" "$OUT_UKI"
if [[ -n "$OUT_INITRAMFS" ]]; then
    install -D -m 0644 "$TREE/tmp/freshroot-stage1.img" "$OUT_INITRAMFS"
fi
echo "build-stage1: UKI written to ${OUT_UKI}"
