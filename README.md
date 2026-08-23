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
│    root.ubuntu-24.04.20260407T120000  ← lineage "ubuntu-24.04"      │
│    root.ubuntu-24.04.20260407T160000  ← newer snapshot, same lineage│
│    root.ubuntu-26.04.20260501T090000  ← lineage "ubuntu-26.04"      │
│                                          (freshroot-install)        │
│    root.20260101T000000  ← legacy name; lineage resolved from the   │
│                             snapshot's own os-release               │
│  @rootfs               ← writable clone created by dracut at boot   │
│  @staging              ← transient writable clone for updates       │
│                                                                     │
│  @home, @log, @apt-cache, @tmp, @spool, @crash, @containers,        │
│  @flatpak, @snap, @libvirt, @AccountsService, @gdm3, @bluetooth,    │
│  @cups, @fwupd, @netmanager, @machine-id, @swap                     │
│    ← persistent subvolumes, survive reboots and rollbacks           │
└─────────────────────────────────────────────────────────────────────┘
```

### Lineages

A **lineage** is an install line of snapshots — normally one OS release,
labeled `<os-release ID>-<VERSION_ID>` (e.g. `ubuntu-24.04`). New snapshots
are named `root.<lineage>.<timestamp>`; the timestamp is always the last
dot-field. Legacy `root.<timestamp>` snapshots keep working — their lineage
is resolved lazily from the `os-release` inside them.

- **Retention is per lineage**: each lineage keeps `LINEAGE_QUOTAS` (falling
  back to `MAX_SNAPSHOTS`) snapshots, so updating one release line can never
  evict another's snapshots.
- **The default boot lineage is sticky**: it is recorded in
  `/boot/freshroot/default-lineage` and changed only by
  `freshroot-install --switch <lineage>` — installing 26.04 next to 24.04
  never silently changes what boots.
- `freshroot-update` operates on the *booted* lineage by default
  (`--lineage`/`--from` override it), and commits under the same label; if
  you perform a release upgrade inside `--shell`, the result automatically
  lands in the new release's lineage.
- Lineages are labels: `freshroot-install --lineage myserver` lets you keep
  several independent lines of the same OS release.

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
   - The btrfs top-level (subvolid=5) at `/run/freshroot-toplevel` so `install.sh` can manage top-level subvolumes (`btrfs subvolume create /run/freshroot-toplevel/@whatever`). This exposes all subvolumes rw to the container — only list trusted entries in `REPOS`.
   - Any host paths listed in `BIND_MOUNTS` (for local dev or shipping secrets).
4. Before apt runs, re-link any kernels the source snapshot needs back into the flat `/boot` names from its `/boot/freshroot/<snapshot>/` archive, and release kernel holds left by the retired hold-based protection scheme. `autoremove` may delete flat kernel names freely — every snapshot's archive keeps hardlinks to its own kernel pair, so no other snapshot can be stranded.
5. Inside the container: `apt full-upgrade`, cloud-init provisioning (`cloud-init init --local`, `init`, `modules --mode={config,final}`), then clone and run `./install.sh` from each repo listed in `REPOS`. Entries using the `local://<path>` scheme skip the clone and run `install.sh` directly (pair with `BIND_MOUNTS` to test uncommitted code).
6. **On success:** snapshot `@staging` as a new read-only snapshot in the same lineage, freeze its kernel pair(s) as hardlinks under `/boot/freshroot/<snapshot>/` (GRUB entries point there; `/boot` is ext4, so identical content costs nothing), delete `@staging`, prune each lineage past its quota (removing pruned snapshots' archives with them), and `update-grub`.
7. **On failure:** retain `@staging` for investigation, log the error.
8. The user reboots at their convenience to activate the new snapshot.

`update-grub` is diverted to `/bin/true` *inside* the staging container (kernel postinsts would otherwise write the host's `grub.cfg` from a container that cannot see `@snapshots`); the host runs the authoritative `update-grub` after commit.

### Installing another OS release (new lineage)

```bash
# Stage an Ubuntu release upgrade into a new lineage (24.04 stays intact)
sudo freshroot-install --release 26.04     # or: --release resolute

# Try it from the GRUB menu; when happy, make it the default boot lineage
sudo freshroot-install --switch ubuntu-26.04

# Didn't like it? Remove the whole lineage (its /boot kernel archives go
# with it; unreferenced flat kernels are autoremoved on the next update run)
sudo freshroot-install --remove ubuntu-26.04
```

`--release` clones the source snapshot to `@staging`, rewrites the **official Ubuntu** APT sources to the target codename (versions are resolved via `distro-info-data`), **disables third-party sources** for the run (they publish for new releases on their own schedule; the tool lists what it disabled so you can re-enable each one later), then runs `apt full-upgrade` in nspawn and commits the result as `root.ubuntu-26.04.<timestamp>`. The upgrade hop is validated (next release, or next LTS from an LTS; `--force` overrides). `dpkg --audit` must come back clean before the snapshot is committed. Because everything happens in the disposable `@staging` clone, a failed upgrade costs nothing — the staging tree is renamed to `@staging.failed-<timestamp>` for investigation and your running system is untouched.

For non-Ubuntu distros, `freshroot-install --import <dir|tarball> --lineage <name>` imports a prepared rootfs (debootstrap, cloud image, …) as a new lineage — see *Porting to other distros* below.

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
    lib/freshroot/
      ceremony                                         ← boot-ceremony capability marker (version)
    sbin/
      freshroot-update                                 ← update/staging script (nspawn)
      freshroot-build                                  ← two-tier "from scratch" snapshot builds
      freshroot-install                                ← lineage management (new releases, switch, remove)

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
| `MAX_SNAPSHOTS` | Per-lineage fallback quota: snapshots retained in each lineage that has no `LINEAGE_QUOTAS` entry (oldest pruned first; `0` = unlimited). With several lineages the total retained is the **sum** of the per-lineage quotas |
| `LINEAGE_QUOTAS` | Array of `"lineage=N"` per-lineage retention overrides, e.g. `"ubuntu-26.04=3"` |
| `BOOT_PARTITION` / `EFI_PARTITION` | Paths bind-mounted into the nspawn container so kernel/GRUB updates land on the real boot partition |
| `EDITION` | Free-form label shown in GRUB entry titles (e.g. `workstation`, `server`) |
| `LOG_DIR` | Where per-run logs are written (default `/var/log/freshroot-update`) |

Upgrading the package does **not** rewrite an existing (locally modified) `/etc/freshroot-update.conf` — the new keys are optional and every tool defaults them sanely when absent. The default boot lineage lives outside the conffile, in `/boot/freshroot/default-lineage`.

## Usage

```bash
# Run an update manually (operates on the booted lineage)
sudo freshroot-update

# Update a specific lineage / stage from a specific snapshot or lineage
sudo freshroot-update --lineage ubuntu-26.04
sudo freshroot-update --from root.ubuntu-24.04.20260407T120000 --shell

# Interactive shell in staging (exit 0 to snapshot, non-zero to abort;
# update-grub is a no-op inside staging — the host runs it after commit)
sudo freshroot-update --shell

# Interactive shell with GUI passthrough (Wayland/X11, GPU, audio)
sudo freshroot-update --gui

# First-boot cloud-init provisioning only (used by freshroot-provision.service)
sudo freshroot-update --provision

# Install another Ubuntu release as a new lineage / manage lineages
sudo freshroot-install --release 26.04
sudo freshroot-install --switch ubuntu-26.04
sudo freshroot-install --remove ubuntu-26.04
sudo freshroot-install --import /srv/debian-rootfs.tar.xz --lineage debian-13

# Check timer status
systemctl status freshroot-update.timer

# View logs
ls /var/log/freshroot-update/
journalctl -u freshroot-update.service
```

## Porting to other distros

The btrfs layout, GRUB hook, quotas and staging pipeline are distro-neutral;
what is Ubuntu-specific is the **boot ceremony** implementation (a dracut
module) and apt/nspawn staging. To boot a non-Ubuntu lineage (imported with
`freshroot-install --import`), the distro's initramfs must implement the
ceremony, version 1:

1. Gate on `rd.freshroot` on the kernel command line (emitted as
   `rd.freshroot=1`; treat an unknown version as an error).
2. Mount the btrfs top-level (`subvolid=5`) of the root device.
3. Delete the stale `@rootfs` subvolume (including nested subvolumes).
4. Create a writable snapshot of the subvolume named by
   `rootflags=subvol=@snapshots/<name>` as `@rootfs`.
5. Rewrite `subvol=@,` to `subvol=@rootfs,` in the clone's `/etc/fstab`.
6. Mount `@rootfs` as the real root (the shipped dracut module does this via
   a `sysroot.mount` drop-in) and continue boot.

The reference implementation is the `90freshroot` dracut module
(`data/usr/lib/dracut/modules.d/90freshroot/`); Fedora and other
dracut-based distros can reuse it nearly as-is. initramfs-tools/mkinitcpio
ports are future work — until one exists in the imported tree, its GRUB
entries boot **without** `rd.freshroot` and are labeled "NO CEREMONY"
(read-only root, no discard-on-reboot).

What the GRUB hook expects from a foreign lineage:

- **Capability marker**: `/usr/lib/freshroot/ceremony` inside the tree
  (content: the ceremony version, currently `1`). Trees containing the
  90freshroot dracut module are recognized without the marker.
- **Kernels**: `/boot/vmlinuz-<kver>` plus `/boot/initrd.img-<kver>` *or*
  `/boot/initramfs-<kver>.img`, with matching `/usr/lib/modules/<kver>` in
  the tree. `--import` also accepts the pair inside the imported tree's own
  `/boot` and copies it into the snapshot's `/boot/freshroot/<name>/`
  archive at commit. Unversioned kernel names (Arch's `vmlinuz-linux`) are
  not matched.
- **Unlock parameters**: entries get the host's dracut-style
  `rd.luks.uuid=<uuid> rd.luks.name=<uuid>=<name>` appended. If the
  distro's initramfs unlocks differently, ship a single-line
  `/etc/freshroot/cmdline` in the tree — it **replaces** the `rd.luks.*`
  parameters for that tree's entries.

`--import` bakes the host's persistent machine-id into the tree (the
snapshot is re-cloned every boot, so an unbaked machine-id would be minted
fresh each boot) and generates a minimal fstab (`/`, `/boot`, `/boot/efi`,
`/home`, `/var/log`, swap); the host's remaining Ubuntu-shaped state-dir
mounts (`@gdm3`, `@snap`, …) are written commented-out so you map them to
the foreign distro's paths deliberately. Package staging (`freshroot-update`
runs `apt` inside nspawn) is Ubuntu/Debian-shaped; for other package
managers use `freshroot-update --lineage <name> --shell` and drive the
distro's tooling by hand.

## Migrating from immutable-ubuntu

See [migrate.sh](migrate.sh) for the full upgrade path. In short: disable the old `immutable-update.timer`, `apt purge immutable-ubuntu`, install the new `freshroot` deb, port your config from `/etc/immutable-update.conf` to `/etc/freshroot-update.conf`, regenerate dracut + GRUB, and reboot into a Freshroot entry.

## Important notes

- **Persistent data** (home directories, logs, apt cache, etc.) lives on separate btrfs subvolumes mounted independently via `/etc/fstab`. The update script and dracut module only touch `@rootfs`, `@staging`, and the snapshot directory.
- **Post-update scripts must be idempotent.** Each repo's `install.sh` runs on every update cycle against the latest snapshot, not against a running system.
- **`rd.freshroot` kernel parameter** is the gate. Remove it from the GRUB config to disable immutable behavior and boot normally (the `@` subvolume serves as the tainted/recovery root).
- **On upgrades** (`apt upgrade freshroot`), the deb's postinst regenerates dracut and updates GRUB automatically.
- **Dracut replaces initramfs-tools.** The package declares `Conflicts: initramfs-tools` so dpkg handles the swap.
- **Migration window:** after the new freshroot lands in a snapshot but before you reboot into it, the *running* (old) tools keep committing legacy-named snapshots — harmless, they resolve into the right lineage by os-release. The `@` subvolume keeps the install-time tooling forever, so tainted-boot updates run pre-lineage code; refresh `@` (tainted boot + `apt install ./freshroot_*.deb`) before relying on updates from a tainted boot.
- **`@base` and release switches:** `freshroot-build`'s pinned `@base` stays on its original release. After switching lineages, reseed it (`btrfs subvolume delete <toplevel>/@base`, then `freshroot-build --init-base --from @snapshots/<new-lineage snapshot>`); the build tool warns when `@base`'s lineage differs from the booted one.
- **Per-snapshot kernel archives:** each committed snapshot's `vmlinuz`/`initrd` pair is frozen as hardlinks under `/boot/freshroot/<snapshot>/`, and its GRUB entries boot from there — so `apt autoremove` (or anything else) unlinking the flat `/boot` names cannot strand another snapshot, and each snapshot keeps the exact initrd bytes it was committed with even when two lineages reuse one `<kver>` (Ubuntu HWE). Snapshots that predate the archive are backfilled on the next update/build run and boot from the flat names until then. The archives are managed by the tools; don't edit them by hand.
- **Removing a lineage** (`freshroot-install --remove`) deletes its snapshots and their kernel archives; the one leftover to clean up is its `LINEAGE_QUOTAS` entry in the conffile (printed as a reminder). Flat `/boot` kernels no remaining tree references are collected by `apt autoremove` on the next update run.
