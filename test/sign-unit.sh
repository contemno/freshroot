#!/bin/bash
# sign-unit.sh — unit tests for freshroot-kernel's Secure Boot signing
# helpers, using throwaway openssl keys (skips when sbsign/ukify are absent).
#
# shellcheck disable=SC2016  # check() expressions are single-quoted for eval
# shellcheck disable=SC2034  # SB_* globals are read by the eval'd helpers
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$(dirname "$HERE")/data/usr/sbin/freshroot-kernel"
LIB="$(dirname "$HERE")/data/usr/lib/dracut/modules.d/90freshroot-stage1/freshroot-menu-lib.sh"
extract() { sed -n "/^$1() {/,/^}/p" "$TOOL"; }
eval "$(extract sb_available)"
eval "$(extract sb_cert_fingerprint)"
eval "$(extract sb_signed_by_us)"
eval "$(extract pe_is_signed)"
eval "$(extract sb_sign_inplace)"
# shellcheck source=/dev/null
. "$LIB"

for c in sbsign sbverify sbattach openssl ukify; do
    command -v "$c" >/dev/null 2>&1 || { echo "SKIP: $c not installed"; exit 0; }
done
[ -r /usr/lib/systemd/boot/efi/linuxx64.efi.stub ] || { echo "SKIP: sd-stub not installed"; exit 0; }

T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
fail=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }

SB_DIR="$T/sb"; SB_KEY_URI=""
mkdir -p "$SB_DIR"
openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=freshroot-unit/" \
    -keyout "$SB_DIR/db.key" -out "$SB_DIR/db.crt" >/dev/null 2>&1
openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=someone-else/" \
    -keyout "$T/other.key" -out "$T/other.crt" >/dev/null 2>&1

check "sb_available with key+cert" 'sb_available'
FP=$(sb_cert_fingerprint)
check "fingerprint is 64 lowercase hex chars" '[[ "$FP" =~ ^[0-9a-f]{64}$ ]]'

head -c 200000 /dev/urandom > "$T/vmlinuz.bin"
head -c 40000  /dev/urandom > "$T/initrd.bin"
ukify build --linux "$T/vmlinuz.bin" --initrd "$T/initrd.bin" --cmdline "root=freshroot" \
    --uname 0.0-test --output "$T/uki.efi" >/dev/null 2>&1 || { echo "SKIP: ukify build failed"; exit 0; }

check "fresh UKI is unsigned" '! pe_is_signed "$T/uki.efi"'
cp "$T/uki.efi" "$T/uki.ours.efi"
check "sb_sign_inplace succeeds" 'sb_sign_inplace "$T/uki.ours.efi"'
check "signed UKI verifies against our cert" 'sb_signed_by_us "$T/uki.ours.efi"'
check "menu-side pe_has_signature agrees" 'pe_has_signature "$T/uki.ours.efi"'
check "no temp files left behind" '[ ! -e "$T/uki.ours.efi.signing" ] && [ ! -e "$T/uki.ours.efi.signed" ]'

# A kernel signed by someone else (Canonical, in real life) gets re-signed
sbsign --key "$T/other.key" --cert "$T/other.crt" --output "$T/uki.theirs.efi" "$T/uki.efi" >/dev/null 2>&1
check "foreign signature is not ours" '! sb_signed_by_us "$T/uki.theirs.efi"'
check "re-signing replaces the foreign signature" 'sb_sign_inplace "$T/uki.theirs.efi" && sb_signed_by_us "$T/uki.theirs.efi"'
check "sections still extract after re-signing" \
    'pe_section_info "$T/uki.theirs.efi" .linux && dd if="$T/uki.theirs.efi" of="$T/out.bin" bs=1M iflag=skip_bytes,count_bytes skip="$PE_OFF" count="$PE_SIZE" 2>/dev/null && cmp -s "$T/out.bin" "$T/vmlinuz.bin"'

rm -f "$SB_DIR/db.key"
check "sb_available fails without db.key" '! sb_available'
SB_KEY_URI="pkcs11:token=x"
check "sb_available with token URI needs only db.crt" 'sb_available'

exit $fail
