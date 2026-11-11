#!/bin/bash
# run-qemu.sh — boot the fixture image under OVMF, serial console on stdio.
# The disk is opened with snapshot=on so runs never dirty the fixture.
# KVM is used when available, TCG otherwise (slow but correct).
#
#   FRESHROOT_TEST_SB=1   boot the Secure-Boot-capable firmware with the
#                         test keys enrolled (vars-sb.fd from build-image.sh)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DISK="${1:-$HERE/disk.img}"
[[ -f "$DISK" ]] || { echo "run-qemu: no disk image at ${DISK} — run 'make rig-image' first" >&2; exit 1; }

CODE=""
VARS_SRC=""
if [[ "${FRESHROOT_TEST_SB:-0}" = "1" ]]; then
    # Secure Boot needs the SMM build of OVMF; the vars carry our keys.
    for c in /usr/share/OVMF/OVMF_CODE_4M.ms.fd /usr/share/OVMF/OVMF_CODE_4M.secboot.fd; do
        [[ -r "$c" ]] && { CODE="$c"; break; }
    done
    VARS_SRC="$HERE/vars-sb.fd"
    [[ -r "$VARS_SRC" ]] || { echo "run-qemu: no vars-sb.fd (build-image.sh needs python3-virt-firmware)" >&2; exit 1; }
else
    for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do
        [[ -r "$c" ]] && { CODE="$c"; break; }
    done
    for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
        [[ -r "$v" ]] && { VARS_SRC="$v"; break; }
    done
fi
[[ -n "$CODE" && -n "$VARS_SRC" ]] || { echo "run-qemu: OVMF not found (apt install ovmf)" >&2; exit 1; }

VARS=$(mktemp --suffix=.fd)
cp "$VARS_SRC" "$VARS"
trap 'rm -f "$VARS"' EXIT

exec qemu-system-x86_64 \
    -machine q35,accel=kvm:tcg,smm=on -cpu max -smp 2 -m 4096 \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive if=pflash,format=raw,readonly=on,file="$CODE" \
    -drive if=pflash,format=raw,file="$VARS" \
    -drive file="$DISK",format=raw,if=virtio,snapshot=on \
    -display none -serial stdio -monitor none -no-reboot
