#!/bin/bash
# /bin/freshroot-menu — stage-1 boot menu.
#
# Runs from the mount hook of the minimal non-systemd stage-1 initramfs:
#   1. unlock the LUKS volume (prompt, or /etc/freshroot/test-keyfile for CI)
#   2. mount the btrfs top-level read-only; index @snapshots and the kernel
#      store on the modules subvolume (.freshroot/uki/uki-<kver>.efi)
#   3. present a serial-friendly menu: snapshots × kernels, countdown to the
#      default (default lineage's newest snapshot, newest kernel)
#   4. extract .linux/.initrd from the chosen UKI (kexec never runs the EFI
#      stub), append a keyfile cpio so stage 2 unlocks LUKS without a second
#      prompt, and kexec with a dynamically built cmdline
#
# Any kernel boots any snapshot: modules live on the shared modules
# subvolume, snapshots carry no kernels. On success this never returns
# (kexec -e). On unrecoverable failure it drops to an interactive shell;
# exiting that shell returns to the menu loop.
#
# Stage-1 cmdline knobs (baked in by `freshroot-kernel stage1`):
#   rd.freshroot.timeout=N   countdown seconds (0 = no countdown)
#   rd.freshroot.modules=@x  modules subvolume name (default @modules)
#   rd.freshroot.dev=/dev/x  LUKS device (default: first crypto_LUKS found)
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

