#!/bin/bash
# Exercise the discovery library and the GRUB drop-in against recorded
# `lsblk -nPspo NAME,TYPE,FSTYPE,UUID` output, so the layouts that matter can
# be checked without a real encrypted disk -- or root.
#
# The drop-in is tested by sourcing it the way grub-mkconfig does (/bin/sh,
# set -e) and reading back GRUB_CMDLINE_LINUX, so a regression that only
# shows up at update-grub time gets caught here.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LIB="${HERE}/../data/usr/lib/dracut-luks/discover.sh"
DROPIN="${HERE}/../data/etc/default/grub.d/99-dracut-luks.cfg"
FIXTURES="${HERE}/fixtures"

PASS=0
FAIL=0

ok()   { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL $1" >&2; FAIL=$((FAIL + 1)); }

eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        ok "${label}: ${got}"
    else
        bad "${label}: got '${got}', want '${want}'"
    fi
}

# Run the discovery library in a clean subshell and print one variable.
discover() {
    local fixture="$1" var="$2"
    (
        set -euo pipefail
        DL_LSBLK_FIXTURE="${FIXTURES}/${fixture}"
        export DL_LSBLK_FIXTURE
        # shellcheck source=../data/usr/lib/dracut-luks/discover.sh
        . "$LIB"
        # No pre-initialization: dracut_luks_discover sets every DL_* variable
        # on entry, so anything it leaves unset under `set -u` is a bug worth
        # failing on.
        if dracut_luks_discover; then
            eval "printf '%s\n' \"\$${var}\""
        else
            printf 'DISCOVER-FAILED\n'
        fi
    )
}

# Same, for token detection against a recorded luksDump.
tokens() {
    local fixture="$1" var="$2"
    (
        set -euo pipefail
        DL_TOKENS_FIXTURE="${FIXTURES}/${fixture}"
        export DL_TOKENS_FIXTURE
        # shellcheck source=../data/usr/lib/dracut-luks/discover.sh
        . "$LIB"
        if dracut_luks_tokens; then
            eval "printf '%s\n' \"\$${var}\""
        else
            printf 'NO-TOKENS\n'
        fi
    )
}

# Source the GRUB drop-in exactly as grub-mkconfig does: /bin/sh, set -e,
# with whatever the admin already had in GRUB_CMDLINE_LINUX. An optional
# third argument supplies a luksDump fixture for token detection.
grub_cmdline() {
    local fixture="$1" preset="${2:-}" tokfixture="${3:-}"
    [[ -n "$tokfixture" ]] && tokfixture="${FIXTURES}/${tokfixture}"
    DL_LSBLK_FIXTURE="${FIXTURES}/${fixture}" \
    DL_TOKENS_FIXTURE="$tokfixture" \
    DL_LIB="$LIB" \
    DROPIN="$DROPIN" \
    GRUB_CMDLINE_LINUX="$preset" \
    /bin/sh -ec '
        . "$DROPIN"
        printf "%s\n" "${GRUB_CMDLINE_LINUX:-}"
    ' 2>&1 || printf 'DROPIN-FAILED\n'
}

BTRFS_UUID="a1b2c3d4-2222-4c1f-8e2a-1111feedface"
LVM_UUID="7a6b5c4d-5555-4f40-b15d-4444abadcafe"

# --- LUKS -> btrfs -------------------------------------------------------
echo "luks-btrfs"
eq "luks dev"  "$(discover luks-btrfs.lsblk DL_LUKS_DEV)"  "/dev/sda3"
eq "luks uuid" "$(discover luks-btrfs.lsblk DL_LUKS_UUID)" "$BTRFS_UUID"
eq "map name"  "$(discover luks-btrfs.lsblk DL_MAP_NAME)"  "crypt-root"
eq "vg name"   "$(discover luks-btrfs.lsblk DL_VG_NAME)"   ""
eq "params"    "$(discover luks-btrfs.lsblk DL_PARAMS)" \
   "rd.luks.uuid=${BTRFS_UUID} rd.luks.name=${BTRFS_UUID}=crypt-root"

