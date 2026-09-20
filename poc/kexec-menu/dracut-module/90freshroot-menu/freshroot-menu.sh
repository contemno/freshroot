#!/bin/bash
# /bin/freshroot-menu — stage-1 kexec boot menu (PoC).
#
# Runs from the mount hook of a minimal non-systemd dracut initramfs:
#   1. unlock the LUKS volume (prompt, or /etc/freshroot/test-keyfile for CI)
#   2. mount the btrfs top-level read-only and index @snapshots
#   3. present a serial-friendly menu (countdown to the default entry)
#   4. kexec into the chosen snapshot's own /boot kernel, appending a keyfile
#      cpio to its initrd so stage 2 unlocks LUKS without a second prompt
#
# On success this never returns (kexec -e). On unrecoverable failure it drops
# to an interactive shell; exiting that shell returns to the menu loop.
#
# No set -e: this is an interactive loop — every failure path is handled.

# shellcheck source=/dev/null
. /lib/freshroot-menu-lib.sh

TOPLEVEL=/freshroot/toplevel
SNAPSHOTS_DIR=@snapshots
ROOT_SUBVOL=@
STATE_REL=freshroot-state/default-lineage
DM_NAME=crypt-root
KEYFILE_SRC=""
TAB=$(printf '\t')

msg() { echo "freshroot-menu: $*"; }

debug_shell() {
    echo "freshroot-menu: $*" >&2
    echo "freshroot-menu: dropping to a debug shell (exit to return to the menu)" >&2
    /bin/bash -i
}

cmdline_value() {
    # Value of key=... on the stage-1 cmdline; last occurrence wins.
    _cv_out=""
    _cv_line=$(cat /proc/cmdline 2>/dev/null) || _cv_line=""
    for _cv_arg in $_cv_line; do
        case "$_cv_arg" in "$1"=*) _cv_out="${_cv_arg#*=}" ;; esac
    done
    printf '%s' "$_cv_out"
}

console_args() {
    # Every console= argument of the stage-1 cmdline, propagated to stage 2.
    _ca_out=""
    _ca_line=$(cat /proc/cmdline 2>/dev/null) || _ca_line=""
    for _ca_arg in $_ca_line; do
        case "$_ca_arg" in console=*) _ca_out="${_ca_out:+${_ca_out} }${_ca_arg}" ;; esac
    done
    printf '%s' "$_ca_out"
}

# ── LUKS device discovery and unlock ─────────────────────────────────
find_luks_dev() {
    _fd_dev=$(cmdline_value rd.freshroot.dev)
    for _fd_i in $(seq 1 30); do
        udevadm settle --timeout=2 2>/dev/null || true
        if [ -n "$_fd_dev" ]; then
            [ -b "$_fd_dev" ] && { printf '%s' "$_fd_dev"; return 0; }
        else
            _fd_found=$(blkid -t TYPE=crypto_LUKS -o device 2>/dev/null | head -1) || _fd_found=""
            [ -n "$_fd_found" ] && { printf '%s' "$_fd_found"; return 0; }
        fi
        msg "waiting for LUKS device (${_fd_i}/30)..."
        sleep 1
    done
    return 1
}

unlock_luks() {
    # Sets KEYFILE_SRC to a RAM-backed file holding the exact bytes that
    # unlocked the volume — the same bytes handed to stage 2, so a prompt
    # that worked here cannot fail there (cryptsetup keyfiles are verbatim:
    # written with printf, never echo — a trailing newline would become part
    # of the passphrase).
    _ul_dev="$1"
    if [ -r /etc/freshroot/test-keyfile ]; then
        msg "unlocking ${_ul_dev} with test keyfile"
        if cryptsetup open --key-file /etc/freshroot/test-keyfile "$_ul_dev" "$DM_NAME"; then
            KEYFILE_SRC=/etc/freshroot/test-keyfile
            return 0
        fi
        msg "test keyfile failed — falling back to prompt"
    fi
    for _ul_try in 1 2 3; do
        _ul_pass=""
        read -rs -p "freshroot: enter passphrase for ${_ul_dev}: " _ul_pass
        echo
        if printf '%s' "$_ul_pass" | cryptsetup open --key-file=- "$_ul_dev" "$DM_NAME"; then
            printf '%s' "$_ul_pass" > /freshroot-luks.pass
            chmod 0400 /freshroot-luks.pass
            KEYFILE_SRC=/freshroot-luks.pass
            _ul_pass=""
            return 0
        fi
        msg "unlock failed (attempt ${_ul_try}/3)"
    done
    return 1
}

