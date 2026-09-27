#!/bin/bash
# freshroot-menu-lib.sh — lineage helpers for the stage-1 kexec boot menu.
#
# SYNC (partial copy: snap_ts, snap_label, lineage_of_root, snapshot_lineage,
# ceremony_capable, lineage_cmdline, display_ts): the canonical versions live
# in freshroot-update / freshroot-build / freshroot-install. This copy runs
# inside the stage-1 initramfs without set -u or pipefail — keep every
# per-snapshot lookup ||-guarded. Fix every copy together.
#
# The PE helpers below are the stage-1 UKI reader: kexec never runs a UKI's
# EFI stub, so the menu extracts the .linux/.initrd sections itself.

# Timestamp field of a snapshot name; empty if the name has none.
snap_ts() {
    _n="${1##*/}"; _n="${_n#root.}"; _last="${_n##*.}"
    if [[ "$_last" =~ ^[0-9]{8}T[0-9]{6}$ ]]; then
        printf '%s\n' "$_last"
    fi
}

# Lineage label encoded in a snapshot name; empty for legacy names.
snap_label() {
    _n="${1##*/}"; _n="${_n#root.}"; _last="${_n##*.}"
    if [[ "$_last" =~ ^[0-9]{8}T[0-9]{6}$ ]] && [ "${_n#*.}" != "$_n" ]; then
        printf '%s\n' "${_n%.*}"
    fi
}

# Default lineage of a root tree from its os-release (never sourced; the
# usr/lib copy is preferred and absolute /etc symlinks are re-rooted into
# the tree). Echoes "unknown" when unreadable.
lineage_of_root() {
    _root="$1"; _f=""; _id=""; _ver=""
    if [ -r "${_root}/usr/lib/os-release" ] && [ ! -L "${_root}/usr/lib/os-release" ]; then
        _f="${_root}/usr/lib/os-release"
    elif [ -L "${_root}/etc/os-release" ]; then
        _tgt=$(readlink "${_root}/etc/os-release" 2>/dev/null) || _tgt=""
        case "$_tgt" in
            /*) [ -r "${_root}${_tgt}" ] && _f="${_root}${_tgt}" ;;
            *)  [ -r "${_root}/etc/os-release" ] && _f="${_root}/etc/os-release" ;;
        esac
    elif [ -r "${_root}/etc/os-release" ]; then
        _f="${_root}/etc/os-release"
    fi
    if [ -n "$_f" ]; then
        _id=$(sed -n 's/^ID=//p' "$_f" 2>/dev/null | head -1 | tr -d '"' \
              | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9._-') || _id=""
        _ver=$(sed -n 's/^VERSION_ID=//p' "$_f" 2>/dev/null | head -1 | tr -d '"' \
               | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9._-') || _ver=""
    fi
    if [ -n "$_id" ] && [ -n "$_ver" ]; then
        printf '%s-%s\n' "$_id" "$_ver"
    elif [ -n "$_id" ]; then
        printf '%s\n' "$_id"
    else
        printf 'unknown\n'
    fi
}

# Lineage of an existing snapshot: the name label, else the tree's os-release.
snapshot_lineage() {
    _lbl=$(snap_label "$1")
    if [ -n "$_lbl" ]; then
        printf '%s\n' "$_lbl"
    else
        lineage_of_root "$1"
    fi
}

# Does the tree implement the freshroot boot ceremony?
ceremony_capable() {
    [ -f "$1/usr/lib/freshroot/ceremony" ] && return 0
    [ -f "$1/usr/lib/dracut/modules.d/90freshroot/freshroot-setup.sh" ] && return 0
    return 1
}

# Optional per-lineage cmdline snippet (replaces the rd.luks.* parameters).
lineage_cmdline() {
    if [ -r "$1/etc/freshroot/cmdline" ]; then
        head -1 "$1/etc/freshroot/cmdline" 2>/dev/null || true
    fi
}

# Human-readable timestamp for a snapshot name.
display_ts() {
    _t=$(snap_ts "$1")
    if [[ "$_t" =~ ^(....)(..)(..)T(..)(..)(..)$ ]]; then
        printf '%s-%s-%s %s:%s:%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" \
            "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}"
    else
        printf '%s\n' "$1"
    fi
}

# ── PE section reader (UKI consumption) ──────────────────────────────
# Minimal PE/COFF parsing with od/dd only: no objcopy, no sidecar maps.
pe_u16() { od -An -tu2 -j "$2" -N 2 "$1" 2>/dev/null | tr -d ' '; }
pe_u32() { od -An -tu4 -j "$2" -N 4 "$1" 2>/dev/null | tr -d ' '; }

# File offset of the PE signature ("PE\0\0"), or failure for a non-PE file.
pe_header_offset() {
    _ph=$(pe_u32 "$1" 60) || return 1
    [ -n "$_ph" ] || return 1
    [ "$(dd if="$1" bs=1 skip="$_ph" count=2 2>/dev/null)" = "PE" ] || return 1
    printf '%s' "$_ph"
}

# pe_section_info FILE NAME — sets PE_OFF/PE_SIZE (raw file offset and
# payload length) of the named section, e.g. ".linux" or ".initrd".
# Payload length is VirtualSize when it fits inside SizeOfRawData (ukify
# pads raw data to FileAlignment — copying the padding would append junk
# to the kernel/initrd), else SizeOfRawData. Returns 1 when absent.
# shellcheck disable=SC2034  # PE_OFF/PE_SIZE are read by the caller
pe_section_info() {
    PE_OFF=""; PE_SIZE=""
    _psf="$1"; _psn="$2"
    _pe=$(pe_header_offset "$_psf") || return 1
    _nsec=$(pe_u16 "$_psf" $((_pe + 6)))
    _optsz=$(pe_u16 "$_psf" $((_pe + 20)))
    [ -n "$_nsec" ] && [ -n "$_optsz" ] || return 1
    _tbl=$((_pe + 24 + _optsz))
    _i=0
    while [ "$_i" -lt "$_nsec" ]; do
        _ent=$((_tbl + _i * 40))
        _name=$(dd if="$_psf" bs=1 skip="$_ent" count=8 2>/dev/null | tr -d '\0')
        if [ "$_name" = "$_psn" ]; then
            _vsize=$(pe_u32 "$_psf" $((_ent + 8)))
            _rawsz=$(pe_u32 "$_psf" $((_ent + 16)))
            _ptr=$(pe_u32 "$_psf" $((_ent + 20)))
            if [ "$_vsize" -gt 0 ] && [ "$_vsize" -le "$_rawsz" ]; then
                PE_SIZE="$_vsize"
            else
                PE_SIZE="$_rawsz"
            fi
            PE_OFF="$_ptr"
            return 0
        fi
        _i=$((_i + 1))
    done
    return 1
}

# True when the PE carries an Authenticode certificate table (data
# directory entry 4 has a non-zero size) — i.e. it is Secure-Boot signed.
pe_has_signature() {
    _pe=$(pe_header_offset "$1") || return 1
    _magic=$(pe_u16 "$1" $((_pe + 24)))
    case "$_magic" in
        523) _dd=$((_pe + 24 + 112)) ;;   # 0x20b PE32+
        267) _dd=$((_pe + 24 + 96)) ;;    # 0x10b PE32
        *) return 1 ;;
    esac
    _certsz=$(pe_u32 "$1" $((_dd + 4 * 8 + 4)))
    [ -n "$_certsz" ] && [ "$_certsz" -gt 0 ]
}
