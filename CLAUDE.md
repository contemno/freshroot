# CLAUDE.md — Agent Guide for freshroot

## What this project is

A `.deb` package (`freshroot`) that makes an Ubuntu installation immutable via btrfs snapshots. Every boot starts fresh from a read-only snapshot; runtime changes are discarded on reboot. Persistent state (home, logs, network config, etc.) lives on dedicated btrfs subvolumes that survive rollbacks. Updates are staged in an nspawn container and committed as new read-only snapshots.

This is **not** a general-purpose tool. It targets a specific architecture: LUKS2-encrypted btrfs on Ubuntu 24.04+ (noble), with dracut replacing initramfs-tools, installed via Ubuntu's autoinstall system.

## Architecture — how the pieces connect

```
                    INSTALL TIME                          BOOT TIME                         UPDATE TIME
                    ────────────                          ─────────                         ───────────
 autoinstall        freshroot-setup                dracut generator                  freshroot-update
 user-data          --bootstrap                           (90freshroot)              (timer or manual)
     │                    │                                    │                                  │
     │  packages:         │  Phase 1-11:                       │  rd.freshroot on cmdline?        │
     │  - freshroot       │  restructure btrfs,                │  yes → create writable           │  1. find latest snapshot
     │                    │  create subvolumes,                │       @rootfs from snapshot      │  2. clone → @staging
     │                    │  migrate data,                     │  no  → normal boot               │  3. nspawn into @staging
     │  late-commands:    │  generate fstab/crypttab,          │                                  │  4. apt upgrade + REPOS
     │  - dpkg -i *.deb   │  first-boot tweaks,                │  sysroot.mount drop-in           │  5. snapshot -r → new snap
     │  - setup --boot    │  baseline snapshot,                │  redirects to @rootfs            │  6. delete @staging
     │                    │  dracut + GRUB                     │                                  │  7. prune old snapshots
     │                    │                                    │                                  │  8. update-grub
     ▼                    ▼                                    ▼                                  ▼
 ┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
 │  BTRFS top-level (subvolid=5)                                                                    │
 │                                                                                                  │
 │  @              original root (reference, not booted directly in clean mode)                     │
 │  @rootfs        ephemeral writable clone (created fresh each boot by dracut)                     │
 │  @staging       transient writable clone (exists only during updates)                            │
 │  @snapshots/    read-only snapshots, grouped into per-release "lineages"                         │
 │                 (root.<lineage>.YYYYMMDDTHHMMSS; legacy root.YYYYMMDDTHHMMSS                     │
 │                 resolves its lineage from the os-release inside the snapshot)                    │
 │  @home, @log, @apt-cache, @tmp, @spool, @crash, @containers, @flatpak,                           │
 │  @snap, @libvirt, @AccountsService, @gdm3, @bluetooth, @cups, @fwupd,                            │
 │  @netmanager, @machine-id, @swap                                                                 │
 │     └─ persistent subvolumes, mounted via fstab, survive reboots and rollbacks                   │
 └──────────────────────────────────────────────────────────────────────────────────────────────────┘
```

## Key design constraints

1. **dracut-systemd, not mount hooks.** Ubuntu 24.04 uses systemd inside the initramfs. Traditional dracut mount hooks don't work because `$root` isn't propagated between services and `sysroot.mount` overrides hook mounts. The solution is a systemd generator that creates a setup service (Before=sysroot.mount) and a sysroot.mount.d drop-in.

2. **`rd.freshroot` kernel parameter is the gate.** The dracut generator checks /proc/cmdline for this flag. Without it, boot proceeds normally. This is how immutable behavior is toggled.

3. **`set -euo pipefail` everywhere.** All scripts use strict mode. When modifying scripts, ensure every variable is initialized before use and unbound variable errors cannot occur. This is especially important in nspawn containers where bash profile scripts reference variables like `SUDO_USER`, `debian_chroot`, etc. The nspawn shell command uses `set +u; exec bash -l` to handle this.

4. **The bootstrap runs in the INSTALLER environment.** `freshroot-setup` runs from autoinstall late-commands, meaning it has access to `/target` and raw block devices but is NOT inside a chroot. It uses `curtin in-target --target="$T"` to run commands inside the target root. It self-relocates to /tmp because Phase 7 deletes non-subvolume entries from /target.