# --- LUKS -> LVM -> ext4 -------------------------------------------------
echo "luks-lvm-ext4"
eq "luks dev"  "$(discover luks-lvm-ext4.lsblk DL_LUKS_DEV)"  "/dev/nvme0n1p3"
eq "luks uuid" "$(discover luks-lvm-ext4.lsblk DL_LUKS_UUID)" "$LVM_UUID"
eq "map name"  "$(discover luks-lvm-ext4.lsblk DL_MAP_NAME)"  "dm_crypt-0"
eq "vg name"   "$(discover luks-lvm-ext4.lsblk DL_VG_NAME)"   "vgubuntu"
eq "params"    "$(discover luks-lvm-ext4.lsblk DL_PARAMS)" \
   "rd.luks.uuid=${LVM_UUID} rd.luks.name=${LVM_UUID}=dm_crypt-0 rd.lvm.vg=vgubuntu"

# --- VG name containing a hyphen (dm escapes it as '--') -----------------
echo "luks-lvm-hyphen-vg"
eq "vg name"  "$(discover luks-lvm-hyphen-vg.lsblk DL_VG_NAME)"  "my-vg"
eq "map name" "$(discover luks-lvm-hyphen-vg.lsblk DL_MAP_NAME)" "luks-8b7a"

# --- No LUKS at all ------------------------------------------------------
echo "plain-ext4"
eq "discovery declines" "$(discover plain-ext4.lsblk DL_PARAMS)" "DISCOVER-FAILED"

# --- Token detection -----------------------------------------------------
echo "tokens"
eq "tpm2 only: types"   "$(tokens tokens-tpm2.luksdump DL_TOKENS)"     "tpm2"
eq "tpm2 only: options" "$(tokens tokens-tpm2.luksdump DL_TOKEN_OPTS)" "tpm2-device=auto"
eq "both: types"        "$(tokens tokens-both.luksdump DL_TOKENS)"     "tpm2 fido2"
eq "both: options"      "$(tokens tokens-both.luksdump DL_TOKEN_OPTS)" \
   "tpm2-device=auto,fido2-device=auto"
eq "none: declines"     "$(tokens tokens-none.luksdump DL_TOKENS)"     "NO-TOKENS"

# --- The GRUB drop-in ----------------------------------------------------
echo "grub drop-in"
eq "appends to empty cmdline" \
   "$(grub_cmdline luks-btrfs.lsblk)" \
   "rd.luks.uuid=${BTRFS_UUID} rd.luks.name=${BTRFS_UUID}=crypt-root"

eq "preserves an existing cmdline" \
   "$(grub_cmdline luks-btrfs.lsblk 'quiet splash')" \
   "quiet splash rd.luks.uuid=${BTRFS_UUID} rd.luks.name=${BTRFS_UUID}=crypt-root"

eq "defers to an admin-set rd.luks.uuid" \
   "$(grub_cmdline luks-btrfs.lsblk 'rd.luks.uuid=deadbeef')" \
   "rd.luks.uuid=deadbeef"

# The important one: update-grub runs under `set -e`, so an unencrypted root
# must leave the cmdline untouched rather than aborting grub-mkconfig.
eq "unencrypted root is a no-op, not an error" \
   "$(grub_cmdline plain-ext4.lsblk 'quiet splash')" \
   "quiet splash"

# Enrolled tokens must land as UUID-scoped rd.luks.options, or
# systemd-cryptsetup skips its native token path (bogus-PIN-prompt bug).
eq "tpm2 token adds rd.luks.options" \
   "$(grub_cmdline luks-btrfs.lsblk '' tokens-tpm2.luksdump)" \
   "rd.luks.uuid=${BTRFS_UUID} rd.luks.name=${BTRFS_UUID}=crypt-root rd.luks.options=${BTRFS_UUID}=tpm2-device=auto"

eq "both tokens add both options" \
   "$(grub_cmdline luks-btrfs.lsblk '' tokens-both.luksdump)" \
   "rd.luks.uuid=${BTRFS_UUID} rd.luks.name=${BTRFS_UUID}=crypt-root rd.luks.options=${BTRFS_UUID}=tpm2-device=auto,fido2-device=auto"

eq "no tokens, no rd.luks.options" \
   "$(grub_cmdline luks-btrfs.lsblk '' tokens-none.luksdump)" \
   "rd.luks.uuid=${BTRFS_UUID} rd.luks.name=${BTRFS_UUID}=crypt-root"

eq "defers to an admin-set rd.luks.options" \
   "$(grub_cmdline luks-btrfs.lsblk 'rd.luks.options=discard' tokens-tpm2.luksdump)" \
   "rd.luks.options=discard rd.luks.uuid=${BTRFS_UUID} rd.luks.name=${BTRFS_UUID}=crypt-root"

echo
echo "${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
