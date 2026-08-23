#!/bin/bash
# run-qemu.sh — boot the fixture image under OVMF, serial console on stdio.
# The disk is opened with snapshot=on so runs never dirty the fixture.
# KVM is used when available, TCG otherwise (slow but correct).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DISK="${1:-$HERE/disk.img}"
[[ -f "$DISK" ]] || { echo "run-qemu: no disk image at ${DISK} — run 'make image' first" >&2; exit 1; }

# Non-SecureBoot OVMF files (SB is out of scope for the PoC); 4M layout on
# noble, legacy paths as fallback.
CODE=""
VARS_SRC=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do
    [[ -r "$c" ]] && { CODE="$c"; break; }
done
for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
    [[ -r "$v" ]] && { VARS_SRC="$v"; break; }
done
[[ -n "$CODE" && -n "$VARS_SRC" ]] || { echo "run-qemu: OVMF not found (apt install ovmf)" >&2; exit 1; }

VARS=$(mktemp --suffix=.fd)
cp "$VARS_SRC" "$VARS"
trap 'rm -f "$VARS"' EXIT

exec qemu-system-x86_64 \
    -machine q35,accel=kvm:tcg -cpu max -smp 2 -m 4096 \
    -drive if=pflash,format=raw,readonly=on,file="$CODE" \
    -drive if=pflash,format=raw,file="$VARS" \
    -drive file="$DISK",format=raw,if=virtio,snapshot=on \
    -display none -serial stdio -monitor none -no-reboot
