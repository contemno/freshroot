# dracut-luks

Switch a running Ubuntu system from initramfs-tools to **dracut**, and configure
it to unlock a **LUKS-encrypted root** at boot.

One script, one job. It works on any root filesystem (ext4, btrfs, xfs) and with
or without LVM between the LUKS container and the root device.

```bash
sudo ./dracut-luks-setup --dry-run   # show exactly what would change
sudo ./dracut-luks-setup             # do it
```

## What it does

1. **Discovers the LUKS container** by walking the block-device ancestry of `/`
   upward to the first `crypto_LUKS` parent — so it works for `LUKS → btrfs` and
   for Ubuntu's own installer default, `LUKS → LVM → ext4`. It reads the LUKS
   UUID, the name of the `crypt` mapping, and the LVM volume group if there is one.
2. **Appends an `/etc/crypttab` entry** if one does not already exist for that
   container: `<name>  UUID=<uuid>  none  luks,discard`. An existing entry is left
   untouched — it may carry a keyfile or options that must not be clobbered.
3. **Writes `/etc/dracut.conf.d/luks.conf`** enabling the `crypt`, `dm` and
   `rootfs-block` modules, with `hostonly_cmdline="no"` so the kernel command line
   stays authoritative rather than being baked into the initramfs.
4. **Writes `/etc/default/grub.d/dracut-luks.cfg`**, appending to
   `GRUB_CMDLINE_LINUX`:

   ```
   rd.luks.uuid=<uuid> rd.luks.name=<uuid>=<name> [rd.lvm.vg=<vg>]
   ```

   Because this layers onto `/etc/default/grub`, the stock `10_linux` entries pick
   the parameters up. No custom GRUB entry generator is needed, and the normal
   Ubuntu menu entries keep working.
5. **Installs `dracut` and `cryptsetup`** if missing (installing `dracut` removes
   `initramfs-tools`; dpkg handles the swap). Skip with `--no-install`.
6. **Preserves each `/boot/initrd.img-<kver>`** as `.pre-dracut` before dracut
   overwrites it.
7. **Runs `dracut --regenerate-all --force` and `update-grub`**, then verifies that
   the new initrd contains `cryptsetup` and that `grub.cfg` carries the
   `rd.luks.uuid=` parameter. It exits non-zero if either check fails.

Every step is idempotent — running it twice changes nothing the second time.

## Options

| Flag | Effect |
|---|---|
| `--dry-run` | Print the discovery result and a diff of every file that would change. Touches nothing. |
| `--yes`, `-y` | Skip the interactive confirmation (required when stdin is not a terminal). |
| `--no-install` | Do not run `apt-get`; fail if `dracut` is not already present. |
| `--name NAME` | Override the derived crypt mapping name. |
| `--uuid UUID` | Override the derived LUKS UUID. |
| `--help`, `-h` | Usage. |

## Requirements

- A running Ubuntu 24.04+ system (root on LUKS, `/boot` on a **plaintext**
  partition), run as root.
- `lsblk`, `findmnt`, `cryptsetup`, `update-grub`.

## Recovery

The failure mode of this tool is a machine that will not boot, so read this first.

- **The old initramfs-tools images are kept** as `/boot/initrd.img-<kver>.pre-dracut`.
  From the GRUB menu press `e` on an entry and change the `initrd` line to the
  `.pre-dracut` file to boot the pre-change initramfs.
- **`/etc/crypttab` and any drop-in it replaced** are backed up next to the
  original as `<file>.dracut-luks-<timestamp>.bak`.
- **To reverse the change entirely**, from a live USB with the root unlocked and
  chrooted: `apt install --reinstall initramfs-tools`, then
  `rm /etc/dracut.conf.d/luks.conf /etc/default/grub.d/dracut-luks.cfg`, then
  `update-initramfs -u -k all && update-grub`.

Run `--dry-run` first, and if the verification step fails, do not reboot until
you understand why.

## Non-goals

Deliberately out of scope — none of it is needed to unlock a root volume, and
adding it would mean shipping code that has never booted a machine:

- Creating LUKS containers, enrolling keyfiles, TPM/`systemd-cryptenroll`, clevis.
  The container is assumed to exist; unlocking is by interactive passphrase at the
  dracut prompt (the crypttab keyfile column is `none`).
- Encrypted `/boot` / `GRUB_ENABLE_CRYPTODISK` / `cryptomount`. GRUB reads a
  plaintext `/boot` and never touches the container.
- fstab, partitioning, subvolumes, snapshots.
- Hibernation (`resume=`).

## Testing

`tests/discovery.sh` runs the tool against recorded
`lsblk -nspo NAME,TYPE,FSTYPE,UUID` output via the `--lsblk-fixture` hook, so the
layouts that matter are checked without a real encrypted disk — or root:

```bash
make lint    # shellcheck
make test    # discovery against tests/fixtures/*.lsblk
```

Fixture mode covers discovery only. The boot path itself can only be proven by
running the tool on an encrypted VM and rebooting.

## Provenance

Extracted from [freshroot](../README.md), which boots an immutable btrfs system
from read-only snapshots on a LUKS volume. The parts that mattered were the
runtime unlock-parameter derivation in `data/etc/grub.d/06_freshroot` and the
crypttab generation in `installer/freshroot-setup`; everything about snapshots,
subvolumes and lineages was left behind.

This is an extraction **by copy**. freshroot keeps its own implementation and the
two will diverge — a fix here is not automatically a fix there.
