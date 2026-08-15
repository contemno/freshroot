# dracut-luks

A small Ubuntu package, installed alongside **dracut**, that makes an encrypted
root boot: it ensures the GRUB kernel command line is built with the right
`rd.luks.*` arguments and that every initramfs contains the LUKS unlock modules
— including FIDO2 and TPM2 token support when the corresponding libraries are
installed.

```bash
sudo apt install ./dracut-luks_*.deb
```

That's the whole workflow on a typical machine. The postinst regenerates the
initramfs and `grub.cfg`, then prints a checklist of what it verified.

## How it works

The package is almost entirely **declarative** — two conffile mechanisms do the
recurring work, so there is no generated configuration to go stale:

- **`/etc/default/grub.d/99-dracut-luks.cfg`** — files in `grub.d` are *sourced
  as shell* by `grub-mkconfig`, so this drop-in derives the LUKS container of
  `/` at every `update-grub` and appends the matching parameters to
  `GRUB_CMDLINE_LINUX`:

  ```
  rd.luks.uuid=<uuid> rd.luks.name=<uuid>=<name> [rd.lvm.vg=<vg>]
  ```

  Because the values are resolved at `update-grub` time rather than written
  anywhere, re-encrypting the disk, cloning it, or renaming the mapping is
  fixed by the next `update-grub` — nothing to edit. If you set `rd.luks.uuid=`
  yourself in `/etc/default/grub`, the drop-in defers to you. On a machine
  whose root is not encrypted it is a silent no-op.

- **`/etc/dracut.conf.d/10-luks.conf`** — pulls `crypt`, `dm` and
  `rootfs-block` into every initramfs. `hostonly_cmdline="no"` keeps the kernel
  command line authoritative instead of baking a copy into the image.

- **`/etc/dracut.conf.d/20-luks-tokens.conf`** — adds the dracut `fido2` /
  `tpm2-tss` modules and the matching libcryptsetup token plugins, each only
  when the relevant userspace library is installed, so it is safe unconditionally.

- **`/usr/lib/dracut-luks/discover.sh`** — the shared discovery library both
  the GRUB drop-in and the helper source. It walks the block-device ancestry of
  `/` (`lsblk -nspo`) to the first `crypto_LUKS` parent, so plain
  `LUKS → filesystem` and Ubuntu's installer default `LUKS → LVM → root LV`
  both work, and reads the container UUID, the crypt mapping name, and the LVM
  volume group if one is in the path.

Because the parameters land in `GRUB_CMDLINE_LINUX`, the stock Ubuntu
(`10_linux`) menu entries carry them — no custom GRUB entry generator, and the
normal entries keep working.

Note that installing dracut on Ubuntu **removes initramfs-tools** (they
conflict); that swap is the point of the package, but it is worth knowing
before you install.

## The helper: `dracut-luks-setup`

The conffiles handle the recurring work; the helper covers the one-time and
diagnostic parts:

```bash
dracut-luks-setup --check        # read-only: discovery + verification checklist
sudo dracut-luks-setup           # crypttab + preserve initrds + regenerate + verify
```

A mutating run:

1. Adds an `/etc/crypttab` entry (`<name> UUID=<uuid> none luks,discard`) if
   none exists for the container. An existing entry is never touched — it may
   carry a keyfile or token options that must not be clobbered.
2. Preserves each `/boot/initrd.img-<kver>` as `<file>.pre-dracut` before
   dracut overwrites it.
3. Runs `dracut --regenerate-all --force` and `update-grub`.
4. Verifies: `cryptsetup` present in the running kernel's initrd, and
   `rd.luks.uuid=` present in `/boot/grub/grub.cfg`. Exits non-zero if not.

| Flag | Effect |
|---|---|
| `--check` | Read-only discovery + verification; needs no root. |
| `--dry-run` | Show what a mutating run would do without doing it. |
| `--yes`, `-y` | Skip the confirmation prompt (required when stdin is not a tty). |
| `--no-regenerate` | Skip `dracut` and `update-grub` (e.g. inside an image build). |
| `--name NAME` / `--uuid UUID` | Override the discovered mapping name / container UUID. |

## Requirements

Ubuntu 24.04+ (or any Debian-family system with `grub2-common`'s
`/etc/default/grub.d` mechanism), root on LUKS, and `/boot` on a **plaintext**
partition — GRUB itself never opens the container.

## Recovery

The failure mode is a machine that will not boot, so:

- The initramfs-tools images survive as `/boot/initrd.img-<kver>.pre-dracut`.
  At the GRUB menu, press `e` on an entry and point the `initrd` line at the
  `.pre-dracut` file to boot the old initramfs.
- `/etc/crypttab` is backed up as `crypttab.dracut-luks-<timestamp>.bak` before
  the helper appends to it.
- Full reversal, from a live USB with the root unlocked and chrooted:
  `apt purge dracut-luks && apt install --reinstall initramfs-tools`, then
  `update-initramfs -u -k all && update-grub`.
- `apt purge`/`remove` of this package regenerates `grub.cfg` (now without
  `rd.luks.*`) and warns loudly: if `/` is on LUKS, put the parameters into
  `GRUB_CMDLINE_LINUX` yourself before rebooting.

## Non-goals

This package concerns itself only with *unlocking* the root volume:

- No creating LUKS containers, no key/keyfile enrollment, no
  `systemd-cryptenroll`/clevis (the token *plugins* are included; enrolling
  tokens is up to you — e.g. `systemd-cryptenroll --fido2-device=auto <dev>`).
- No encrypted `/boot`, `GRUB_ENABLE_CRYPTODISK`, or `cryptomount`.
- No fstab, partitioning, or filesystem management.
- No hibernation (`resume=`).

## Building and testing

```bash
make lint     # shellcheck (bash tools, sh sourced fragments)
make test     # discovery + GRUB drop-in behavior against recorded lsblk output
make build    # dpkg-buildpackage -> target/dracut-luks_<version>_all.deb
```

The tests exercise the discovery library and the GRUB drop-in (sourced exactly
as `grub-mkconfig` does: `/bin/sh` under `set -e`) against `tests/fixtures/*` —
`LUKS → btrfs`, `LUKS → LVM → ext4`, a hyphenated VG name, and an unencrypted
root — so regressions are caught without an encrypted disk. The boot path
itself can only be proven by installing the package on an encrypted VM and
rebooting.

## Provenance

Extracted from [freshroot](https://github.com/contemno/freshroot), which boots
an immutable btrfs system from read-only snapshots on a LUKS volume. The
`rd.luks.*` derivation began as the runtime discovery in its GRUB hook; the
snapshot, subvolume and lineage machinery stayed behind. The code has since
diverged — fixes do not flow between the two automatically.
