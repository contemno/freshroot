# Freshroot — BTRFS snapshot-based immutable root

## Overview

This system makes an Ubuntu installation effectively immutable. Every boot starts fresh from a read-only btrfs snapshot, and runtime state is discarded on the next reboot. Persistent changes are only made through a controlled staging pipeline that runs system updates and user-defined provisioning scripts (ansible, plain shell, whatever you like — the package is tool-agnostic).

Ships as a `.deb` package (`freshroot`) that can be installed during autoinstall via the `packages:` section or from a PPA.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  BTRFS top-level (subvolid=5)                                       │
│                                                                     │
│  @/                    ← original root subvolume (reference only)   │
│  @snapshots/                                                        │
│    root.20260407T120000  ← read-only snapshot (GRUB boots this)     │
│    root.20260407T160000  ← newer read-only snapshot after update    │
│  @rootfs               ← writable clone created by dracut at boot   │
│  @staging              ← transient writable clone for updates       │
│                                                                     │
│  @home, @log, @apt-cache, @tmp, @spool, @crash, @containers,        │
│  @flatpak, @snap, @libvirt, @AccountsService, @gdm3, @bluetooth,    │
│  @cups, @fwupd, @netmanager, @machine-id, @swap                     │
│    ← persistent subvolumes, survive reboots and rollbacks           │
└─────────────────────────────────────────────────────────────────────┘
```

### Boot flow

1. **GRUB** (`06_freshroot`) selects the latest read-only snapshot and passes `rootflags=subvol=@snapshots/<timestamp>` plus `rd.freshroot` on the kernel cmdline.
2. **dracut** (the `90freshroot` module) uses a systemd generator to:
   - Create a setup service that runs before `sysroot.mount`.
   - Mount the btrfs top-level, delete the previous `@rootfs`, and create a new writable snapshot from the selected read-only snapshot.
   - Drop in an override for `sysroot.mount` so systemd mounts `@rootfs` as the real root.
3. **systemd** boots normally from the ephemeral writable root.

### Update flow

Runs manually or every 4 hours via the systemd timer:

1. Find the latest read-only snapshot.
2. Create a writable `@staging` clone.
3. Enter `@staging` with `systemd-nspawn`, bind-mounting:
   - `/boot` and `/boot/efi` so kernel/GRUB updates land on the real boot partition.
   - `@apt-cache` onto `/var/cache/apt` so downloaded `.deb` files persist across runs.
   - Any host paths listed in `BIND_MOUNTS` (for local dev or shipping secrets).
4. Before apt runs, scan all existing snapshots for in-use kernel versions and `apt-mark hold` them so `autoremove` can't delete kernels older snapshots depend on.
5. Inside the container: `apt full-upgrade`, cloud-init provisioning (`cloud-init init --local`, `init`, `modules --mode={config,final}`), then clone and run `./install.sh` from each repo listed in `REPOS`. Entries using the `local://<path>` scheme skip the clone and run `install.sh` directly (pair with `BIND_MOUNTS` to test uncommitted code).
6. **On success:** snapshot `@staging` as a new read-only snapshot, delete `@staging`, prune old snapshots past `MAX_SNAPSHOTS`, and `update-grub`.
7. **On failure:** retain `@staging` for investigation, log the error.
8. The user reboots at their convenience to activate the new snapshot.

`systemd-nspawn` is launched with `SYSTEMD_SECCOMP=0` exported in its parent env to skip the default syscall filter — apt and git are syscall-heavy enough that the filter overhead is measurable. Staging runs trusted code, so the trade-off is acceptable.

## Project layout

```
debian/                                                ← deb package scaffolding
  control, rules, postinst, prerm, changelog, ...

data/                                                  ← package install tree (maps to /)
  etc/
    freshroot-update.conf                              ← update script configuration
    default/grub.d/
      freshroot.cfg                                    ← GRUB defaults (timeout, cmdline)
    dracut.conf.d/
      freshroot.conf                                   ← enables dracut module
    grub.d/
      06_freshroot                                     ← GRUB hook for snapshot boot entries
    systemd/system/
      freshroot-update.service                         ← oneshot update service
      freshroot-update.timer                           ← 4-hour periodic trigger
      freshroot-provision.service                      ← first-boot cloud-init hook
      machine-id-persist.service                       ← restores machine-id after rollback
  usr/
    lib/dracut/modules.d/90freshroot/
      module-setup.sh                                  ← dracut module metadata
      freshroot-generator                              ← systemd generator for boot-time setup
      freshroot-setup.sh                               ← creates writable @rootfs from snapshot
    sbin/
      freshroot-update                                 ← update/staging script (nspawn)

installer/
  freshroot-setup                                      ← autoinstall bootstrap (shipped
                                                         separately, not inside the .deb)
```