# ── Snapshot index (mirrors 06_freshroot's SNAP_INDEX) ───────────────
# Lines: "TS<TAB>lineage<TAB>name", TS-sorted oldest first. Snapshots with
# no parseable timestamp are skipped (PoC limitation, noted in README).
build_index() {
    SNAP_INDEX=""
    for _bi_d in "${TOPLEVEL}/${SNAPSHOTS_DIR}"/root.*/; do
        [ -d "$_bi_d" ] || continue
        btrfs property get "${_bi_d%/}" ro 2>/dev/null | grep -q 'ro=true' || continue
        _bi_name="${_bi_d%/}"; _bi_name="${_bi_name##*/}"
        _bi_ts=$(snap_ts "$_bi_name")
        [ -n "$_bi_ts" ] || continue
        _bi_lin=$(snapshot_lineage "${_bi_d%/}") || _bi_lin=unknown
        SNAP_INDEX="${SNAP_INDEX}${_bi_ts}${TAB}${_bi_lin}${TAB}${_bi_name}
"
    done
    SNAP_INDEX=$(printf '%s' "$SNAP_INDEX" | sort)
}

default_lineage() {
    _dl_lin=""
    if [ -r "${TOPLEVEL}/${STATE_REL}" ]; then
        _dl_lin=$(head -1 "${TOPLEVEL}/${STATE_REL}" 2>/dev/null | tr -cd 'a-zA-Z0-9._-') || _dl_lin=""
    fi
    if [ -z "$_dl_lin" ]; then
        # Fallback: the lineage of the globally newest snapshot.
        _dl_lin=$(printf '%s\n' "$SNAP_INDEX" | awk -F'\t' 'NF==3{l=$2} END{print l}') || _dl_lin=""
    fi
    printf '%s' "$_dl_lin"
}

# ── In-tree kernel pairing ───────────────────────────────────────────
# Bootable kernels of a tree: "kver<TAB>vmlinuz<TAB>initrd" lines (absolute
# paths under the mounted top-level), newest first. A kernel is bootable if
# the tree carries vmlinuz + initrd in its own /boot AND the matching
# modules directory.
kernels_for_tree() {
    for _kt_f in "$1"/boot/vmlinuz-*; do
        [ -f "$_kt_f" ] || continue
        _kt_k="${_kt_f##*/vmlinuz-}"
        [ -d "$1/usr/lib/modules/${_kt_k}" ] || continue
        if [ -f "$1/boot/initrd.img-${_kt_k}" ]; then
            _kt_i="$1/boot/initrd.img-${_kt_k}"
        elif [ -f "$1/boot/initramfs-${_kt_k}.img" ]; then
            _kt_i="$1/boot/initramfs-${_kt_k}.img"
        else
            continue
        fi
        printf '%s\t%s\t%s\n' "$_kt_k" "$_kt_f" "$_kt_i"
    done | sort -rV
    return 0
}

# Sets BK_REL, BK_VMLINUZ, BK_INITRD. Returns 1 if the tree has no pair.
best_kernel_for_tree() {
    _bk_line=$(kernels_for_tree "$1" | head -1)
    [ -n "$_bk_line" ] || return 1
    IFS="$TAB" read -r BK_REL BK_VMLINUZ BK_INITRD <<< "$_bk_line"
    return 0
}

# ── Target cmdline (mirrors 06_freshroot's emit_entry) ───────────────
build_cmdline() {
    # $1 = subvol (@ or @snapshots/<name>), $2 = tree path, $3 = "yes" for
    # rd.freshroot, $4 = extra args
    _bc_btrfs_uuid=$(blkid -s UUID -o value "/dev/mapper/${DM_NAME}" 2>/dev/null) || _bc_btrfs_uuid=""
    _bc_luks_uuid=$(blkid -s UUID -o value "$LUKS_DEV" 2>/dev/null) || _bc_luks_uuid=""
    # stage 2 maps the volume under the name its own crypttab uses
    _bc_dm=$(awk '$1 !~ /^#/ && NF>=2 {print $1; exit}' "$2/etc/crypttab" 2>/dev/null) || _bc_dm=""
    [ -n "$_bc_dm" ] || _bc_dm="$DM_NAME"
    _bc_luks="rd.luks.uuid=${_bc_luks_uuid} rd.luks.name=${_bc_luks_uuid}=${_bc_dm} rd.luks.key=/freshroot-luks.key"
    # A tree's /etc/freshroot/cmdline snippet REPLACES the rd.luks.* block
    # (same rule as GRUB entries) — foreign initramfses unlock their own way.
    _bc_snippet=$(lineage_cmdline "$2")
    [ -n "$_bc_snippet" ] && _bc_luks="$_bc_snippet"
    CMDLINE="root=UUID=${_bc_btrfs_uuid} ro rootflags=subvol=$1 ${_bc_luks}"
    [ "$3" = "yes" ] && CMDLINE="${CMDLINE} rd.freshroot=1"
    [ -n "$4" ] && CMDLINE="${CMDLINE} $4"
    _bc_console=$(console_args)
    [ -n "$_bc_console" ] && CMDLINE="${CMDLINE} ${_bc_console}"
}

