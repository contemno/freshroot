#!/bin/bash
# build-image.sh — build the disposable QEMU fixture for the kexec-menu PoC.
#
# Produces disk.img: GPT with a 512M ESP (stage-1 UKI at the removable-media
# fallback path) and a LUKS2 partition holding a btrfs filesystem laid out
# like a freshroot install (@, @home, @log, @tmp, @snapshots), a minimal
# Ubuntu noble tree with the kernel installed IN-TREE (/boot is a plain
# directory — the point of the PoC), the repo's 90freshroot dracut module in
# the tree's own initramfs, and two read-only snapshots in one lineage.
#
# Needs: root, loop devices, ~12 GB free disk, network (mmdebstrap or
# debootstrap). Exits 77 ("skip") when the environment can't support it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
POC_DIR="$(dirname "$HERE")"
REPO_ROOT="$(cd "$POC_DIR/../.." && pwd)"
# shellcheck source=/dev/null
source "$HERE/fixture.conf"
cd "$POC_DIR"

die()  { echo "build-image: FATAL: $*" >&2; exit 1; }
skip() { echo "build-image: SKIP: $*" >&2; exit 77; }
info() { echo "build-image: $*"; }

[[ $(id -u) -eq 0 ]] || skip "must run as root (losetup/cryptsetup/mount/chroot)"
command -v losetup >/dev/null || skip "losetup not available"
losetup -f >/dev/null 2>&1 || skip "no loop devices available (container without loop support?)"
dmsetup version >/dev/null 2>&1 || modprobe dm_mod 2>/dev/null || true
dmsetup version >/dev/null 2>&1 \
    || skip "device-mapper unavailable (dm_mod not loadable — sandboxed container?)"
command -v sgdisk >/dev/null || die "sgdisk missing (apt install gdisk)"
command -v cryptsetup >/dev/null || die "cryptsetup missing"
command -v mkfs.btrfs >/dev/null || die "mkfs.btrfs missing (apt install btrfs-progs)"
command -v mkfs.vfat >/dev/null || die "mkfs.vfat missing (apt install dosfstools)"
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
        for sub in dev/pts dev proc sys; do
            mountpoint -q "$MNT/@/$sub" 2>/dev/null && umount -R "$MNT/@/$sub"
        done
        mountpoint -q "$MNT" && umount -R "$MNT"
    fi
    [[ $CRYPT_OPEN -eq 1 ]] && cryptsetup close crypt-fixture 2>/dev/null
    [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null
    rm -rf "${MNT:-}" "${ESP_MNT:-}"
}
trap cleanup EXIT

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
btrfs subvolume create "$MNT/@" >/dev/null
for sv in @home @log @tmp @snapshots; do
    btrfs subvolume create "$MNT/$sv" >/dev/null
done

LUKS_UUID=$(blkid -s UUID -o value "${LOOP}p2")
BTRFS_UUID=$(blkid -s UUID -o value /dev/mapper/crypt-fixture)
T="$MNT/@"

# ── Minimal Ubuntu tree ──────────────────────────────────────────────
PKGS="systemd-sysv,udev,dracut,btrfs-progs,cryptsetup,systemd-cryptsetup,kexec-tools,systemd-ukify,systemd-boot-efi,zstd"
if command -v mmdebstrap >/dev/null; then
    info "bootstrapping ${SUITE} with mmdebstrap"
    mmdebstrap --mode=root --variant=apt --include="$PKGS" "$SUITE" "$T" "$MIRROR"
else
    info "bootstrapping ${SUITE} with debootstrap (slower fallback)"
    debootstrap --variant=minbase "$SUITE" "$T" "$MIRROR"
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
info "installing the repo's 90freshroot dracut module + ceremony marker"
mkdir -p "$T/usr/lib/dracut/modules.d"
cp -a "$REPO_ROOT/data/usr/lib/dracut/modules.d/90freshroot" "$T/usr/lib/dracut/modules.d/"
mkdir -p "$T/usr/lib/freshroot"
cp "$REPO_ROOT/data/usr/lib/freshroot/ceremony" "$T/usr/lib/freshroot/ceremony"

