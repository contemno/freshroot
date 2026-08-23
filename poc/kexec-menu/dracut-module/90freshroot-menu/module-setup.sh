#!/bin/bash
# dracut module: freshroot stage-1 kexec boot menu (PoC).
# Built into a NON-systemd initramfs (see build-stage1.sh) — the menu takes
# over the console at the mount hook and never hands control to an init.

check() {
    require_binaries cryptsetup btrfs kexec cpio || return 1
    return 0
}

depends() {
    # crypt: dm plumbing, crypto kernel modules, udev rules (its own hooks
    # stay inert — stage 1 has no rd.luks.* args and drives cryptsetup
    # directly). btrfs: btrfs device scan udev glue.
    echo "crypt btrfs"
}

# shellcheck disable=SC2154  # moddir and initdir are provided by dracut
install() {
    inst_hook cmdline 91 "$moddir/parse-freshroot-menu.sh"
    inst_hook mount 98 "$moddir/mount-freshroot-menu.sh"

    inst_simple "$moddir/freshroot-menu-lib.sh" /lib/freshroot-menu-lib.sh
    inst_simple "$moddir/freshroot-menu.sh" /bin/freshroot-menu
    chmod 0755 "${initdir}/bin/freshroot-menu"

    inst_multiple bash cryptsetup btrfs kexec blkid cpio \
        mount umount mkdir rmdir mktemp cat head tail tac sort sed awk tr \
        grep wc stty dd stat sync shred sleep seq chmod readlink udevadm
}

installkernel() {
    # Non-hostonly driver set for the QEMU rig plus common real hardware.
    hostonly='' instmods dm_crypt btrfs vfat ext4 \
        virtio_blk virtio_pci virtio_scsi virtio_console sd_mod nvme ahci
}
