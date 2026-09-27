#!/bin/bash
# kernel-unit.sh — unit tests for freshroot-kernel's pure helpers (mainline
# index parsing, checksum lookup, extracted-deb kver detection, gc victim
# selection). No root, network or btrfs needed.
#
# shellcheck disable=SC2016  # check() expressions are single-quoted for eval
# shellcheck disable=SC2034  # KERNEL_FLAVOUR/KERNEL_ARCH are read by the eval'd helpers
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$(dirname "$HERE")/data/usr/sbin/freshroot-kernel"
extract() { sed -n "/^$1() {/,/^}/p" "$TOOL"; }
eval "$(extract mainline_versions_from_index)"
eval "$(extract mainline_deb_from_index)"
eval "$(extract checksum_for)"
eval "$(extract kver_of_extracted)"
eval "$(extract gc_victims)"

KERNEL_FLAVOUR=generic
KERNEL_ARCH=amd64
T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
fail=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1 (got: ${3:-})"; fail=1; fi; }

# ── Mirror index parsing (fixture mirrors kernel.ubuntu.com's listing) ──
cat > "$T/index.html" <<'HTML'
<a href="v6.16.9/">v6.16.9/</a> <a href="v7.1.13/">v7.1.13/</a>
<a href="v7.2-rc3/">v7.2-rc3/</a> <a href="v7.2/">v7.2/</a>
<a href="v6.16.10/">v6.16.10/</a> <a href="daily/">daily/</a>
HTML
V=$(mainline_versions_from_index < "$T/index.html" | tr '\n' ' ')
check "stable versions only, ascending by version" '[ "$V" = "6.16.9 6.16.10 7.1.13 7.2 " ]' "$V"

cat > "$T/vindex.html" <<'HTML'
<a href="amd64/linux-headers-7.1.13-070113-generic_7.1.13-070113.202609032040_amd64.deb">x</a>
<a href="amd64/linux-image-unsigned-7.1.13-070113-generic_7.1.13-070113.202609032040_amd64.deb">x</a>
<a href="amd64/linux-modules-7.1.13-070113-generic_7.1.13-070113.202609032040_amd64.deb">x</a>
<a href="arm64/linux-image-unsigned-7.1.13-070113-generic_7.1.13-070113.202609032040_arm64.deb">x</a>
HTML
I=$(mainline_deb_from_index image < "$T/vindex.html")
M=$(mainline_deb_from_index modules < "$T/vindex.html")
check "image deb picked for amd64/generic" \
    '[ "$I" = amd64/linux-image-unsigned-7.1.13-070113-generic_7.1.13-070113.202609032040_amd64.deb ]' "$I"
check "modules deb picked for amd64/generic" \
    '[ "$M" = amd64/linux-modules-7.1.13-070113-generic_7.1.13-070113.202609032040_amd64.deb ]' "$M"
KERNEL_ARCH=riscv64
R=$(mainline_deb_from_index image < "$T/vindex.html")
check "missing arch yields nothing" '[ -z "$R" ]' "$R"
KERNEL_ARCH=amd64

# ── CHECKSUMS parsing (sha256 block only; sha1 block ignored) ────────
cat > "$T/CHECKSUMS" <<'SUMS'
# Checksums-Sha1:
0000000000000000000000000000000000000000  amd64/linux-image-unsigned-7.1.13-070113-generic_7.1.13-070113.202609032040_amd64.deb
# Checksums-Sha256:
1111111111111111111111111111111111111111111111111111111111111111  amd64/linux-image-unsigned-7.1.13-070113-generic_7.1.13-070113.202609032040_amd64.deb
2222222222222222222222222222222222222222222222222222222222222222  crack.bundle
SUMS
S=$(checksum_for "$T/CHECKSUMS" linux-image-unsigned-7.1.13-070113-generic_7.1.13-070113.202609032040_amd64.deb)
check "sha256 found by basename" '[ "$S" = 1111111111111111111111111111111111111111111111111111111111111111 ]' "$S"
S2=$(checksum_for "$T/CHECKSUMS" linux-modules-7.1.13-070113-generic_7.1.13-070113.202609032040_amd64.deb)
check "unlisted deb yields no checksum (newer builds list only crack.bundle)" '[ -z "$S2" ]' "$S2"

# ── kver detection from an extracted deb tree ────────────────────────
mkdir -p "$T/x/lib/modules/7.1.13-070113-generic/kernel" "$T/x/boot"
K=$(kver_of_extracted "$T/x")
check "kver from lib/modules" '[ "$K" = 7.1.13-070113-generic ]' "$K"
mkdir -p "$T/x/usr/lib/modules/7.1.13-070113-generic"
K=$(kver_of_extracted "$T/x")
check "same kver under both module roots collapses to one" '[ "$K" = 7.1.13-070113-generic ]' "$K"
mkdir -p "$T/x/lib/modules/6.8.0-50-generic"
N=$(kver_of_extracted "$T/x" | grep -c .)
check "two kernel versions are both reported (caller refuses)" '[ "$N" = 2 ]' "$N"

# ── gc victim selection ──────────────────────────────────────────────
LIST=$'6.8.0-50-generic\n7.1.13-070113-generic\n6.16.9-061609-generic\n6.8.0-52-generic'
G=$(gc_victims "$LIST" 2 6.8.0-50-generic | tr '\n' ' ')
check "gc keeps newest 2, never the running kernel" '[ "$G" = "6.8.0-52-generic " ]' "$G"
G=$(gc_victims "$LIST" 10 x | tr '\n' ' ')
check "gc removes nothing when under the keep count" '[ -z "$G" ]' "$G"

exit $fail