5. **nspawn needs `--resolv-conf=bind-stub`.** The `copy-host` mode copies a symlink that doesn't resolve inside the container. Always use `bind-stub`.

6. **No `/usr/local/` in deb packages.** Debian policy reserves `/usr/local/` for the local admin. Scripts go in `/usr/sbin/`.

7. **Config is tool-agnostic.** The `REPOS` array in `freshroot-update.conf` holds git URLs. Each repo must have an executable `./install.sh`. The user chooses their own config management (ansible, puppet, plain scripts, etc.). The package does NOT depend on ansible.

8. **Subvolume lists must stay in sync.** The list of persistent subvolumes appears in multiple places: Phase 2 (create), Phase 3 (migrate), Phase 4 (fstab), and Phase 7 (cleanup whitelist). Adding or removing a subvolume requires updating ALL of these.

9. **The lineage helper corpus is copied into FOUR files.** `snap_ts`, `snap_label`, `lineage_of_root`, `snapshot_lineage`, `lineage_quota`, `list_ro_snapshots`/snapshot indexing, `booted_snapshot`, `current_lineage`, `prune_snapshots` and the update-grub suppress/restore helpers exist in `freshroot-update`, `freshroot-build`, `freshroot-install`, and (sh-dialect, ||-guarded, NO `set -u`/`pipefail`) in `06_freshroot`. The tools deliberately share no library — fix a bug in all four. All snapshot ordering sorts on the parsed TIMESTAMP field, never on raw names (lineage-prefixed names sort after legacy names lexically).

10. **New config keys never reach existing installs automatically.** `freshroot-setup` rewrites the conffile at install time, so dpkg keeps the old version on upgrades. Every tool must initialize new keys before sourcing the conf (`LINEAGE_QUOTAS=()` etc.) and guard every lookup; `06_freshroot` must do the same without `set -u`. The default boot lineage therefore lives OUTSIDE the conffile, in `/boot/freshroot/default-lineage` (written by `freshroot-install --switch`, seeded by the installer / first lineage-aware run).

## File roles

| File | Runs when | Runs where | Purpose |
|---|---|---|---|
| `installer/freshroot-setup` | Install time (late-commands) | Installer environment | 11-phase bootstrap: subvolumes, fstab, crypttab, migration, tweaks, snapshot, dracut, GRUB |
| `data/usr/sbin/freshroot-update` | Runtime (timer or manual) | Running system | Stage updates in nspawn on the booted lineage, snapshot result, per-lineage pruning, update GRUB |
| `data/usr/sbin/freshroot-build` | Runtime (timer or manual) | Running system | Two-tier "from scratch" builds: vanilla-upgrade pinned `@base`, then component layer from a fresh clone |
| `data/usr/sbin/freshroot-install` | Runtime (manual) | Running system | Lineage management: `--release` (stage an Ubuntu release upgrade as a NEW lineage), `--import` (foreign rootfs), `--switch` (sticky default boot lineage), `--remove` |
| `data/usr/lib/freshroot/ceremony` | Read by `06_freshroot` | Inside each snapshot tree | Boot-ceremony capability marker (contains the ceremony version, `1`); trees without it (or the dracut module) get GRUB entries without `rd.freshroot` |
| `data/etc/freshroot-update.conf` | Sourced by freshroot-update | Running system | Config: REPOS, subvol names, retention, boot partitions, log dir |
| `data/etc/grub.d/06_freshroot` | `update-grub` | Running system | Generate GRUB entries: clean (latest snapshot), tainted (@), snapshot history submenu |
| `data/etc/default/grub.d/freshroot.cfg` | `update-grub` | Running system | GRUB defaults: timeout, default entry, disable os-prober |
| `data/etc/dracut.conf.d/freshroot.conf` | `dracut --regenerate-all` | Running system | Enables the 90freshroot dracut module |
| `data/usr/lib/dracut/modules.d/90freshroot/module-setup.sh` | dracut build | initramfs generation | Declares module deps, installs generator + setup script into initramfs |
| `data/usr/lib/dracut/modules.d/90freshroot/freshroot-generator` | Every boot (initramfs) | initramfs (PID 1 generators) | Checks for rd.freshroot, creates setup service + sysroot.mount drop-in |
| `data/usr/lib/dracut/modules.d/90freshroot/freshroot-setup.sh` | Every boot (initramfs) | initramfs (systemd service) | Mounts btrfs top-level, deletes old @rootfs, snapshots new writable @rootfs |
| `data/etc/systemd/system/freshroot-update.service` | Timer or manual | Running system | Oneshot service wrapping freshroot-update |
| `data/etc/systemd/system/freshroot-update.timer` | Boot | Running system | Triggers update service every 4 hours |
| `data/etc/systemd/system/machine-id-persist.service` | Every boot | Running system | Restores /etc/machine-id from @machine-id subvolume after rollback |