# ── System config (BEFORE the kernel installs: the postinst-built stage-2
#    initrd must be non-hostonly with virtio + the freshroot module) ──
cat > "$T/etc/dracut.conf.d/90-fixture.conf" <<'EOF'
hostonly="no"
compress="zstd"
add_drivers+=" virtio_blk virtio_pci virtio_scsi sd_mod "
EOF

# Root line keeps the "subvol=@," anchor freshroot-setup.sh's fstab sed
# expects. Deliberately NO /boot line — kernels live in-tree.
cat > "$T/etc/fstab" <<EOF
UUID=${BTRFS_UUID}  /         btrfs  subvol=@,noatime,compress=zstd:1  0  0
UUID=${BTRFS_UUID}  /home     btrfs  subvol=@home,noatime              0  0
UUID=${BTRFS_UUID}  /var/log  btrfs  subvol=@log,noatime               0  0
UUID=${BTRFS_UUID}  /tmp      btrfs  subvol=@tmp,noatime               0  0
EOF
cat > "$T/etc/crypttab" <<EOF
${DM_NAME} UUID=${LUKS_UUID} none luks,discard
EOF
echo freshroot-poc > "$T/etc/hostname"
echo "root:${ROOT_PASSWORD}" | in_chroot chpasswd

# ── Kernel install, /boot unmounted → lands IN-TREE ──────────────────
# linux-image ships /boot/vmlinuz-<kver> as dpkg payload; the dracut
# package's /etc/kernel/postinst.d/dracut hook writes the initrd into the
# tree. Neither checks whether /boot is a mountpoint. dracut is already
# installed (Provides: linux-initramfs-tool), and no GRUB exists here so no
# zz-update-grub hook fires.
info "installing linux-image-virtual with /boot as a plain directory"
in_chroot apt-get update
in_chroot apt-get install -y linux-image-virtual

KVER=$(find "$T/boot" -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' 2>/dev/null \
       | sed 's/^vmlinuz-//' | sort -V | tail -1)
[[ -n "$KVER" ]] || die "kernel install left no vmlinuz in-tree"
[[ -f "$T/boot/vmlinuz-$KVER" ]] || die "missing in-tree vmlinuz-${KVER}"
[[ -f "$T/boot/initrd.img-$KVER" ]] || die "missing in-tree initrd.img-${KVER} (dracut postinst hook did not run?)"
in_chroot lsinitrd "/boot/initrd.img-$KVER" | grep -q freshroot-setup.sh \
    || die "stage-2 initrd does not contain the 90freshroot module"
info "in-tree kernel: ${KVER}"

# ── Stage-1 UKI ──────────────────────────────────────────────────────
KEYFILE_TMP=""
BUILD_ARGS=(--tree "$T" --kver "$KVER" --out-uki "$POC_DIR/freshroot-menu.efi")
if [[ "${FRESHROOT_TEST_KEYFILE:-0}" = "1" ]]; then
    # Automated unlock for expect-less smoke tests; e2e.py types the
    # passphrase instead, exercising the real prompt path.
    KEYFILE_TMP=$(mktemp)
    printf '%s' "$PASSPHRASE" > "$KEYFILE_TMP"
    BUILD_ARGS+=(--test-keyfile "$KEYFILE_TMP")
fi
"$POC_DIR/build-stage1.sh" "${BUILD_ARGS[@]}"
[[ -n "$KEYFILE_TMP" ]] && rm -f "$KEYFILE_TMP"

for sub in dev/pts dev proc sys; do
    umount -R "$T/$sub" 2>/dev/null || true
done

ESP_MNT=$(mktemp -d)
mount "${LOOP}p1" "$ESP_MNT"
install -D -m 0644 "$POC_DIR/freshroot-menu.efi" "$ESP_MNT/EFI/BOOT/BOOTX64.EFI"
umount "$ESP_MNT"

# ── Snapshots + default-lineage state ────────────────────────────────
info "creating snapshots ${SNAP_OLD} and ${SNAP_NEW}"
btrfs subvolume snapshot -r "$T" "$MNT/@snapshots/$SNAP_OLD" >/dev/null
echo second > "$T/etc/fixture-marker"
btrfs subvolume snapshot -r "$T" "$MNT/@snapshots/$SNAP_NEW" >/dev/null
mkdir -p "$MNT/freshroot-state"
echo "$DEFAULT_LINEAGE" > "$MNT/freshroot-state/default-lineage"

info "fixture image ready: ${DISK_IMG}"