# ── kexec with the keyfile-cpio handoff ──────────────────────────────
do_kexec() {
    # $1 = vmlinuz, $2 = initrd, $3 = cmdline. Returns only on failure.
    _dk_keydir=$(mktemp -d /freshroot-key.XXXXXX) || return 1
    if ! cp "$KEYFILE_SRC" "${_dk_keydir}/freshroot-luks.key"; then
        rm -rf "$_dk_keydir"; return 1
    fi
    chmod 0400 "${_dk_keydir}/freshroot-luks.key"
    if ! ( cd "$_dk_keydir" && echo freshroot-luks.key | cpio -o -H newc --quiet ) > /freshroot-key.cpio; then
        rm -rf "$_dk_keydir" /freshroot-key.cpio; return 1
    fi
    # Pad the key segment to a 4-byte boundary — the kernel's initramfs
    # unpacker skips NUL padding between concatenated segments.
    _dk_sz=$(stat -c %s /freshroot-key.cpio)
    _dk_pad=$(( (4 - _dk_sz % 4) % 4 ))
    [ "$_dk_pad" -gt 0 ] && dd if=/dev/zero bs=1 count="$_dk_pad" >> /freshroot-key.cpio 2>/dev/null
    if ! cat "$2" /freshroot-key.cpio > /freshroot-merged.initrd; then
        rm -rf "$_dk_keydir" /freshroot-key.cpio /freshroot-merged.initrd; return 1
    fi

    msg "kernel : $1"
    msg "cmdline: $3"
    # kexec_file_load first (works under lockdown with signed kernels);
    # legacy kexec_load as fallback.
    if ! kexec -s -l "$1" --initrd=/freshroot-merged.initrd --command-line="$3" 2>/dev/null; then
        msg "kexec_file_load failed — trying legacy kexec_load"
        if ! kexec -l "$1" --initrd=/freshroot-merged.initrd --command-line="$3"; then
            rm -rf "$_dk_keydir" /freshroot-key.cpio /freshroot-merged.initrd
            return 1
        fi
    fi
    # Both load paths copy all segments into kernel memory at load time, so
    # the staging files can be destroyed before -e. Best-effort scrub: the
    # loaded segments and stage-2 initramfs still hold the key in RAM.
    shred -u /freshroot-merged.initrd /freshroot-key.cpio "${_dk_keydir}/freshroot-luks.key" 2>/dev/null \
        || rm -f /freshroot-merged.initrd /freshroot-key.cpio "${_dk_keydir}/freshroot-luks.key"
    rmdir "$_dk_keydir" 2>/dev/null
    umount "$TOPLEVEL" 2>/dev/null
    sync
    msg "executing kexec"
    kexec -e
    msg "kexec -e returned unexpectedly"
    # Remount so the menu can carry on
    mount -t btrfs -o ro,subvolid=5 "/dev/mapper/${DM_NAME}" "$TOPLEVEL" 2>/dev/null
    return 1
}

boot_snapshot() {
    _bs_name="$1"
    _bs_tree="${TOPLEVEL}/${SNAPSHOTS_DIR}/${_bs_name}"
    if ! best_kernel_for_tree "$_bs_tree"; then
        msg "snapshot ${_bs_name} has no bootable in-tree kernel pair"
        return 1
    fi
    msg "selected ${_bs_name} (kernel ${BK_REL})"
    _bs_cap=""
    ceremony_capable "$_bs_tree" && _bs_cap=yes
    [ -n "$_bs_cap" ] || msg "NO CEREMONY: booting ${_bs_name} read-only, without rd.freshroot"
    build_cmdline "${SNAPSHOTS_DIR}/${_bs_name}" "$_bs_tree" "$_bs_cap" ""
    do_kexec "$BK_VMLINUZ" "$BK_INITRD" "$CMDLINE"
}

boot_tainted() {
    _bt_tree="${TOPLEVEL}/${ROOT_SUBVOL}"
    if ! best_kernel_for_tree "$_bt_tree"; then
        msg "${ROOT_SUBVOL} has no bootable in-tree kernel pair"
        return 1
    fi
    build_cmdline "$ROOT_SUBVOL" "$_bt_tree" "" \
        "systemd.mask=freshroot-update.service systemd.mask=freshroot-update.timer"
    do_kexec "$BK_VMLINUZ" "$BK_INITRD" "$CMDLINE"
}

# ═════════════════════════════════════════════════════════════════════
# Main
# ═════════════════════════════════════════════════════════════════════
exec </dev/console >/dev/console 2>&1
stty sane 2>/dev/null || true

