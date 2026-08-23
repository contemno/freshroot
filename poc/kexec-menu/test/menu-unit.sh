#!/bin/bash
# menu-unit.sh — CI-safe unit tests for the stage-1 menu's decision logic.
#
# Extracts the pure functions from freshroot-menu.sh / freshroot-menu-lib.sh
# and exercises them against a directory fixture, with `btrfs` stubbed (every
# fixture snapshot reports ro=true), so no btrfs, LUKS, or root is needed.
#
# shellcheck disable=SC2016  # check() expressions are single-quoted for eval
# shellcheck disable=SC2034  # globals are consumed by the eval'd functions
# shellcheck disable=SC2317  # the btrfs stub is called via the eval'd code
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
MOD="$(dirname "$HERE")/dracut-module/90freshroot-menu"

# shellcheck source=/dev/null
. "$MOD/freshroot-menu-lib.sh"

extract() { sed -n "/^$1() {/,/^}/p" "$MOD/freshroot-menu.sh"; }
eval "$(extract build_index)"
eval "$(extract default_lineage)"
eval "$(extract kernels_for_tree)"
eval "$(extract best_kernel_for_tree)"

# Stub btrfs: property get always reports ro=true (fixture snapshots are
# plain directories).
btrfs() { echo "ro=true"; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
TOPLEVEL="$T"
SNAPSHOTS_DIR=@snapshots
STATE_REL=freshroot-state/default-lineage
TAB=$(printf '\t')

mksnap() { # name kver... — snapshot dir with in-tree kernel pair(s)
    local name="$1"; shift
    local d="$T/@snapshots/$name" k
    mkdir -p "$d/boot" "$d/usr/lib/freshroot"
    echo 1 > "$d/usr/lib/freshroot/ceremony"
    for k in "$@"; do
        mkdir -p "$d/usr/lib/modules/$k"
        echo K > "$d/boot/vmlinuz-$k"
        echo I > "$d/boot/initrd.img-$k"
    done
    mkdir -p "$d/usr/lib"
    printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$d/usr/lib/os-release"
}

fail=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1 (got: $3)"; fail=1; fi }

# Fixture: two lineages + one snapshot missing its initrd + one legacy name
mksnap root.ubuntu-24.04.20260820T120000 6.8.0-50
mksnap root.ubuntu-24.04.20260822T090000 6.8.0-50 6.8.0-51
mksnap root.ubuntu-26.04.20260821T000000 6.14.0-9
mksnap root.ubuntu-24.04.20260823T120000 6.8.0-52
rm "$T/@snapshots/root.ubuntu-24.04.20260823T120000/boot/initrd.img-6.8.0-52"
mkdir -p "$T/@snapshots/root.notatimestamp"    # excluded: no TS field
mkdir -p "$T/freshroot-state"
echo ubuntu-24.04 > "$T/freshroot-state/default-lineage"

build_index
N=$(printf '%s\n' "$SNAP_INDEX" | grep -c .)
check "index holds 4 timestamped snapshots" '[ "$N" = 4 ]' "$N"
FIRST=$(printf '%s\n' "$SNAP_INDEX" | head -1 | cut -f3)
check "index sorted oldest first" '[ "$FIRST" = root.ubuntu-24.04.20260820T120000 ]' "$FIRST"

DL=$(default_lineage)
check "default lineage from state file" '[ "$DL" = ubuntu-24.04 ]' "$DL"
rm "$T/freshroot-state/default-lineage"
DL=$(default_lineage)
check "default lineage falls back to newest snapshot's lineage" '[ "$DL" = ubuntu-24.04 ]' "$DL"
echo ubuntu-24.04 > "$T/freshroot-state/default-lineage"

K=$(kernels_for_tree "$T/@snapshots/root.ubuntu-24.04.20260822T090000" | head -1 | cut -f1)
check "pairing picks newest in-tree kernel" '[ "$K" = 6.8.0-51 ]' "$K"
K=$(kernels_for_tree "$T/@snapshots/root.ubuntu-24.04.20260823T120000")
check "missing initrd -> no bootable pair" '[ -z "$K" ]' "$K"

best_kernel_for_tree "$T/@snapshots/root.ubuntu-26.04.20260821T000000"
check "best_kernel_for_tree sets BK_VMLINUZ" \
    '[ "$BK_VMLINUZ" = "$T/@snapshots/root.ubuntu-26.04.20260821T000000/boot/vmlinuz-6.14.0-9" ]' "$BK_VMLINUZ"

# Menu ordering + default selection (mirrors the main-flow logic)
DEFAULT_LINEAGE_VAL=$DL
MENU_NAMES=()
ALL_LINEAGES=$(printf '%s\n' "$SNAP_INDEX" \
    | awk -F'\t' 'NF==3 { last[$2]=$1 } END { for (l in last) print last[l] "\t" l }' \
    | sort -r | cut -f2)
ORDERED_LINEAGES=$({ printf '%s\n' "$DEFAULT_LINEAGE_VAL"; \
    printf '%s\n' "$ALL_LINEAGES" | grep -Fvx "$DEFAULT_LINEAGE_VAL" || true; } | grep . )
for _lin in $ORDERED_LINEAGES; do
    while read -r _name; do
        [ -n "$_name" ] && MENU_NAMES+=("$_name")
    done < <(printf '%s\n' "$SNAP_INDEX" | awk -F'\t' -v l="$_lin" 'NF==3 && $2==l {print $3}' | tac)
done
check "menu lists default lineage first, newest first" \
    '[ "${MENU_NAMES[0]}" = root.ubuntu-24.04.20260823T120000 ]' "${MENU_NAMES[0]}"
check "other lineage listed after default lineage" \
    '[ "${MENU_NAMES[3]}" = root.ubuntu-26.04.20260821T000000 ]' "${MENU_NAMES[3]}"

DEFAULT_IDX=""
for _i in "${!MENU_NAMES[@]}"; do
    if [ -n "$(kernels_for_tree "$T/@snapshots/${MENU_NAMES[$_i]}")" ]; then
        DEFAULT_IDX=$_i
        break
    fi
done
# Entry 0 (newest) has no bootable pair — the default walk must land on entry 1
check "default walk skips the unbootable newest snapshot" \
    '[ "$DEFAULT_IDX" = 1 ] && [ "${MENU_NAMES[1]}" = root.ubuntu-24.04.20260822T090000 ]' \
    "idx=$DEFAULT_IDX name=${MENU_NAMES[$DEFAULT_IDX]:-}"

exit $fail
