#!/bin/bash
# /usr/lib/dracut/modules.d/90freshroot/module-setup.sh

check() {
    require_binaries btrfs || return 1
    return 0
}

depends() {
    echo "btrfs"
}

# shellcheck disable=SC2154  # moddir and initdir are provided by dracut
install() {
    # systemd generator — creates the service + sysroot.mount drop-in
    inst_simple "$moddir/freshroot-generator" \
        /usr/lib/systemd/system-generators/freshroot-generator
    chmod 0755 "${initdir}/usr/lib/systemd/system-generators/freshroot-generator"

    # Setup script called by the generated service unit
    inst_simple "$moddir/freshroot-setup.sh" /bin/freshroot-setup.sh
    chmod 0755 "${initdir}/bin/freshroot-setup.sh"

    inst_multiple btrfs sed awk sort seq sleep
}

installkernel() {
    return 0
}
