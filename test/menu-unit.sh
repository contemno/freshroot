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
MOD="$(dirname "$HERE")/data/usr/lib/dracut/modules.d/90freshroot-stage1"

# shellcheck source=/dev/null
. "$MOD/freshroot-menu-lib.sh"

extract() { sed -n "/^$1() {/,/^}/p" "$MOD/freshroot-menu.sh"; }
eval "$(extract build_index)"
eval "$(extract default_lineage)"
eval "$(extract store_kernels)"

btrfs() { echo "ro=true"; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
TOPLEVEL="$T"
SNAPSHOTS_DIR=@snapshots
STATE_REL=freshroot-state/default-lineage
UKI_DIR="$T/@modules/.freshroot/uki"
TAB=$(printf '\t')

mksnap() { # name — snapshot dir WITHOUT kernels (the store model)
    local d="$T/@snapshots/$1"
    mkdir -p "$d/usr/lib/freshroot" "$d/usr/lib/modules"
    echo 1 > "$d/usr/lib/freshroot/ceremony"
    printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$d/usr/lib/os-release"
}

fail=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1 (got: $3)"; fail=1; fi; }

mksnap root.ubuntu-24.04.20260820T120000
mksnap root.ubuntu-24.04.20260822T090000
mksnap root.ubuntu-26.04.20260821T000000
mksnap root.ubuntu-24.04.20260823T120000
mkdir -p "$T/@snapshots/root.notatimestamp"
mkdir -p "$T/freshroot-state" "$UKI_DIR"
echo ubuntu-24.04 > "$T/freshroot-state/default-lineage"
touch "$UKI_DIR/uki-6.8.0-50.efi" "$UKI_DIR/uki-6.16.9-061609.efi" "$UKI_DIR/uki-6.8.0-52.efi"

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

KL=$(store_kernels)
K1=$(printf '%s\n' "$KL" | head -1 | cut -f1)
K3=$(printf '%s\n' "$KL" | tail -1 | cut -f1)
KP=$(printf '%s\n' "$KL" | head -1 | cut -f2)
check "store kernels newest-first by version (6.16 before 6.8.0-52)" '[ "$K1" = 6.16.9-061609 ]' "$K1"
check "store kernels oldest last" '[ "$K3" = 6.8.0-50 ]' "$K3"
check "store kernel path points at the UKI" '[ "$KP" = "$UKI_DIR/uki-6.16.9-061609.efi" ]' "$KP"
rm -f "$UKI_DIR"/*.efi
KE=$(store_kernels)
check "empty store yields no kernels" '[ -z "$KE" ]' "$KE"

# Menu ordering (mirrors the main-flow logic)
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

exit $fail