## Building the package

```bash
# Install build dependencies (once)
sudo apt install debhelper devscripts shellcheck

# Lint all shell scripts
make lint

# Build the .deb
make build

# Result: target/freshroot_<version>_all.deb and target/freshroot-setup
```

Version is pulled from `debian/changelog`. Tagged releases (`v<semver>`) push to GitHub trigger [release.yml](.github/workflows/release.yml), which derives the version from the tag and regenerates the changelog stanza from the annotated tag's message.

## Autoinstall

The user-data files are minimal — the `freshroot` package is listed in `packages:` and a single late-command calls the bootstrap script:

```yaml
autoinstall:
  packages:
    - freshroot
    - ubuntu-desktop-minimal
    # ...
  late-commands:
    - /target/usr/sbin/freshroot-setup --bootstrap --repos "https://github.com/example/my-config.git"
```

The bootstrap script handles all 11 phases: btrfs subvolume restructuring, data migration, fstab/crypttab generation, machine-id persistence, top-level cleanup, first-boot tweaks, baseline snapshot, dracut regeneration, and GRUB configuration.

## Configuration

Edit `/etc/freshroot-update.conf` after install:

| Variable | Purpose |
|---|---|
| `REPOS` | Bash array of sources; each entry is either a git URL or `local://<path>`. Each source must have an executable `./install.sh` at its root |
| `BIND_MOUNTS` | Array of `HOST:CONTAINER[:ro]` entries bind-mounted into the nspawn staging container. Use for dev playbooks, secrets, or anything else the install scripts need |
| `MAX_SNAPSHOTS` | Number of read-only snapshots to retain (oldest pruned first; `0` = unlimited) |
| `BOOT_PARTITION` / `EFI_PARTITION` | Paths bind-mounted into the nspawn container so kernel/GRUB updates land on the real boot partition |
| `EDITION` | Free-form label shown in GRUB entry titles (e.g. `workstation`, `server`) |
| `LOG_DIR` | Where per-run logs are written (default `/var/log/freshroot-update`) |

## Usage

```bash
# Run an update manually
sudo freshroot-update

# Interactive shell in staging (exit 0 to snapshot, non-zero to abort)
sudo freshroot-update --shell

# Interactive shell with GUI passthrough (Wayland/X11, GPU, audio)
sudo freshroot-update --gui

# First-boot cloud-init provisioning only (used by freshroot-provision.service)
sudo freshroot-update --provision

# Check timer status
systemctl status freshroot-update.timer

# View logs
ls /var/log/freshroot-update/
journalctl -u freshroot-update.service
```

## Migrating from immutable-ubuntu

See [migrate.sh](migrate.sh) for the full upgrade path. In short: disable the old `immutable-update.timer`, `apt purge immutable-ubuntu`, install the new `freshroot` deb, port your config from `/etc/immutable-update.conf` to `/etc/freshroot-update.conf`, regenerate dracut + GRUB, and reboot into a Freshroot entry.

## Important notes

- **Persistent data** (home directories, logs, apt cache, etc.) lives on separate btrfs subvolumes mounted independently via `/etc/fstab`. The update script and dracut module only touch `@rootfs`, `@staging`, and the snapshot directory.
- **Post-update scripts must be idempotent.** Each repo's `install.sh` runs on every update cycle against the latest snapshot, not against a running system.
- **`rd.freshroot` kernel parameter** is the gate. Remove it from the GRUB config to disable immutable behavior and boot normally (the `@` subvolume serves as the tainted/recovery root).
- **On upgrades** (`apt upgrade freshroot`), the deb's postinst regenerates dracut and updates GRUB automatically.
- **Dracut replaces initramfs-tools.** The package declares `Conflicts: initramfs-tools` so dpkg handles the swap.
