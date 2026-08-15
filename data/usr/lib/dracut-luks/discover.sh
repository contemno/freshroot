# shellcheck shell=sh
# /usr/lib/dracut-luks/discover.sh
#
# Locate the LUKS container holding / and derive the dracut unlock
# parameters for it.
#
# POSIX sh, because it is sourced from two very different places:
#
#   /etc/default/grub.d/99-dracut-luks.cfg  — inside grub-mkconfig, which is
#                                             /bin/sh and runs under `set -e`
#   /usr/sbin/dracut-luks-setup             — bash, `set -euo pipefail`
#
# So: no bashisms, no arrays, every variable initialized, and every command
# that can fail either guarded or inside the function. ALWAYS call
# dracut_luks_discover from a condition (`if dracut_luks_discover; then`) —
# calling it bare under `set -e` would abort update-grub on an unencrypted
# system, which is a supported configuration, not an error.
#
# On success sets: DL_ROOT_SRC DL_LUKS_DEV DL_LUKS_UUID DL_MAP_NAME
#                  DL_VG_NAME DL_PARAMS
# Returns non-zero (with all of them empty) when / is not on LUKS.

# Recover a volume-group name from a device-mapper name. dm escapes '-' in
# VG and LV names as '--', so vgubuntu-root -> vgubuntu but my--vg-root ->
# my-vg. Split on the first single hyphen, then unescape.
_dl_vg_from_dm() {
    printf '%s\n' "$1" \
        | sed -n 's/^\(\([^-]\|--\)*\)-[^-].*$/\1/p' \
        | sed 's/--/-/g'
}

dracut_luks_discover() {
    DL_ROOT_SRC=''
    DL_LUKS_DEV=''
    DL_LUKS_UUID=''
    DL_MAP_NAME=''
    DL_VG_NAME=''
    DL_PARAMS=''

    _dl_chain=''
    if [ -n "${DL_LSBLK_FIXTURE:-}" ]; then
        [ -r "$DL_LSBLK_FIXTURE" ] || return 1
        _dl_chain=$(cat "$DL_LSBLK_FIXTURE" 2>/dev/null)
    else
        command -v findmnt >/dev/null 2>&1 || return 1
        command -v lsblk   >/dev/null 2>&1 || return 1
        DL_ROOT_SRC=$(findmnt -n -o SOURCE / 2>/dev/null | head -1)
        # Strip a btrfs subvolume suffix, e.g. /dev/mapper/root[/@rootfs]
        DL_ROOT_SRC=${DL_ROOT_SRC%%\[*}
        [ -n "$DL_ROOT_SRC" ] || return 1
        # -s walks parents; -P is key="value" so an empty column cannot shift
        # the fields of the one after it.
        _dl_chain=$(lsblk -nPspo NAME,TYPE,FSTYPE,UUID "$DL_ROOT_SRC" 2>/dev/null)
    fi
    [ -n "$_dl_chain" ] || return 1

    # The chain reads device-first, so for LUKS -> LVM -> ext4:
    #
    #   NAME="/dev/mapper/vgubuntu-root" TYPE="lvm"   FSTYPE="ext4"
    #   NAME="/dev/mapper/dm_crypt-0"    TYPE="crypt" FSTYPE="LVM2_member"
    #   NAME="/dev/nvme0n1p3"            TYPE="part"  FSTYPE="crypto_LUKS"
    #   NAME="/dev/nvme0n1"              TYPE="disk"  FSTYPE=""
    #
    # Rows before the crypto_LUKS one are seen first, so keeping the last
    # crypt/lvm row seen leaves the one nearest the container — the mapping
    # dracut has to recreate, and the VG it has to activate.
    _dl_parsed=$(printf '%s\n' "$_dl_chain" | awk '
        function val(line, key,   s, p) {
            p = key "=\"[^\"]*\""
            if (match(line, p)) {
                s = substr(line, RSTART, RLENGTH)
                return substr(s, length(key) + 3, length(s) - length(key) - 3)
            }
            return ""
        }
        {
            name = val($0, "NAME"); type = val($0, "TYPE")
            fstype = val($0, "FSTYPE"); uuid = val($0, "UUID")
            if (name == "") next
            if (first == "") first = name
            if (found) next
            if (fstype == "crypto_LUKS") {
                luksdev = name; luksuuid = uuid; found = 1; next
            }
            if (type == "crypt") map = name
            if (type == "lvm")   lvdev = name
        }
        END {
            if (!found) exit 1
            printf "%s\n%s\n%s\n%s\n%s\n", first, luksdev, luksuuid, map, lvdev
        }
    ') || return 1

    [ -n "$DL_ROOT_SRC" ] || DL_ROOT_SRC=$(printf '%s\n' "$_dl_parsed" | sed -n 1p)
    DL_LUKS_DEV=$(printf  '%s\n' "$_dl_parsed" | sed -n 2p)
    DL_LUKS_UUID=$(printf '%s\n' "$_dl_parsed" | sed -n 3p)
    _dl_map=$(printf      '%s\n' "$_dl_parsed" | sed -n 4p)
    _dl_lvdev=$(printf    '%s\n' "$_dl_parsed" | sed -n 5p)

    [ -n "$DL_LUKS_UUID" ] || return 1

    if [ -n "$_dl_map" ]; then
        DL_MAP_NAME=$(basename "$_dl_map")
    fi

    if [ -n "$_dl_lvdev" ]; then
        if [ -z "${DL_LSBLK_FIXTURE:-}" ] && command -v lvs >/dev/null 2>&1; then
            DL_VG_NAME=$(lvs --noheadings -o vg_name "$_dl_lvdev" 2>/dev/null \
                         | tr -d '[:space:]')
        fi
        if [ -z "$DL_VG_NAME" ]; then
            DL_VG_NAME=$(_dl_vg_from_dm "$(basename "$_dl_lvdev")")
        fi
    fi

    # rd.luks.name= needs a mapping name; without one, still ask dracut to
    # unlock the container (it will pick its own name) rather than emitting a
    # malformed parameter.
    DL_PARAMS="rd.luks.uuid=${DL_LUKS_UUID}"
    if [ -n "$DL_MAP_NAME" ]; then
        DL_PARAMS="${DL_PARAMS} rd.luks.name=${DL_LUKS_UUID}=${DL_MAP_NAME}"
    fi
    if [ -n "$DL_VG_NAME" ]; then
        DL_PARAMS="${DL_PARAMS} rd.lvm.vg=${DL_VG_NAME}"
    fi

    return 0
}
