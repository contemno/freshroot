# CLAUDE.md — Agent Guide for freshroot

## What this project is

A `.deb` package (`freshroot`) that makes an Ubuntu installation immutable via btrfs snapshots. Every boot starts fresh from a read-only snapshot; runtime changes are discarded on reboot. Persistent state (home, logs, network config, etc.) lives on dedicated btrfs subvolumes that survive rollbacks. Updates are staged in an nspawn container and committed as new read-only snapshots. Kernels are managed outside apt: module trees and firmware live on shared subvolumes, each kernel is compiled into a UKI stored next to its modules, and a stage-1 boot menu (a UKI on the ESP) unlocks LUKS, offers snapshot × kernel and kexecs into the choice. GRUB is not used.

This is **not** a general-purpose tool. It targets a specific architecture: LUKS2-encrypted btrfs on Ubuntu 24.04+ (noble), UEFI, with dracut replacing initramfs-tools, installed via Ubuntu's autoinstall system.

## Architecture — how the pieces connect

```
        INSTALL TIME                    BOOT TIME                         UPDATE TIME                  KERNEL TIME
        ────────────                    ─────────                         ───────────                  ───────────
 autoinstall  freshroot-setup    firmware → stage-1 UKI (ESP)      freshroot-update            freshroot-kernel
 user-data    --bootstrap        (90freshroot-stage1, no systemd)  (timer or manual)           (manual / post-commit hook)
     │              │                        │                              │                           │
     │ packages:    │ Phase 1-11 (+3.5):     │ unlock LUKS (one prompt)     │ 1. find latest snapshot   │ add: fetch mainline debs
     │ - freshroot  │ restructure btrfs,     │ mount top-level ro           │ 2. clone → @staging       │   (or local debs / raw)
     │              │ create subvolumes      │ index @snapshots + store     │ 3. nspawn into @staging   │   → modules on @modules,
     │ late-cmds:   │ (incl. @modules,       │ menu: snapshot × kernel      │ 4. apt upgrade, purge     │     vmlinuz → store dist/
     │ - setup      │ @firmware), migrate,   │ extract .linux/.initrd       │    kernel pkgs, REPOS     │ build_uki: nspawn clone of
     │   --bootstrap│ kernel → store (3.5),  │ from the store UKI,          │ 5. uki_store_ok gate      │   newest snap (@kernelstage)
     │              │ fstab/crypttab, tweaks,│ append keyfile cpio,         │ 6. snapshot -r → new snap │   depmod + dracut + ukify
     │              │ baseline snapshot,     │ kexec (rd.freshroot=1)       │ 7. delete @staging        │   sign inner kernel + UKI
     │              │ first UKI + stage 1    │        ▼                     │ 8. prune per lineage      │ stage1: menu UKI → ESP,
     │              │ → ESP, efibootmgr      │ stage-2 dracut generator     │ 9. freshroot-kernel       │   efibootmgr entry
     │              │                        │ (90freshroot): @rootfs clone │    rebuild --if-stale     │ rebuild/gc/remove/sb-status
     ▼              ▼                        ▼                              ▼                           ▼
 ┌──────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
 │  ESP: EFI/freshroot/freshroot-stage1.efi (+ -prev.efi), EFI/BOOT/BOOTX64.EFI fallback (claimed only when free)   │
 ├──────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │  BTRFS top-level (subvolid=5), inside LUKS                                                                       │
 │                                                                                                                  │
 │  @              original root (reference, not booted directly in clean mode)                                     │
 │  @rootfs        ephemeral writable clone (created fresh each boot by the stage-2 dracut module)                  │
 │  @staging       transient writable clone (exists only during updates)                                            │
 │  @kernelstage   transient clone freshroot-kernel builds initramfs/UKIs in (never @staging)                       │
 │  @snapshots/    read-only snapshots, grouped into per-release "lineages"; they carry NO kernels                  │
 │                 (root.<lineage>.YYYYMMDDTHHMMSS; legacy root.YYYYMMDDTHHMMSS                                     │
 │                 resolves its lineage from the os-release inside the snapshot)                                    │
 │  @modules       /usr/lib/modules — <kver>/ module trees + the kernel STORE in .freshroot/:                       │
 │                 dist/vmlinuz-<kver>, uki/uki-<kver>.efi + .meta, stage1/freshroot-stage1.efi + .meta             │
 │  @firmware      /usr/lib/firmware — travels with kernels, not snapshots                                          │
 │  freshroot-state/  plain directory (not a subvolume): default-lineage, sb/db.key + db.crt                        │
 │  @home, @log, @apt-cache, @tmp, @spool, @crash, @containers, @flatpak,                                           │
 │  @snap, @libvirt, @AccountsService, @gdm3, @bluetooth, @cups, @fwupd,                                            │
 │  @netmanager, @machine-id, @swap                                                                                 │
 │     └─ persistent subvolumes, mounted via fstab, survive reboots and rollbacks                                   │
 └──────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

## Key design constraints

1. **dracut-systemd for stage 2, deliberately NOT for stage 1.** Ubuntu 24.04 uses systemd inside the initramfs. Traditional dracut mount hooks don't work there because `$root` isn't propagated between services and `sysroot.mount` overrides hook mounts, so the stage-2 module (`90freshroot`) is a systemd generator that creates a setup service (Before=sysroot.mount) and a sysroot.mount.d drop-in. The stage-1 menu (`90freshroot-stage1`) is the opposite: built with `--omit "systemd systemd-initrd dracut-systemd …"`, it uses classic `cmdline`/`mount` hooks (POSIX sh, linted with `-s sh`) and a bash menu that owns `/dev/console`, because it never hands control to an init — it ends in `kexec -e`.

2. **`rd.freshroot` kernel parameter is the gate.** The stage-2 generator checks /proc/cmdline for this flag. Without it, boot proceeds normally. Stage 1 emits `rd.freshroot=1` for snapshot entries and omits it for the tainted `@` entry (which also masks the update units). Stage 1's own knobs (`rd.freshroot.timeout`, `rd.freshroot.modules`, `rd.freshroot.dev`) are baked into the stage-1 UKI's cmdline at build time — stage 1 runs before the disk is unlocked and can never read the conffile.

3. **`set -euo pipefail` everywhere.** All scripts use strict mode. When modifying scripts, ensure every variable is initialized before use and unbound variable errors cannot occur. This is especially important in nspawn containers where bash profile scripts reference variables like `SUDO_USER`, `debian_chroot`, etc. The nspawn shell command uses `set +u; exec bash -l` to handle this. Inside the stage-1 initramfs only what `module-setup.sh` installs exists (`od`, `dd`, `cpio`, `kexec`, `cryptsetup`, `btrfs`, …); every per-snapshot lookup in the menu is ||-guarded because one unreadable snapshot must not kill the menu.

4. **The bootstrap runs in the INSTALLER environment.** `freshroot-setup` runs from autoinstall late-commands, meaning it has access to `/target` and raw block devices but is NOT inside a chroot. It uses `curtin in-target --target="$T"` to run commands inside the target root (there is no nspawn there — Phase 10 mounts `@`, `@modules`, `@firmware` and the ESP under `$T` and runs depmod/dracut/ukify/sbsign in-target). It self-relocates to /tmp because Phase 7 deletes non-subvolume entries from /target.

5. **nspawn needs `--resolv-conf=bind-stub`.** The `copy-host` mode copies a symlink that doesn't resolve inside the container. Always use `bind-stub`. `freshroot-kernel` builds in its own clone `@kernelstage` with `@modules`/`@firmware` bound in — never in `@staging`, so a kernel build can run while an update is retained for investigation.

6. **No `/usr/local/` in deb packages.** Debian policy reserves `/usr/local/` for the local admin. Scripts go in `/usr/sbin/`.

7. **Config is tool-agnostic.** The `REPOS` array in `freshroot-update.conf` holds git URLs. Each repo must have an executable `./install.sh`. The user chooses their own config management (ansible, puppet, plain scripts, etc.). The package does NOT depend on ansible.

8. **Subvolume lists must stay in sync.** The list of persistent subvolumes appears in multiple places: Phase 2 (create), Phase 3 (migrate), Phase 4 (fstab), and Phase 7 (cleanup whitelist). Adding or removing a subvolume requires updating ALL of these. `@modules` and `@firmware` additionally appear as `MODULES_SUBVOL`/`FIRMWARE_SUBVOL` conf keys (pre-source defaults in every tool), in `freshroot-install`'s import fstab keep-list, in the stage-1 `rd.freshroot.modules` default, and in the rig's `build-image.sh`.

9. **The lineage helper corpus is copied.** `snap_ts`, `snap_label`, `lineage_of_root`, `snapshot_lineage`, `lineage_quota`, `list_ro_snapshots`, `booted_snapshot`, `current_lineage`, `ensure_default_lineage`, `write_legacy_default_lineage`, `prune_snapshots`, `resolve_from_ref`, `release_kernel_holds`, `uki_store_ok`, `rebuild_ukis_if_stale`, the update-grub suppress/restore helpers and the in-container kernel-package purge block are copied between `freshroot-update`, `freshroot-build` and `freshroot-install` (each omits helpers it does not use). `freshroot-kernel` carries its own copy of `snap_ts`, `snap_label`, `lineage_of_root`, `snapshot_lineage`, `list_ro_snapshots` and `resolve_btrfs_device`. The stage-1 `freshroot-menu-lib.sh` carries a PARTIAL copy (`snap_ts`, `snap_label`, `lineage_of_root`, `snapshot_lineage`, ceremony detection) plus the PE section parser — bash inside the initramfs, where every lookup must be ||-guarded. `installer/freshroot-setup` Phase 9 re-derives the lineage with the same parsing rules, and Phases 3.5/10 carry an inline copy of the store layout, the dracut/ukify recipe, the `.meta` fields and the sign-inner-kernel-then-UKI rule. The tools deliberately share no library — fix a bug in every copy. All snapshot ordering sorts on the parsed TIMESTAMP field, never on raw names (lineage-prefixed names sort after legacy names lexically); kernel ordering uses `sort -V`.

10. **New config keys never reach existing installs automatically.** `freshroot-setup` rewrites the conffile at install time, so dpkg keeps the old version on upgrades. Every tool must initialize new keys before sourcing the conf (`LINEAGE_QUOTAS=()`, `MODULES_SUBVOL="@modules"`, `KERNEL_KEEP=3`, `SB_KEY_DIR=""` etc.) and guard every lookup. The default boot lineage therefore lives OUTSIDE the conffile, in `<btrfs top-level>/freshroot-state/default-lineage` (written by `freshroot-install --switch`, seeded by the installer / first lineage-aware run; the pre-stage-1 location `/boot/freshroot/default-lineage` is migrated from and dual-written while that directory exists). Stage 1 reads that file directly.

11. **The kernel store is the only boot path.** Snapshots are kernel-free; the tools refuse to commit while the store holds no UKI with a matching module tree (`uki_store_ok`). The store lives in `@modules/.freshroot/` — a dot-dir so `/usr/lib/modules/*/` globs (kernel hooks, dkms, our own `store_kvers`) never see it as a kver. A UKI's embedded cmdline is vestigial: stage 1 extracts the `.linux`/`.initrd` PE sections (payload size = VirtualSize when 0 < VirtualSize ≤ SizeOfRawData, else SizeOfRawData — ukify pads raw sections) and builds the cmdline per entry. Under Secure Boot the INNER kernel must be signed before wrapping (kexec_file_load verifies the extracted image), the outer UKI after; any prior Canonical signature is stripped first. `stage1 --install` refuses an unsigned UKI while Secure Boot is on. Every post-commit path runs `_FRESHROOT_LOCK_HELD=1 freshroot-kernel rebuild --if-stale` (the lock is the shared `/run/freshroot-update.lock`; the env var stops the re-take).

## File roles

| File | Runs when | Runs where | Purpose |
|---|---|---|---|
| `installer/freshroot-setup` | Install time (late-commands) | Installer environment | Bootstrap: subvolumes (incl. @modules/@firmware), migration, kernel → store + apt purge (3.5), fstab, crypttab, tweaks, baseline snapshot, first UKI + stage 1 → ESP + boot entry (10) |
| `data/usr/sbin/freshroot-update` | Runtime (timer or manual) | Running system | Stage updates in nspawn on the booted lineage, purge kernel pkgs, gate on the store, snapshot result, per-lineage pruning, UKI rebuild hook |
| `data/usr/sbin/freshroot-build` | Runtime (timer or manual) | Running system | Two-tier "from scratch" builds: vanilla-upgrade pinned `@base`, then component layer from a fresh clone |
| `data/usr/sbin/freshroot-install` | Runtime (manual) | Running system | Lineage management: `--release` (stage an Ubuntu release upgrade as a NEW lineage), `--import` (foreign rootfs), `--switch` (sticky default boot lineage), `--remove` |
| `data/usr/sbin/freshroot-kernel` | Runtime (manual; `rebuild --if-stale` as a post-commit hook) | Running system | Kernel store: `add` (mainline/deb/raw), `adopt`, `list`, `remove`, `rebuild`, `gc`, `stage1` (build/install/test-next/make-default), `sb-status`; Secure Boot signing |
| `data/usr/lib/freshroot/ceremony` | Read by stage 1 | Inside each snapshot tree | Boot-ceremony capability marker (contains the ceremony version, `1`); trees without it (or the dracut module) get entries without `rd.freshroot` |
| `data/etc/freshroot-update.conf` | Sourced by the runtime tools | Running system | Config: REPOS, subvol names, retention, kernel store, stage-1 knobs, signing key, boot partitions, log dir |
| `data/etc/apt/preferences.d/freshroot-kernel-pin` | Every apt run inside a tree | Snapshot trees / staging | Pin-Priority -1 for kernel packages so apt never reinstalls them |
| `data/etc/dracut.conf.d/freshroot.conf` | dracut inside `@kernelstage` | Snapshot clone | Enables the 90freshroot (stage-2) module in every store UKI |
| `data/usr/lib/dracut/modules.d/90freshroot/module-setup.sh` | dracut build | initramfs generation | Declares module deps, installs generator + setup script into initramfs |
| `data/usr/lib/dracut/modules.d/90freshroot/freshroot-generator` | Every boot (stage-2 initramfs) | initramfs (PID 1 generators) | Checks for rd.freshroot, creates setup service + sysroot.mount drop-in |
| `data/usr/lib/dracut/modules.d/90freshroot/freshroot-setup.sh` | Every boot (stage-2 initramfs) | initramfs (systemd service) | Mounts btrfs top-level, deletes old @rootfs, snapshots new writable @rootfs |
| `data/usr/lib/dracut/modules.d/90freshroot-stage1/module-setup.sh` | `freshroot-kernel stage1` | dracut build in `@kernelstage` | Declares the non-systemd stage-1 module: hooks, menu, binaries, drivers |
| `data/usr/lib/dracut/modules.d/90freshroot-stage1/parse-freshroot-menu.sh` | Every boot (stage 1) | initramfs cmdline hook (sh) | Accepts `root=freshroot` so dracut does not wait for a root device |
| `data/usr/lib/dracut/modules.d/90freshroot-stage1/mount-freshroot-menu.sh` | Every boot (stage 1) | initramfs mount hook (sh) | Runs the menu |
| `data/usr/lib/dracut/modules.d/90freshroot-stage1/freshroot-menu-lib.sh` | Every boot (stage 1) | initramfs (bash) | Lineage helpers (partial copy), ceremony detection, PE header/section/signature parser |
| `data/usr/lib/dracut/modules.d/90freshroot-stage1/freshroot-menu.sh` | Every boot (stage 1) | initramfs (bash) | Unlock LUKS, index snapshots + store, menu, build cmdline, extract UKI sections, keyfile cpio, kexec |
| `data/usr/share/freshroot/kernel-ppa.asc` | `freshroot-kernel add --mainline` | Running system | GPG key that signs the mainline CHECKSUMS files |
| `data/etc/systemd/system/freshroot-update.service` | Timer or manual | Running system | Oneshot service wrapping freshroot-update |
| `data/etc/systemd/system/freshroot-update.timer` | Boot | Running system | Triggers update service every 4 hours |
| `data/etc/systemd/system/machine-id-persist.service` | Every boot | Running system | Restores /etc/machine-id from @machine-id subvolume after rollback |
| `debian/freshroot.maintscript` | Package upgrade | dpkg | Retires the GRUB-era conffiles (`06_freshroot`, `grub.d/freshroot.cfg`) |
| `test/*-unit.sh` | `make unit` (CI) | Build host | Function-level tests via sed extraction + eval: PE parser vs a real ukify artifact, menu indexing, mainline index parsing, signing helpers |
| `test/rig/` | `make rig-image` / `rig-test` | Root host with QEMU | Disposable LUKS+btrfs image in the install layout, e2e scenarios over serial (incl. Secure Boot) |

## Workflow for every change

### Before writing code

1. **Read the files you're changing.** Do not modify code you haven't read.
2. **Identify all cross-references.** Changes to names, paths, or subvolume lists ripple across multiple files. Use grep to find every reference before editing.
3. **Check which environment the code runs in.** Installer context (/target available, no running system, no nspawn), stage-1 initramfs (no systemd, no networking, no conffile, disk still locked), stage-2 initramfs (systemd, minimal), nspawn clone (`@staging`/`@kernelstage`), or running system (full Ubuntu).

### Making the change

4. **Edit the minimum necessary.** Do not refactor surrounding code, add comments to unchanged lines, or "improve" things that weren't asked for.
5. **Maintain sync points.** If you add a persistent subvolume, update: Phase 2 (create), Phase 3 (migrate_sv call), Phase 4 (fstab line), Phase 7 (whitelist case). If you touch a lineage helper, `uki_store_ok`, `rebuild_ukis_if_stale`, `release_kernel_holds` or the kernel purge block, fix all copies: `freshroot-update`, `freshroot-build`, `freshroot-install`, plus `freshroot-kernel` and the stage-1 `freshroot-menu-lib.sh` where they carry it. If you touch the store layout, the dracut/ukify recipe, the `.meta` fields or the signing order, fix `freshroot-kernel`, installer Phases 3.5/10, the stage-1 menu's `store_kernels`, and the rig's `build-image.sh`. If you rename a file, grep the entire project.
6. **Respect permissions.** Config files under `data/etc/` must be 644. Executable scripts must be 755. Set permissions on the source files in `data/`, not in `debian/rules`.
7. **No `debian/conffiles` needed.** debhelper auto-detects files under `/etc/` as conffiles. Removed conffiles go in `debian/freshroot.maintscript` (`rm_conffile`).
8. **`debian/rules` overrides `dh_auto_build` and `dh_auto_clean` as no-ops** to prevent debhelper from recursively invoking the project Makefile.

### After writing code

9. **Run `make lint`** to shellcheck all scripts (bash with `-x`; the stage-1 hooks in `sh` dialect).
10. **Run `make unit`** — the function-level tests extract functions from the scripts by name, so renaming a tested function breaks the harness.
11. **Run `make build`** to verify the deb builds cleanly. Check for warnings.
12. **Inspect `make build` output** for:
    - `dh_fixperms` should not need to fix anything you set wrong
    - No "conffile is duplicated" warnings
    - No `dh_usrlocal` errors (nothing under `/usr/local/`)
13. **Verify package contents** with `dpkg-deb -c target/*.deb` — confirm your files are present at the expected paths with correct permissions. Do not commit the `debian/*.debhelper` files the build generates (`make clean` removes them).

### Commit discipline

14. **One logical change per commit.** Don't bundle unrelated fixes.
15. **Commit message format:** imperative mood, explain what and why, not how. The code shows how.

## Common mistakes to avoid

- **Putting files in `/usr/local/`** — deb policy forbids this, `dh_usrlocal` will error.
- **Forgetting `--resolv-conf=bind-stub`** on nspawn invocations — DNS will fail.
- **Referencing uninitialized variables under `set -u`** — especially in nspawn shells where bash profiles source scripts that assume `SUDO_USER` etc. exist.
- **Editing subvolume lists in only one place** — they appear in 4 places in the bootstrap script.
- **Editing lineage helpers in only one file** — they are copied into freshroot-update, freshroot-build, freshroot-install, freshroot-kernel AND the stage-1 menu lib (initramfs, every lookup ||-guarded).
- **Sorting snapshots by name** — `root.<lineage>.<TS>` sorts after `root.<TS>` lexically; always sort on the parsed timestamp field.
- **Referencing a new conf key without a pre-source default** — upgraded systems keep their old conffile; under `set -u` an unguarded `${LINEAGE_QUOTAS[@]}` aborts the update timer.
- **Reading the conffile from stage 1** — it runs before the disk is unlocked; anything it needs is baked into its cmdline by `freshroot-kernel stage1`.
- **Putting anything but the store under `@modules/.freshroot/`, or store files outside it** — `/usr/lib/modules/*/` globs must never see a non-kver directory, and nothing outside the dot-dir is invisible to them.
- **Writing kernels or boot files into a snapshot tree** — snapshots are kernel-free; `/boot` and the ESP are never bound into staging. New kernels go through `freshroot-kernel add`.
- **Trusting a UKI's raw section size or embedded cmdline** — extract with VirtualSize (ukify pads raw sections) and build the cmdline per entry; kexec never runs the EFI stub.
- **Signing only the outer UKI** — kexec_file_load verifies the extracted inner kernel; sign it before wrapping, and strip a prior Canonical signature first (`sbattach --remove`).
- **Checking signatures with `sbverify --list`'s exit code** — it exits 0 for unsigned files; grep for a `signature N` line.
- **Letting `efibootmgr -c` reorder the boot** — it prepends the new entry; restore the previous `BootOrder` with the entry appended unless `--make-default` was asked for.
- **Using `dh clean` in the Makefile `clean` target** — causes infinite recursion because debhelper calls `make clean`.
- **Adding `--buildinfo-option=-u` or `--changes-option=-u` to dpkg-buildpackage** — these flags specify where to READ files, not where to WRITE them.
- **Forgetting the self-relocation in freshroot-setup** — Phase 7 deletes /target/* (non-subvolume entries), which includes the script itself if it's still running from /target.

## Build commands

```bash
make build      # build .deb into target/
make lint       # shellcheck all scripts
make unit       # function-level tests (needs systemd-ukify, sbsigntool, openssl for the full set)
make clean      # remove build artifacts
make rig-image  # QEMU fixture image (root, loop devices, dm; exits 77 where unsupported)
make rig-run    # boot the fixture interactively on a serial console
make rig-test   # e2e scenarios A–F via pexpect
make rig-clean  # drop the fixture image, vars and logs
```