# Kernel lockdown (Secure Boot): legacy kexec_load is refused and
# kexec_file_load verifies the loaded kernel's signature.
lockdown_active() {
    grep -qE '\[(integrity|confidentiality)\]' /sys/kernel/security/lockdown 2>/dev/null
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

# ── Snapshot index (mirrors the tools' list_ro_snapshots) ────────────
# Lines: "TS<TAB>lineage<TAB>name", TS-sorted oldest first. Snapshots with
# no parseable timestamp are not listed.
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

# ── Kernel store ─────────────────────────────────────────────────────
# "kver<TAB>path" lines for every UKI in the store, newest kver first.
store_kernels() {
    for _sk_f in "${UKI_DIR}"/uki-*.efi; do
        [ -f "$_sk_f" ] || continue
        _sk_k="${_sk_f##*/uki-}"; _sk_k="${_sk_k%.efi}"
        printf '%s\t%s\n' "$_sk_k" "$_sk_f"
    done | sort -rV
    return 0
}

# ── Target cmdline (mirrors what 06_freshroot used to emit) ──────────
build_cmdline() {
    # $1 = subvol (@ or @snapshots/<name>), $2 = tree path, $3 = "yes" for
    # rd.freshroot, $4 = extra args
    _bc_btrfs_uuid=$(blkid -s UUID -o value "/dev/mapper/${DM_NAME}" 2>/dev/null) || _bc_btrfs_uuid=""
    _bc_luks_uuid=$(blkid -s UUID -o value "$LUKS_DEV" 2>/dev/null) || _bc_luks_uuid=""
    # stage 2 maps the volume under the name its own crypttab uses
    _bc_dm=$(awk '$1 !~ /^#/ && NF>=2 {print $1; exit}' "$2/etc/crypttab" 2>/dev/null) || _bc_dm=""
    [ -n "$_bc_dm" ] || _bc_dm="$DM_NAME"
    _bc_luks="rd.luks.uuid=${_bc_luks_uuid} rd.luks.name=${_bc_luks_uuid}=${_bc_dm} rd.luks.key=/freshroot-luks.key"
    # A tree's /etc/freshroot/cmdline snippet REPLACES the rd.luks.* block —
    # foreign initramfses unlock their own way.
    _bc_snippet=$(lineage_cmdline "$2")
    [ -n "$_bc_snippet" ] && _bc_luks="$_bc_snippet"
    CMDLINE="root=UUID=${_bc_btrfs_uuid} ro rootflags=subvol=$1 ${_bc_luks}"
    [ "$3" = "yes" ] && CMDLINE="${CMDLINE} rd.freshroot=1"
    [ -n "$4" ] && CMDLINE="${CMDLINE} $4"
    _bc_console=$(console_args)
    [ -n "$_bc_console" ] && CMDLINE="${CMDLINE} ${_bc_console}"
}

# ── UKI section extraction ───────────────────────────────────────────
# Writes /freshroot-vmlinuz and /freshroot-initrd from the UKI's .linux and
# .initrd sections (tmpfs, freed before kexec -e).
extract_uki() {
    rm -f /freshroot-vmlinuz /freshroot-initrd
    if ! pe_section_info "$1" .linux; then
        msg "${1##*/}: no .linux section (not a UKI?)"; return 1
    fi
    dd if="$1" of=/freshroot-vmlinuz bs=1M iflag=skip_bytes,count_bytes \
        skip="$PE_OFF" count="$PE_SIZE" 2>/dev/null || { msg "extracting .linux failed"; return 1; }
    if ! pe_section_info "$1" .initrd; then
        msg "${1##*/}: no .initrd section"; return 1
    fi
    dd if="$1" of=/freshroot-initrd bs=1M iflag=skip_bytes,count_bytes \
        skip="$PE_OFF" count="$PE_SIZE" 2>/dev/null || { msg "extracting .initrd failed"; return 1; }
    return 0
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
    # kexec_file_load first (verifies the kernel signature under lockdown);
    # legacy kexec_load only when lockdown is off (it is refused otherwise).
    if ! kexec -s -l "$1" --initrd=/freshroot-merged.initrd --command-line="$3"; then
        if lockdown_active; then
            msg "kexec_file_load failed under lockdown — is this kernel signed with an enrolled key?"
            rm -rf "$_dk_keydir" /freshroot-key.cpio /freshroot-merged.initrd
            return 1
        fi
        msg "kexec_file_load failed — trying legacy kexec_load"
        if ! kexec -l "$1" --initrd=/freshroot-merged.initrd --command-line="$3"; then
            rm -rf "$_dk_keydir" /freshroot-key.cpio /freshroot-merged.initrd
            return 1
        fi
    fi
    # Both load paths copy all segments into kernel memory at load time, so
    # the staging files can be destroyed before -e. Best-effort scrub: the
    # loaded segments and stage-2 initramfs still hold the key in RAM.
    shred -u /freshroot-merged.initrd /freshroot-key.cpio "${_dk_keydir}/freshroot-luks.key" \
        /freshroot-vmlinuz /freshroot-initrd 2>/dev/null \
        || rm -f /freshroot-merged.initrd /freshroot-key.cpio "${_dk_keydir}/freshroot-luks.key" \
                 /freshroot-vmlinuz /freshroot-initrd
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

# Boot a tree with the selected kernel. $1 = subvol, $2 = tree path,
# $3 = "yes" for rd.freshroot, $4 = extra args.
boot_tree() {
    if [ -z "$SEL_UKI" ]; then
        msg "kernel store is empty — nothing to boot (run freshroot-kernel add)"
        return 1
    fi
    msg "kernel ${SEL_KVER} from ${SEL_UKI##*/}"
    extract_uki "$SEL_UKI" || return 1
    if lockdown_active && ! pe_has_signature /freshroot-vmlinuz; then
        msg "REFUSING: the kernel inside ${SEL_UKI##*/} is unsigned and lockdown is active"
        rm -f /freshroot-vmlinuz /freshroot-initrd
        return 1
    fi
    build_cmdline "$1" "$2" "$3" "$4"
    do_kexec /freshroot-vmlinuz /freshroot-initrd "$CMDLINE"
}

boot_snapshot() {
    _bs_tree="${TOPLEVEL}/${SNAPSHOTS_DIR}/$1"
    _bs_cap=""
    ceremony_capable "$_bs_tree" && _bs_cap=yes
    [ -n "$_bs_cap" ] || msg "NO CEREMONY: booting $1 read-only, without rd.freshroot"
    boot_tree "${SNAPSHOTS_DIR}/$1" "$_bs_tree" "$_bs_cap" ""
}

boot_tainted() {
    boot_tree "$ROOT_SUBVOL" "${TOPLEVEL}/${ROOT_SUBVOL}" "" \
        "systemd.mask=freshroot-update.service systemd.mask=freshroot-update.timer"
}

# Select kernel by index into KERNEL_LIST (newest first). Sets SEL_KVER,
# SEL_UKI, SEL_TAG.
select_kernel() {
    SEL_KVER=""; SEL_UKI=""; SEL_TAG=""
    _sk_line=$(printf '%s\n' "$KERNEL_LIST" | sed -n "$(( $1 + 1 ))p")
    [ -n "$_sk_line" ] || return 1
    SEL_KVER="${_sk_line%%"${TAB}"*}"
    SEL_UKI="${_sk_line#*"${TAB}"}"
    if pe_has_signature "$SEL_UKI"; then
        SEL_TAG="[signed]"
    elif lockdown_active; then
        SEL_TAG="[UNSIGNED — will not boot under Secure Boot]"
    else
        SEL_TAG="[unsigned]"
    fi
    return 0
}

# ═════════════════════════════════════════════════════════════════════
# Main
# ═════════════════════════════════════════════════════════════════════
exec </dev/console >/dev/console 2>&1
stty sane 2>/dev/null || true

MODULES_SUBVOL=$(cmdline_value rd.freshroot.modules)
[ -n "$MODULES_SUBVOL" ] || MODULES_SUBVOL=@modules
UKI_DIR="${TOPLEVEL}/${MODULES_SUBVOL}/.freshroot/uki"

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
KERNEL_LIST=$(store_kernels)
KERNEL_COUNT=$(printf '%s\n' "$KERNEL_LIST" | grep -c .)
KERNEL_IDX=0
select_kernel "$KERNEL_IDX" || true

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

# Default entry: the first listed snapshot (any kernel boots any snapshot).
DEFAULT_IDX=""
[ ${#MENU_NAMES[@]} -gt 0 ] && DEFAULT_IDX=0

TIMEOUT=$(cmdline_value rd.freshroot.timeout)
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=5 ;; esac

FIRST_PASS=1
while :; do
    echo
    echo "freshroot boot menu"
    if [ "$KERNEL_COUNT" -eq 0 ]; then
        echo "  kernel: NONE — store ${MODULES_SUBVOL}/.freshroot/uki is empty (freshroot-kernel add)"
    else
        echo "  kernel: ${SEL_KVER} ${SEL_TAG}  (k = next of ${KERNEL_COUNT})"
    fi
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
        ceremony_capable "$_tree" || _tag="${_tag} [NO CEREMONY]"
        printf '  %d) %-16s %s  %s%s\n' "$((_i + 1))" "$_lin" "$_tsd" "$_name" "$_tag"
    done
    echo "  t) tainted ${ROOT_SUBVOL}  (skip rollback, updates masked)"
    echo "  k) next kernel"
    echo "  s) shell (debug)"

    choice=""
    if [ "$FIRST_PASS" = "1" ] && [ "$TIMEOUT" -gt 0 ] && [ -n "$DEFAULT_IDX" ] && [ "$KERNEL_COUNT" -gt 0 ]; then
        remaining=$TIMEOUT
        while [ "$remaining" -gt 0 ]; do
            printf '\rBooting %s (%s) in %ds — press any key for menu ' \
                "${MENU_NAMES[$DEFAULT_IDX]}" "$SEL_KVER" "$remaining"
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
        k)
            if [ "$KERNEL_COUNT" -gt 0 ]; then
                KERNEL_IDX=$(( (KERNEL_IDX + 1) % KERNEL_COUNT ))
                select_kernel "$KERNEL_IDX" || true
            fi
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
