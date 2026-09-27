#!/bin/bash
# build-image.sh — build the disposable QEMU fixture for the stage-1 /
# kernel-store boot model.
#
# Produces disk.img: GPT with a 512M ESP (stage-1 UKI at the removable-media
# fallback path) and a LUKS2 partition holding a btrfs filesystem laid out
# like a freshroot install (@, @home, @log, @tmp, @snapshots, @modules,
# @firmware), a minimal Ubuntu noble tree whose kernel was handed to the
# store the way the installer does it (modules on @modules, image under
# .freshroot/dist, UKI under .freshroot/uki, kernel packages purged, apt pin
# in place), the repo's 90freshroot module in the store's initramfs, the
# packaged 90freshroot-stage1 module built into the stage-1 UKI, and two
# kernel-free read-only snapshots. Test Secure Boot keys sign everything
# and are enrolled into an OVMF vars copy (vars-sb.fd) for the SB scenario.
#
# Needs: root, loop devices, device-mapper, ~12 GB free disk, network
# (mmdebstrap or debootstrap). Exits 77 ("skip") when the environment can't
# support it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$HERE/fixture.conf"
cd "$HERE"

die()  { echo "build-image: FATAL: $*" >&2; exit 1; }
skip() { echo "build-image: SKIP: $*" >&2; exit 77; }
info() { echo "build-image: $*"; }

[[ $(id -u) -eq 0 ]] || skip "must run as root (losetup/cryptsetup/mount/chroot)"
command -v losetup >/dev/null || skip "losetup not available"
losetup -f >/dev/null 2>&1 || skip "no loop devices available (container without loop support?)"
dmsetup version >/dev/null 2>&1 || modprobe dm_mod 2>/dev/null || true
dmsetup version >/dev/null 2>&1 \
    || skip "device-mapper unavailable (dm_mod not loadable — sandboxed container?)"
for c in sgdisk cryptsetup mkfs.btrfs mkfs.vfat openssl sbsign; do
    command -v "$c" >/dev/null || die "$c missing (apt install gdisk cryptsetup btrfs-progs dosfstools openssl sbsigntool)"
done
command -v mmdebstrap >/dev/null || command -v debootstrap >/dev/null \
    || die "neither mmdebstrap nor debootstrap installed"