## Workflow for every change

### Before writing code

1. **Read the files you're changing.** Do not modify code you haven't read.
2. **Identify all cross-references.** Changes to names, paths, or subvolume lists ripple across multiple files. Use grep to find every reference before editing.
3. **Check which environment the code runs in.** Installer context (/target available, no running system), initramfs (minimal environment, no networking, limited binaries), or running system (full Ubuntu).

### Making the change

4. **Edit the minimum necessary.** Do not refactor surrounding code, add comments to unchanged lines, or "improve" things that weren't asked for.
5. **Maintain sync points.** If you add a persistent subvolume, update: Phase 2 (create), Phase 3 (migrate_sv call), Phase 4 (fstab line), Phase 7 (whitelist case). If you touch a lineage helper or `protect_snapshot_kernels`, fix all copies: `freshroot-update`, `freshroot-build`, `freshroot-install`, and the sh-dialect copy in `06_freshroot`. If you rename a file, grep the entire project.
6. **Respect permissions.** Config files under `data/etc/` must be 644. Executable scripts must be 755. Set permissions on the source files in `data/`, not in `debian/rules`.
7. **No `debian/conffiles` needed.** debhelper auto-detects files under `/etc/` as conffiles.
8. **`debian/rules` overrides `dh_auto_build` and `dh_auto_clean` as no-ops** to prevent debhelper from recursively invoking the project Makefile.

### After writing code

9. **Run `make lint`** to shellcheck all scripts.
10. **Run `make build`** to verify the deb builds cleanly. Check for warnings.
11. **Inspect `make build` output** for:
    - `dh_fixperms` should not need to fix anything you set wrong
    - No "conffile is duplicated" warnings
    - No `dh_usrlocal` errors (nothing under `/usr/local/`)
12. **Verify package contents** with `dpkg-deb -c target/*.deb` — confirm your files are present at the expected paths with correct permissions.

### Commit discipline

13. **One logical change per commit.** Don't bundle unrelated fixes.
14. **Commit message format:** imperative mood, explain what and why, not how. The code shows how.

## Common mistakes to avoid

- **Putting files in `/usr/local/`** — deb policy forbids this, `dh_usrlocal` will error.
- **Forgetting `--resolv-conf=bind-stub`** on nspawn invocations — DNS will fail.
- **Referencing uninitialized variables under `set -u`** — especially in nspawn shells where bash profiles source scripts that assume `SUDO_USER` etc. exist.
- **Editing subvolume lists in only one place** — they appear in 4 places in the bootstrap script.
- **Editing lineage helpers in only one file** — they are copied into freshroot-update, freshroot-build, freshroot-install AND 06_freshroot (which runs without `set -u`/`pipefail`).
- **Sorting snapshots by name** — `root.<lineage>.<TS>` sorts after `root.<TS>` lexically; always sort on the parsed timestamp field.
- **Referencing a new conf key without a pre-source default** — upgraded systems keep their old conffile; under `set -u` an unguarded `${LINEAGE_QUOTAS[@]}` aborts the update timer.
- **Using `dh clean` in the Makefile `clean` target** — causes infinite recursion because debhelper calls `make clean`.
- **Adding `--buildinfo-option=-u` or `--changes-option=-u` to dpkg-buildpackage** — these flags specify where to READ files, not where to WRITE them.
- **Forgetting the self-relocation in freshroot-setup** — Phase 7 deletes /target/* (non-subvolume entries), which includes the script itself if it's still running from /target.

## Build commands

```bash
make build    # build .deb into target/
make lint     # shellcheck all scripts
make clean    # remove build artifacts
```
