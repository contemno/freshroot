#!/bin/bash
# freshroot-menu-lib.sh — lineage helpers for the stage-1 kexec boot menu.
#
# SYNC (partial copy: snap_ts, snap_label, lineage_of_root, snapshot_lineage,
# ceremony_capable, lineage_cmdline, display_ts): the canonical versions live
# in /etc/grub.d/06_freshroot (whose own canonical sources are freshroot-update
# / freshroot-build / freshroot-install). This copy runs inside the stage-1
# initramfs without set -u or pipefail — keep every per-snapshot lookup
# ||-guarded. Fix every copy together.

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