LOOP=""
MNT=""
ESP_MNT=""
CRYPT_OPEN=0
cleanup() {
    set +e
    [[ -n "$ESP_MNT" ]] && mountpoint -q "$ESP_MNT" && umount "$ESP_MNT"
    if [[ -n "$MNT" ]]; then
        for sub in usr/lib/firmware usr/lib/modules dev/pts dev proc sys; do
            mountpoint -q "$MNT/@/$sub" 2>/dev/null && umount -R "$MNT/@/$sub"
        done
        mountpoint -q "$MNT" && umount -R "$MNT"
    fi
    [[ $CRYPT_OPEN -eq 1 ]] && cryptsetup close crypt-fixture 2>/dev/null
    [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null
    [[ -n "$MNT" ]] && rmdir "$MNT" 2>/dev/null
    [[ -n "$ESP_MNT" ]] && rmdir "$ESP_MNT" 2>/dev/null
}
trap cleanup EXIT

# ── Secure Boot test keys (PK, KEK, db) ─────────────────────────────
mkdir -p "$SB_DIR"
for k in PK KEK db; do
    if [[ ! -f "$SB_DIR/$k.key" ]]; then
        openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=freshroot test $k/" \
            -keyout "$SB_DIR/$k.key" -out "$SB_DIR/$k.crt" >/dev/null 2>&1
    fi
done
chmod 600 "$SB_DIR"/*.key
sign_pe() { # file — sign in place with the test db key
    sbattach --remove "$1" >/dev/null 2>&1 || true
    sbsign --key "$SB_DIR/db.key" --cert "$SB_DIR/db.crt" --output "$1.signed" "$1" >/dev/null 2>&1
    mv -f "$1.signed" "$1"
}

# ── Disk, partitions, LUKS, btrfs ────────────────────────────────────
info "creating ${DISK_IMG} (${DISK_SIZE})"
rm -f "$DISK_IMG"
truncate -s "$DISK_SIZE" "$DISK_IMG"
LOOP=$(losetup --show -fP "$DISK_IMG") || skip "losetup failed"
sgdisk --zap-all "$LOOP" >/dev/null
sgdisk -n1:1M:+512M -t1:ef00 -c1:ESP -n2:0:0 -t2:8309 -c2:luks "$LOOP" >/dev/null
partprobe "$LOOP" 2>/dev/null || true
[[ -b "${LOOP}p1" && -b "${LOOP}p2" ]] || skip "loop partitions did not appear"

mkfs.vfat -F32 -n ESP "${LOOP}p1" >/dev/null

info "formatting LUKS2 (weak PBKDF — test fixture only, keeps TCG unlock fast)"
printf '%s' "$PASSPHRASE" | cryptsetup luksFormat --batch-mode --type luks2 \
    --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file=- "${LOOP}p2"
printf '%s' "$PASSPHRASE" | cryptsetup open --key-file=- "${LOOP}p2" crypt-fixture
CRYPT_OPEN=1

mkfs.btrfs -f -L freshroot /dev/mapper/crypt-fixture >/dev/null
MNT=$(mktemp -d)
mount -o noatime /dev/mapper/crypt-fixture "$MNT"
for sv in @ @home @log @tmp @snapshots @modules @firmware; do
    btrfs subvolume create "$MNT/$sv" >/dev/null
done

LUKS_UUID=$(blkid -s UUID -o value "${LOOP}p2")
BTRFS_UUID=$(blkid -s UUID -o value /dev/mapper/crypt-fixture)
T="$MNT/@"
STORE="$MNT/@modules/.freshroot"

# ── Minimal Ubuntu tree ──────────────────────────────────────────────
PKGS="systemd-sysv,udev,dracut,btrfs-progs,cryptsetup,systemd-cryptsetup,kexec-tools,systemd-ukify,systemd-boot-efi,sbsigntool,zstd"
if command -v mmdebstrap >/dev/null; then
    info "bootstrapping ${SUITE} with mmdebstrap"
    mmdebstrap --mode=root --variant=apt --components=main,universe --include="$PKGS" "$SUITE" "$T" "$MIRROR"
else
    info "bootstrapping ${SUITE} with debootstrap (slower fallback)"
    debootstrap --variant=minbase --components=main,universe "$SUITE" "$T" "$MIRROR"
fi

in_chroot() {
    chroot "$T" /usr/bin/env DEBIAN_FRONTEND=noninteractive "$@"
}
for sub in proc sys dev dev/pts; do
    mount --bind "/$sub" "$T/$sub"
done
if ! command -v mmdebstrap >/dev/null; then
    in_chroot apt-get update
    in_chroot apt-get install -y --no-install-recommends "${PKGS//,/ }"
fi

# ── freshroot boot-time pieces (from this repo, not the whole deb) ───
info "installing the repo's dracut modules + ceremony marker"
mkdir -p "$T/usr/lib/dracut/modules.d" "$T/usr/lib/freshroot"
cp -a "$REPO_ROOT/data/usr/lib/dracut/modules.d/90freshroot" "$T/usr/lib/dracut/modules.d/"
cp -a "$REPO_ROOT/data/usr/lib/dracut/modules.d/90freshroot-stage1" "$T/usr/lib/dracut/modules.d/"
cp "$REPO_ROOT/data/usr/lib/freshroot/ceremony" "$T/usr/lib/freshroot/ceremony"

# ── System config (BEFORE the kernel installs: the postinst-built stage-2
#    initrd is non-hostonly with virtio + the freshroot module) ───────
cat > "$T/etc/dracut.conf.d/90-fixture.conf" <<'EOF'
hostonly="no"
compress="zstd"
add_drivers+=" virtio_blk virtio_pci virtio_scsi sd_mod "
EOF

# Root line keeps the "subvol=@," anchor freshroot-setup.sh's fstab sed
# expects. No /boot line — kernels live in the store on @modules.
cat > "$T/etc/fstab" <<EOF
UUID=${BTRFS_UUID}  /                  btrfs  subvol=@,noatime,compress=zstd:1   0  0
UUID=${BTRFS_UUID}  /usr/lib/modules   btrfs  subvol=@modules,noatime            0  0
UUID=${BTRFS_UUID}  /usr/lib/firmware  btrfs  subvol=@firmware,noatime           0  0
UUID=${BTRFS_UUID}  /home              btrfs  subvol=@home,noatime               0  0
UUID=${BTRFS_UUID}  /var/log           btrfs  subvol=@log,noatime                0  0
UUID=${BTRFS_UUID}  /tmp               btrfs  subvol=@tmp,noatime                0  0
EOF
cat > "$T/etc/crypttab" <<EOF
${DM_NAME} UUID=${LUKS_UUID} none luks,discard
EOF
echo freshroot-rig > "$T/etc/hostname"
echo "root:${ROOT_PASSWORD}" | in_chroot chpasswd

# ── Kernel install, then hand it to the store like the installer does ──
info "installing linux-image-virtual, then moving it into the kernel store"
in_chroot apt-get update
in_chroot apt-get install -y linux-image-virtual

KVER=$(find "$T/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V | tail -1)
[[ -n "$KVER" ]] || die "kernel install left no module tree"
[[ -f "$T/boot/vmlinuz-$KVER" ]] || die "missing in-tree vmlinuz-${KVER}"
mkdir -p "$STORE/dist" "$STORE/uki" "$STORE/stage1"
mv "$T/usr/lib/modules/$KVER" "$MNT/@modules/"
if [[ -n "$(ls -A "$T/usr/lib/firmware" 2>/dev/null)" ]]; then
    cp -a "$T/usr/lib/firmware/." "$MNT/@firmware/"
    rm -rf "${T:?}/usr/lib/firmware/"*
fi
install -m 0644 "$T/boot/vmlinuz-$KVER" "$STORE/dist/vmlinuz-$KVER"
sign_pe "$STORE/dist/vmlinuz-$KVER"
install -D -m 0644 "$REPO_ROOT/data/etc/apt/preferences.d/freshroot-kernel-pin" \
    "$T/etc/apt/preferences.d/freshroot-kernel-pin"
in_chroot apt-get purge -y 'linux-image-*' 'linux-modules-*' 'linux-headers-*' 'linux-generic*' 'linux-virtual*' \
    || die "kernel package purge failed"
[[ -z "$(ls -A "$T/usr/lib/modules" 2>/dev/null)" ]] || die "tree still carries modules after the purge"
[[ ! -e "$T/boot/vmlinuz-$KVER" ]] || die "tree still carries vmlinuz after the purge"

# Store UKI (built in-chroot with the subvolumes mounted where the guest
# will see them — the same recipe as freshroot-kernel/build_uki)
mount --bind "$MNT/@modules"  "$T/usr/lib/modules"
mount --bind "$MNT/@firmware" "$T/usr/lib/firmware"
in_chroot depmod "$KVER"
in_chroot dracut --force --no-hostonly --no-hostonly-cmdline --kver "$KVER" /tmp/initrd.img
in_chroot lsinitrd /tmp/initrd.img | grep -q freshroot-setup.sh \
    || die "stage-2 initrd does not contain the 90freshroot module"
in_chroot ukify build \
    --linux "/usr/lib/modules/.freshroot/dist/vmlinuz-$KVER" \
    --initrd /tmp/initrd.img --uname "$KVER" --cmdline "ro rd.freshroot=1" \
    --output "/usr/lib/modules/.freshroot/uki/uki-$KVER.efi"
sign_pe "$STORE/uki/uki-$KVER.efi"
cat > "$STORE/uki/uki-$KVER.meta" <<META
KVER=$KVER
SOURCE=rig
BUILT_FROM_SNAPSHOT=$SNAP_NEW
SIGNED=yes
STAGE1=yes
META
# Second store entry for the kernel picker: same UKI under a fake, older kver
cp "$STORE/uki/uki-$KVER.efi" "$STORE/uki/uki-$FAKE_KVER.efi"
mkdir -p "$MNT/@modules/$FAKE_KVER"
info "store UKI built for ${KVER} (+ picker copy ${FAKE_KVER})"

# Stage-1 UKI from the packaged module (serial console, short countdown)
STAGE1_CMDLINE="console=ttyS0,115200n8 root=freshroot rd.freshroot.timeout=5 rd.freshroot.modules=@modules loglevel=4"
in_chroot dracut --force --kver "$KVER" \
    --no-hostonly --no-hostonly-cmdline \
    --omit "systemd systemd-initrd dracut-systemd systemd-cryptsetup plymouth resume network network-legacy network-manager ifcfg url-lib nfs iscsi lvm mdraid fips" \
    --add "freshroot-stage1" \
    --add-drivers "virtio_blk virtio_pci virtio_scsi sd_mod nvme ahci dm_crypt btrfs vfat ext4" \
    --compress zstd \
    /tmp/stage1.img
in_chroot ukify build \
    --linux "/usr/lib/modules/.freshroot/dist/vmlinuz-$KVER" \
    --initrd /tmp/stage1.img --uname "$KVER" --cmdline "$STAGE1_CMDLINE" \
    --output /usr/lib/modules/.freshroot/stage1/freshroot-stage1.efi
sign_pe "$STORE/stage1/freshroot-stage1.efi"
rm -f "$T/tmp/initrd.img" "$T/tmp/stage1.img"
umount "$T/usr/lib/firmware" "$T/usr/lib/modules"
for sub in dev/pts dev proc sys; do
    umount -R "$T/$sub" 2>/dev/null || true
done

ESP_MNT=$(mktemp -d)
mount "${LOOP}p1" "$ESP_MNT"
install -D -m 0644 "$STORE/stage1/freshroot-stage1.efi" "$ESP_MNT/EFI/BOOT/BOOTX64.EFI"
install -D -m 0644 "$STORE/stage1/freshroot-stage1.efi" "$ESP_MNT/EFI/freshroot/freshroot-stage1.efi"
umount "$ESP_MNT"

# ── Snapshots (kernel-free) + default-lineage state ──────────────────
info "creating snapshots ${SNAP_OLD} and ${SNAP_NEW}"
btrfs subvolume snapshot -r "$T" "$MNT/@snapshots/$SNAP_OLD" >/dev/null
echo second > "$T/etc/fixture-marker"
btrfs subvolume snapshot -r "$T" "$MNT/@snapshots/$SNAP_NEW" >/dev/null
mkdir -p "$MNT/freshroot-state"
echo "$DEFAULT_LINEAGE" > "$MNT/freshroot-state/default-lineage"

# ── OVMF vars with the test keys enrolled (Secure Boot scenario) ─────
VARS_SRC=""
for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
    [[ -r "$v" ]] && { VARS_SRC="$v"; break; }
done
if command -v virt-fw-vars >/dev/null 2>&1 && [[ -n "$VARS_SRC" ]]; then
    GUID="a5c059a1-94e4-4aa7-87b5-ab155c2bf072"
    virt-fw-vars --input "$VARS_SRC" --output vars-sb.fd \
        --set-pk "$GUID" "$SB_DIR/PK.crt" \
        --add-kek "$GUID" "$SB_DIR/KEK.crt" \
        --add-db "$GUID" "$SB_DIR/db.crt" \
        --secure-boot >/dev/null
    info "vars-sb.fd: OVMF variables with the test PK/KEK/db enrolled, Secure Boot on"
else
    info "virt-fw-vars (python3-virt-firmware) or OVMF vars missing — SB scenario unavailable"
fi

info "fixture image ready: ${DISK_IMG} (kernel ${KVER})"
