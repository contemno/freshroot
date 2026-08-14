#!/bin/bash
# Exercise dracut-luks-setup's block-device discovery against recorded
# `lsblk -nspo NAME,TYPE,FSTYPE,UUID` output, so the three layouts that matter
# can be checked without a real encrypted disk (or root).

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TOOL="${HERE}/../dracut-luks-setup"
FIXTURES="${HERE}/fixtures"

PASS=0
FAIL=0

check() {
    local label="$1" haystack="$2" needle="$3"
    if grep -qF -- "$needle" <<< "$haystack"; then
        echo "  ok   ${label}: ${needle}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL ${label}: expected ${needle}" >&2
        FAIL=$((FAIL + 1))
    fi
}

# --- LUKS -> btrfs -------------------------------------------------------
echo "luks-btrfs"
OUT=$("$TOOL" --lsblk-fixture "${FIXTURES}/luks-btrfs.lsblk" 2>&1)
check luks-btrfs "$OUT" "LUKS container   /dev/sda3"
check luks-btrfs "$OUT" "LUKS UUID        a1b2c3d4-2222-4c1f-8e2a-1111feedface"
check luks-btrfs "$OUT" "mapping name     crypt-root"
check luks-btrfs "$OUT" "LVM volume group (none)"
check luks-btrfs "$OUT" \
    "rd.luks.uuid=a1b2c3d4-2222-4c1f-8e2a-1111feedface rd.luks.name=a1b2c3d4-2222-4c1f-8e2a-1111feedface=crypt-root"

# --- LUKS -> LVM -> ext4 -------------------------------------------------
echo "luks-lvm-ext4"
OUT=$("$TOOL" --lsblk-fixture "${FIXTURES}/luks-lvm-ext4.lsblk" 2>&1)
check luks-lvm "$OUT" "LUKS container   /dev/nvme0n1p3"
check luks-lvm "$OUT" "LUKS UUID        7a6b5c4d-5555-4f40-b15d-4444abadcafe"
check luks-lvm "$OUT" "mapping name     dm_crypt-0"
check luks-lvm "$OUT" "LVM volume group vgubuntu"
check luks-lvm "$OUT" "rd.lvm.vg=vgubuntu"

# --- No LUKS at all ------------------------------------------------------
echo "plain-ext4"
if OUT=$("$TOOL" --lsblk-fixture "${FIXTURES}/plain-ext4.lsblk" 2>&1); then
    echo "  FAIL plain-ext4: expected a non-zero exit" >&2
    FAIL=$((FAIL + 1))
else
    check plain-ext4 "$OUT" "/ is not on a LUKS volume"
fi

# --- Overrides -----------------------------------------------------------
echo "overrides"
OUT=$("$TOOL" --lsblk-fixture "${FIXTURES}/luks-btrfs.lsblk" \
        --name myroot --uuid 00000000-0000-0000-0000-000000000000 2>&1)
check overrides "$OUT" "mapping name     myroot"
check overrides "$OUT" "rd.luks.name=00000000-0000-0000-0000-000000000000=myroot"

echo
echo "${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
