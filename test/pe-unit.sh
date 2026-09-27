#!/bin/bash
# pe-unit.sh — unit tests for the stage-1 PE section reader
# (pe_section_info / pe_has_signature in 90freshroot-stage1/freshroot-menu-lib.sh).
#
# Builds a synthetic PE32+ with python3 (always) and a real UKI with ukify
# (when installed) and checks that section extraction reproduces the exact
# payload bytes — including the VirtualSize-vs-SizeOfRawData padding rule.
#
# shellcheck disable=SC2016  # check() expressions are single-quoted for eval
# shellcheck disable=SC2317  # extract() is called via the eval'd expressions
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$(dirname "$HERE")/data/usr/lib/dracut/modules.d/90freshroot-stage1/freshroot-menu-lib.sh"
# shellcheck source=/dev/null
. "$LIB"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }

extract() { # file section out
    pe_section_info "$1" "$2" || return 1
    dd if="$1" of="$3" bs=1M iflag=skip_bytes,count_bytes skip="$PE_OFF" count="$PE_SIZE" 2>/dev/null
}

# ── Synthetic PE32+: two sections, raw data padded past VirtualSize ──
head -c 3001 /dev/urandom > "$T/linux.bin"
head -c 777  /dev/urandom > "$T/initrd.bin"
python3 - "$T" <<'PY'
import struct, sys, os
t = sys.argv[1]
linux = open(os.path.join(t, "linux.bin"), "rb").read()
initrd = open(os.path.join(t, "initrd.bin"), "rb").read()
FA = 512
def pad(b): return b + b"\0" * ((FA - len(b) % FA) % FA)

def build(signed, out):
    pe_off = 0x80
    nsec = 2
    optsz = 240                      # PE32+ optional header size
    tbl = pe_off + 24 + optsz
    hdr_end = tbl + 40 * nsec
    data_start = (hdr_end + FA - 1) // FA * FA
    lraw, iraw = pad(linux), pad(initrd)
    lptr = data_start
    iptr = lptr + len(lraw)
    cert = b"\x11" * 64 if signed else b""
    cptr = iptr + len(iraw)

    dos = bytearray(b"MZ" + b"\0" * 62); struct.pack_into("<I", dos, 60, pe_off)
    dos += b"\0" * (pe_off - 64)
    coff = b"PE\0\0" + struct.pack("<HHIIIHH", 0x8664, nsec, 0, 0, 0, optsz, 0x22)
    opt = bytearray(optsz)
    struct.pack_into("<H", opt, 0, 0x20b)
    struct.pack_into("<I", opt, 32, FA)          # SectionAlignment (unused)
    struct.pack_into("<I", opt, 36, FA)          # FileAlignment
    struct.pack_into("<I", opt, 108, 16)         # NumberOfRvaAndSizes
    if signed:
        struct.pack_into("<II", opt, 112 + 4 * 8, cptr, len(cert))  # cert table dir
    def sec(name, vsize, rawsz, ptr):
        return struct.pack("<8sIIIIIIHHI", name, vsize, 0x1000, rawsz, ptr, 0, 0, 0, 0, 0x40000040)
    secs = sec(b".linux", len(linux), len(lraw), lptr) + sec(b".initrd", len(initrd), len(iraw), iptr)
    img = bytes(dos) + coff + bytes(opt) + secs
    img += b"\0" * (data_start - len(img)) + lraw + iraw + cert
    open(out, "wb").write(img)

build(False, os.path.join(t, "plain.efi"))
build(True, os.path.join(t, "signed.efi"))
PY

check "synthetic: .linux extracts byte-exact (VirtualSize, not padded raw)" \
    'extract "$T/plain.efi" .linux "$T/out.linux" && cmp -s "$T/out.linux" "$T/linux.bin"'
check "synthetic: .initrd extracts byte-exact" \
    'extract "$T/plain.efi" .initrd "$T/out.initrd" && cmp -s "$T/out.initrd" "$T/initrd.bin"'
check "synthetic: missing section is reported" \
    '! pe_section_info "$T/plain.efi" .cmdline'
check "synthetic: unsigned PE has no signature" \
    '! pe_has_signature "$T/plain.efi"'
check "synthetic: signed PE reports a signature" \
    'pe_has_signature "$T/signed.efi"'
check "non-PE input is rejected" \
    '! pe_section_info "$T/linux.bin" .linux'

# ── Real UKI via ukify, when available ───────────────────────────────
if command -v ukify >/dev/null 2>&1 && [ -r /usr/lib/systemd/boot/efi/linuxx64.efi.stub ]; then
    head -c 200000 /dev/urandom > "$T/vmlinuz.bin"
    head -c 50000  /dev/urandom > "$T/initrd2.bin"
    if ukify build --linux "$T/vmlinuz.bin" --initrd "$T/initrd2.bin" \
            --cmdline "root=freshroot" --uname 0.0-test \
            --output "$T/real.efi" >/dev/null 2>&1; then
        check "ukify: .linux extracts byte-exact" \
            'extract "$T/real.efi" .linux "$T/r.linux" && cmp -s "$T/r.linux" "$T/vmlinuz.bin"'
        check "ukify: .initrd extracts byte-exact" \
            'extract "$T/real.efi" .initrd "$T/r.initrd" && cmp -s "$T/r.initrd" "$T/initrd2.bin"'
        check "ukify: unsigned UKI has no signature" '! pe_has_signature "$T/real.efi"'
        if command -v sbsign >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; then
            openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=freshroot-test/" \
                -keyout "$T/db.key" -out "$T/db.crt" >/dev/null 2>&1
            if sbsign --key "$T/db.key" --cert "$T/db.crt" --output "$T/real.signed.efi" "$T/real.efi" >/dev/null 2>&1; then
                check "sbsign: signed UKI reports a signature" 'pe_has_signature "$T/real.signed.efi"'
                check "sbsign: sections still extract after signing" \
                    'extract "$T/real.signed.efi" .linux "$T/s.linux" && cmp -s "$T/s.linux" "$T/vmlinuz.bin"'
            else
                echo "SKIP: sbsign failed to sign the fixture"
            fi
        else
            echo "SKIP: sbsign/openssl not installed"
        fi
    else
        echo "SKIP: ukify build failed (stub/tooling mismatch)"
    fi
else
    echo "SKIP: ukify or sd-stub not installed — synthetic PE checks only"
fi

exit $fail