LUKS_DEV=$(find_luks_dev) || { debug_shell "no LUKS device found"; exec /bin/freshroot-menu; }
msg "LUKS device: $LUKS_DEV"

if ! unlock_luks "$LUKS_DEV"; then
    debug_shell "could not unlock $LUKS_DEV"
    exec /bin/freshroot-menu
fi

mkdir -p "$TOPLEVEL"
if ! mount -t btrfs -o ro,subvolid=5 "/dev/mapper/${DM_NAME}" "$TOPLEVEL"; then
    debug_shell "cannot mount btrfs top-level from /dev/mapper/${DM_NAME}"
    exec /bin/freshroot-menu
fi

build_index
DEFAULT_LINEAGE=$(default_lineage)

# Menu order: default lineage's snapshots newest-first, then the remaining
# lineages by their newest snapshot.
MENU_NAMES=()
ALL_LINEAGES=$(printf '%s\n' "$SNAP_INDEX" \
    | awk -F'\t' 'NF==3 { last[$2]=$1 } END { for (l in last) print last[l] "\t" l }' \
    | sort -r | cut -f2)
ORDERED_LINEAGES=$({ printf '%s\n' "$DEFAULT_LINEAGE"; \
    printf '%s\n' "$ALL_LINEAGES" | grep -Fvx "$DEFAULT_LINEAGE" || true; } | grep . )
for _lin in $ORDERED_LINEAGES; do
    while read -r _name; do
        [ -n "$_name" ] && MENU_NAMES+=("$_name")
    done < <(printf '%s\n' "$SNAP_INDEX" | awk -F'\t' -v l="$_lin" 'NF==3 && $2==l {print $3}' | tac)
done

# Default entry: the first listed snapshot with a bootable pair (mirrors
# emit_clean_for_lineage's newest-bootable walk).
DEFAULT_IDX=""
for _i in "${!MENU_NAMES[@]}"; do
    if [ -n "$(kernels_for_tree "${TOPLEVEL}/${SNAPSHOTS_DIR}/${MENU_NAMES[$_i]}")" ]; then
        DEFAULT_IDX=$_i
        break
    fi
done

TIMEOUT=$(cmdline_value rd.freshroot.timeout)
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=5 ;; esac

FIRST_PASS=1
while :; do
    echo
    echo "freshroot boot menu"
    if [ ${#MENU_NAMES[@]} -eq 0 ]; then
        echo "  (no snapshots found under ${SNAPSHOTS_DIR})"
    fi
    for _i in "${!MENU_NAMES[@]}"; do
        _name="${MENU_NAMES[$_i]}"
        _tree="${TOPLEVEL}/${SNAPSHOTS_DIR}/${_name}"
        _lin=$(snapshot_lineage "$_tree") || _lin=unknown
        _tsd=$(display_ts "$_name")
        _tag=""
        [ "$_i" = "$DEFAULT_IDX" ] && _tag=" [default]"
        [ -z "$(kernels_for_tree "$_tree")" ] && _tag="${_tag} (no kernel)"
        ceremony_capable "$_tree" || _tag="${_tag} [NO CEREMONY]"
        printf '  %d) %-16s %s  %s%s\n' "$((_i + 1))" "$_lin" "$_tsd" "$_name" "$_tag"
    done
    echo "  t) tainted ${ROOT_SUBVOL}  (skip rollback, updates masked)"
    echo "  s) shell (debug)"

    choice=""
    if [ "$FIRST_PASS" = "1" ] && [ "$TIMEOUT" -gt 0 ] && [ -n "$DEFAULT_IDX" ]; then
        remaining=$TIMEOUT
        while [ "$remaining" -gt 0 ]; do
            printf '\rBooting %s in %ds — press any key for menu ' \
                "${MENU_NAMES[$DEFAULT_IDX]}" "$remaining"
            if read -rs -n1 -t1 _key; then
                choice=""
                break
            fi
            remaining=$((remaining - 1))
        done
        echo
        [ "$remaining" -eq 0 ] && choice=$((DEFAULT_IDX + 1))
    fi
    FIRST_PASS=0

    if [ -z "$choice" ]; then
        read -rp "boot: " choice
    fi

    case "$choice" in
        t)
            boot_tainted || msg "tainted boot failed"
            ;;
        s)
            /bin/bash -i
            ;;
        ''|*[!0-9]*)
            msg "invalid selection: '${choice}'"
            ;;
        *)
            _sel=$((choice - 1))
            if [ "$_sel" -ge 0 ] && [ "$_sel" -lt ${#MENU_NAMES[@]} ]; then
                boot_snapshot "${MENU_NAMES[$_sel]}" || msg "boot failed"
            else
                msg "invalid selection: '${choice}'"
            fi
            ;;
    esac
done
