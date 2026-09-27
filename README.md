# Freshroot — BTRFS snapshot-based immutable root

## Overview

This system makes an Ubuntu installation effectively immutable. Every boot starts fresh from a read-only btrfs snapshot, and runtime state is discarded on the next reboot. Persistent changes are only made through a controlled staging pipeline that runs system updates and user-defined provisioning scripts (ansible, plain shell, whatever you like — the package is tool-agnostic).

Kernels are managed **outside apt** by `freshroot-kernel`: module trees and firmware live on shared persistent subvolumes, each kernel is compiled with dracut + `ukify` into a Unified Kernel Image (UKI) stored next to its modules, and a small **stage-1 boot menu** (itself a UKI on the ESP) unlocks the disk, lets you pick any snapshot × any kernel, and kexecs into it. Snapshots carry no kernels at all. Everything is signed with your own Secure Boot key when one is configured. There is no GRUB.

Ships as a `.deb` package (`freshroot`) that can be installed during autoinstall via the `packages:` section or from a PPA.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  ESP (vfat, unencrypted)                                            │
│    EFI/freshroot/freshroot-stage1.efi  ← stage-1 boot menu (UKI)    │
│    EFI/BOOT/BOOTX64.EFI                ← removable-media fallback   │
└─────────────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────────────┐
│  BTRFS top-level (subvolid=5), inside LUKS                          │
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
│  @kernelstage          ← transient clone freshroot-kernel builds in │
│                                                                     │
│  @modules              ← /usr/lib/modules, shared by every snapshot │
│    <kver>/                        module trees                      │
│    .freshroot/dist/vmlinuz-<kver> kernel images (kernel store)      │
│    .freshroot/uki/uki-<kver>.efi  UKIs the stage-1 menu boots       │
│    .freshroot/stage1/             the stage-1 UKI + metadata        │
│  @firmware             ← /usr/lib/firmware, travels with kernels    │
│  freshroot-state/      ← plain dir: default-lineage, sb/ (db key)   │
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
  `freshroot-state/default-lineage` on the btrfs top-level (read by the
  stage-1 menu at every boot) and changed only by
  `freshroot-install --switch <lineage>` — installing 26.04 next to 24.04
  never silently changes what boots. Installs that still have the old
  `/boot/freshroot/default-lineage` are migrated automatically.
- `freshroot-update` operates on the *booted* lineage by default
  (`--lineage`/`--from` override it), and commits under the same label; if
  you perform a release upgrade inside `--shell`, the result automatically
  lands in the new release's lineage.
- Lineages are labels: `freshroot-install --lineage myserver` lets you keep
  several independent lines of the same OS release.

### Boot flow

1. **Firmware** boots the stage-1 UKI from the ESP (`EFI/freshroot/freshroot-stage1.efi`, or the `EFI/BOOT/BOOTX64.EFI` fallback). Under Secure Boot the firmware verifies its signature against your `db` key.
2. **Stage 1** (the `90freshroot-stage1` dracut module, a non-systemd initramfs) asks for the LUKS passphrase once, mounts the btrfs top-level read-only, and indexes `@snapshots` (grouped by lineage) and the kernel store on `@modules`. It shows a menu: snapshots by number, `t` for the tainted `@` root, `k` to cycle through store kernels, `s` for a debug shell. After `STAGE1_TIMEOUT` seconds it boots the newest snapshot of the default lineage with the newest kernel.
3. For the chosen entry it extracts the `.linux` and `.initrd` sections straight out of the store UKI (the UKI's EFI stub never runs), appends the LUKS keyfile to the initrd so stage 2 needs no second passphrase, builds the kernel command line (`rootflags=subvol=@snapshots/<name>`, `rd.luks.*`, `rd.freshroot=1`, console settings) and kexecs into it. Under lockdown only `kexec_file_load` is used, which verifies the kernel's signature.
4. **Stage 2** (the `90freshroot` module in that kernel's initramfs) uses a systemd generator to:
   - Create a setup service that runs before `sysroot.mount`.
   - Mount the btrfs top-level, delete the previous `@rootfs`, and create a new writable snapshot from the selected read-only snapshot.
   - Drop in an override for `sysroot.mount` so systemd mounts `@rootfs` as the real root.
5. **systemd** boots normally from the ephemeral writable root; `@modules` and `@firmware` mount from fstab, so the tree sees the modules of whichever kernel booted it.

### Update flow

Runs manually or every 4 hours via the systemd timer:

1. Find the latest read-only snapshot.
2. Create a writable `@staging` clone.
3. Enter `@staging` with `systemd-nspawn`, bind-mounting:
   - `@apt-cache` onto `/var/cache/apt` so downloaded `.deb` files persist across runs.
   - The btrfs top-level (subvolid=5) at `/run/freshroot-toplevel` so `install.sh` can manage top-level subvolumes (`btrfs subvolume create /run/freshroot-toplevel/@whatever`). This exposes all subvolumes rw to the container — only list trusted entries in `REPOS`.
   - Any host paths listed in `BIND_MOUNTS` (for local dev or shipping secrets).
   No `/boot` or ESP is bound: nothing inside a snapshot writes kernels or boot loaders any more.
4. Inside the container: `apt full-upgrade`, then purge any kernel packages apt still knows about (the shipped pin `/etc/apt/preferences.d/freshroot-kernel-pin` keeps `linux-image*`, `linux-modules*`, `linux-headers*`, `linux-generic*` and `linux-virtual*` from ever coming back — `linux-firmware` stays apt-managed and lands on `@firmware` through the mount), cloud-init provisioning (`cloud-init init --local`, `init`, `modules --mode={config,final}`), then clone and run `./install.sh` from each repo listed in `REPOS`. Entries using the `local://<path>` scheme skip the clone and run `install.sh` directly (pair with `BIND_MOUNTS` to test uncommitted code).
5. Verify the kernel store holds at least one UKI with a matching module tree — otherwise the commit is refused and staging is retained (run `freshroot-kernel add` or `adopt` first).
6. **On success:** snapshot `@staging` as a new read-only snapshot in the same lineage, delete `@staging`, prune each lineage past its quota, and run `freshroot-kernel rebuild --if-stale` so every store UKI's initramfs is rebuilt from the new newest snapshot.
7. **On failure:** retain `@staging` for investigation, log the error.
8. The user reboots at their convenience to activate the new snapshot — it is picked up by the stage-1 menu with no boot-loader regeneration.

`update-grub` is still diverted to `/bin/true` *inside* the staging container: trees migrated from older installs may still contain the GRUB packages, and nothing on the host regenerates `grub.cfg` any more.

### Installing another OS release (new lineage)

```bash
# Stage an Ubuntu release upgrade into a new lineage (24.04 stays intact)
sudo freshroot-install --release 26.04     # or: --release resolute

# Try it from the stage-1 boot menu; when happy, make it the default lineage
sudo freshroot-install --switch ubuntu-26.04

# Didn't like it? Remove the whole lineage (kernels are lineage-independent,
# so there is nothing else to clean up)
sudo freshroot-install --remove ubuntu-26.04
```

`--release` clones the source snapshot to `@staging`, rewrites the **official Ubuntu** APT sources to the target codename (versions are resolved via `distro-info-data`), **disables third-party sources** for the run (they publish for new releases on their own schedule; the tool lists what it disabled so you can re-enable each one later), then runs `apt full-upgrade` in nspawn and commits the result as `root.ubuntu-26.04.<timestamp>`. The upgrade hop is validated (next release, or next LTS from an LTS; `--force` overrides). `dpkg --audit` must come back clean before the snapshot is committed. Because everything happens in the disposable `@staging` clone, a failed upgrade costs nothing — the staging tree is renamed to `@staging.failed-<timestamp>` for investigation and your running system is untouched.

For non-Ubuntu distros, `freshroot-install --import <dir|tarball> --lineage <name>` imports a prepared rootfs (debootstrap, cloud image, …) as a new lineage — see *Porting to other distros* below.

`systemd-nspawn` is launched with `SYSTEMD_SECCOMP=0` exported in its parent env to skip the default syscall filter — apt and git are syscall-heavy enough that the filter overhead is measurable. Staging runs trusted code, so the trade-off is acceptable.

## Kernel management (`freshroot-kernel`)

Kernels never pass through apt inside a snapshot. `freshroot-kernel` keeps a
**kernel store** on the `@modules` subvolume (mounted at `/usr/lib/modules`):

```
@modules/<kver>/                        module tree (what the running system sees)
@modules/.freshroot/dist/vmlinuz-<kver> kernel image, kept for rebuilds
@modules/.freshroot/uki/uki-<kver>.efi  kernel + initramfs as a UKI — what stage 1 boots
@modules/.freshroot/uki/uki-<kver>.meta build metadata (source, hashes, signing state, …)
@modules/.freshroot/stage1/             the stage-1 menu UKI and its metadata
```

The `.freshroot` dot-directory is invisible to `/usr/lib/modules/*/` globs, so
kernel hooks, dkms and the tools' own gates never mistake it for a kernel.

**Adding kernels.** `add --mainline <ver>` (or `--latest`) fetches an Ubuntu
mainline build from `MAINLINE_MIRROR` — the deb names are discovered from
the build's directory index, sha256 sums are verified when the mirror
publishes them (`--require-checksums` makes that mandatory) and the
`CHECKSUMS` file is GPG-verified against the shipped kernel-ppa key when
`gnupg` is installed (`--require-gpg` makes that mandatory). `add --deb
<image.deb> --deb <modules.deb>` ingests local debs, `add --vmlinuz <file>
--modules <dir>` a raw image plus module tree. Debs are unpacked with
`dpkg-deb -x`; no maintainer script ever runs. `adopt` imports a kernel that
apt installed before the migration (modules already on `@modules`, image in
`/boot`).

**Building UKIs.** For every kernel the tool clones the newest read-only
snapshot to `@kernelstage`, enters it with nspawn (binding `@modules` and
`@firmware`), runs `depmod` and `dracut --no-hostonly`, wraps the result with
`ukify`, then signs and atomically places the UKI in the store. UKIs are
therefore built from the userspace they will boot. `rebuild --if-stale`
(run by `freshroot-update`, `freshroot-build` and `freshroot-install` after
every commit) rebuilds a UKI when the newest snapshot changed, the dracut
configuration hash changed, the UKI or its metadata is missing, or the
signing key changed.

**Housekeeping.** `list` shows the store (`--remote` adds the newest mainline
builds offering your arch), `remove <kver>` deletes a kernel (refusing the
running one without `--force`, and the last bootable one always), `gc`
keeps the newest `KERNEL_KEEP` kernels plus the running and the stage-1
kernel. Any kernel boots any snapshot, so kernels are never tied to a
lineage.

**Stage 1.** `stage1` builds the boot-menu UKI on the newest store kernel
(`--kver` overrides) with `STAGE1_TIMEOUT` and `STAGE1_CMDLINE_EXTRA` baked
into its command line — it runs before the disk is unlocked, so it cannot
read the conffile. `--install` copies it to `EFI/freshroot/freshroot-stage1.efi`
(keeping the previous one as `freshroot-stage1-prev.efi`), claims
`EFI/BOOT/BOOTX64.EFI` only when that slot is free or already ours, and
registers a `freshroot` boot entry **without changing the boot order**.
`--test-next` boots it exactly once on the next reboot (`BootNext`);
`--make-default` puts it first in `BootOrder`. Removing or garbage-collecting
the kernel stage 1 was built on prints a reminder to rebuild it.

Rough cost: one UKI build is a dracut run inside nspawn, one to three
minutes per kernel. dkms/NVIDIA modules are out of scope for mainline
kernels (no headers are installed).

## Secure Boot

Freshroot signs with **your own** `db` key — there is no shim and no MOK.
Enrolling PK/KEK/db in the firmware is your process (firmware setup,
`sbkeysync`, `efi-updatevar`); freshroot never writes those variables.

- Put `db.key` and `db.crt` (PEM) in `SB_KEY_DIR` (default:
  `freshroot-state/sb/` on the btrfs top-level — root-only and never inside
  a snapshot). `SB_KEY_URI` names a PKCS#11 token key instead of `db.key`.
- Every kernel image is signed **before** it is wrapped (any existing
  Canonical signature is stripped first — it chains to shim, not to your
  db) and every UKI is signed **after**. Stage 1 kexecs the extracted inner
  kernel, so that is the signature `kexec_file_load` verifies under lockdown;
  the outer signature is what the firmware verifies on the stage-1 UKI.
- Without a key everything is built unsigned, loudly. `stage1 --install`
  refuses to replace the stage-1 UKI with an unsigned one while Secure Boot
  is enabled. In the menu, kernels without a signature are labeled and, under
  lockdown, will not boot.
- `freshroot-kernel sb-status` reports the firmware state, the lockdown
  mode, the configured key, whether the firmware `db` lists your certificate
  (needs `efitools`) and each store kernel's signing state.
- Key rotation: replace the files and run `freshroot-kernel rebuild --all`
  (or wait for the next commit — a signer change counts as stale), then
  `stage1 --install`.

Known limits and risks: the initrd is not covered by kexec's verification
(as with every GRUB/shim setup today). Dropping Microsoft's certificates from
`db` can break option ROMs (discrete GPUs, some NICs) — keep the Microsoft
UEFI CA in `db` if you rely on them. A compromised `db.key` is a full boot
compromise: keep it off-tree, root-only, ideally on a token. Enabling Secure
Boot with a stale or unsigned stage 1 on the ESP leaves the machine
unbootable until you disable it again — validate with `--test-next` first.

## Project layout

```
debian/                                                ← deb package scaffolding
  control, rules, postinst, prerm, changelog, freshroot.maintscript, ...

data/                                                  ← package install tree (maps to /)
  etc/
    freshroot-update.conf                              ← configuration (update, kernel store, stage 1, signing)
    apt/preferences.d/
      freshroot-kernel-pin                             ← keeps kernel packages out of apt inside trees
    dracut.conf.d/
      freshroot.conf                                   ← enables the stage-2 dracut module
    systemd/system/
      freshroot-update.service                         ← oneshot update service
      freshroot-update.timer                           ← 4-hour periodic trigger
      freshroot-provision.service                      ← first-boot cloud-init hook
      machine-id-persist.service                       ← restores machine-id after rollback
  usr/
    lib/dracut/modules.d/90freshroot/                  ← STAGE 2 (systemd initramfs, inside each store UKI)
      module-setup.sh                                  ← dracut module metadata
      freshroot-generator                              ← systemd generator for boot-time setup
      freshroot-setup.sh                               ← creates writable @rootfs from snapshot
    lib/dracut/modules.d/90freshroot-stage1/           ← STAGE 1 (non-systemd initramfs, the ESP UKI)
      module-setup.sh                                  ← dracut module metadata
      parse-freshroot-menu.sh, mount-freshroot-menu.sh ← dracut hooks (root=freshroot)
      freshroot-menu-lib.sh                            ← lineage helpers + PE section parser
      freshroot-menu.sh                                ← unlock, index, menu, extract, kexec
    lib/freshroot/
      ceremony                                         ← boot-ceremony capability marker (version)
    sbin/
      freshroot-update                                 ← update/staging script (nspawn)
      freshroot-build                                  ← two-tier "from scratch" snapshot builds
      freshroot-install                                ← lineage management (new releases, switch, remove)
      freshroot-kernel                                 ← kernel store, UKIs, stage 1, Secure Boot signing
    share/freshroot/
      kernel-ppa.asc                                   ← GPG key that signs mainline CHECKSUMS

installer/
  freshroot-setup                                      ← autoinstall bootstrap (shipped
                                                         separately, not inside the .deb)

test/
  pe-unit.sh, menu-unit.sh, kernel-unit.sh, sign-unit.sh  ← unit tests (make unit)
  rig/                                                 ← QEMU end-to-end rig (make rig-image / rig-test)
```

## Building the package

```bash
# Install build dependencies (once)
sudo apt install debhelper devscripts shellcheck systemd-ukify systemd-boot-efi sbsigntool

# Lint all shell scripts
make lint

# Unit tests (PE parser against a real ukify artifact, menu indexing,
# mainline index parsing, signing helpers — no root, btrfs or QEMU needed)
make unit

# Build the .deb
make build

# Result: target/freshroot_<version>_all.deb and target/freshroot-setup
```

The QEMU rig (`make rig-image`, `make rig-run`, `make rig-test`) builds a
disposable LUKS+btrfs image laid out exactly like an install — kernel-free
snapshots, a store UKI, the packaged stage 1 on the ESP, test Secure Boot
keys — and drives the whole boot over the serial console; see
[test/rig/README.md](test/rig/README.md). It needs root, loop devices and
device-mapper on the host and skips itself where it cannot run.

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

The bootstrap script handles all phases: btrfs subvolume restructuring (including `@modules` and `@firmware`), data migration, handing the installer's kernel to the kernel store and purging the kernel packages, fstab/crypttab generation, machine-id persistence, top-level cleanup, first-boot tweaks, baseline snapshot, then building the first store UKI and the stage-1 menu, installing stage 1 on the ESP and registering its boot entry. To get a signed install, ship `db.key` and `db.crt` to `/target/freshroot-state/sb/` in an earlier late-command; without them the install is unsigned and Secure Boot must stay off until you sign (see *Secure Boot*).

## Configuration

Edit `/etc/freshroot-update.conf` after install:

| Variable | Purpose |
|---|---|
| `REPOS` | Bash array of sources; each entry is either a git URL or `local://<path>`. Each source must have an executable `./install.sh` at its root |
| `BIND_MOUNTS` | Array of `HOST:CONTAINER[:ro]` entries bind-mounted into the nspawn staging container. Use for dev playbooks, secrets, or anything else the install scripts need |
| `MAX_SNAPSHOTS` | Per-lineage fallback quota: snapshots retained in each lineage that has no `LINEAGE_QUOTAS` entry (oldest pruned first; `0` = unlimited). With several lineages the total retained is the **sum** of the per-lineage quotas |
| `LINEAGE_QUOTAS` | Array of `"lineage=N"` per-lineage retention overrides, e.g. `"ubuntu-26.04=3"` |
| `MODULES_SUBVOL` / `FIRMWARE_SUBVOL` | The shared subvolumes mounted at `/usr/lib/modules` and `/usr/lib/firmware` (defaults `@modules`, `@firmware`); the kernel store lives on the former |
| `KERNEL_KEEP` | How many kernels `freshroot-kernel gc` keeps (newest first; the running and the stage-1 kernel are always kept) |
| `MAINLINE_MIRROR` / `KERNEL_FLAVOUR` / `KERNEL_ARCH` | Where `add --mainline`/`--latest` fetches from and which build it picks |
| `STAGE1_TIMEOUT` / `STAGE1_CMDLINE_EXTRA` | Menu countdown (0 = wait) and extra kernel parameters (e.g. a serial console) baked into the stage-1 UKI; rebuild with `freshroot-kernel stage1 --install` after changing them |
| `SB_KEY_DIR` / `SB_KEY_URI` | Directory holding `db.key` + `db.crt` (empty = `freshroot-state/sb` on the btrfs top-level), or a PKCS#11 URI for a token-held key |
| `BOOT_PARTITION` / `EFI_PARTITION` | The ESP stage 1 is installed to, and the legacy unencrypted `/boot` that `freshroot-kernel adopt` imports apt-era kernels from |
| `EDITION` | Free-form label (e.g. `workstation`, `server`) recorded for tooling |
| `LOG_DIR` | Where per-run logs are written (default `/var/log/freshroot-update`) |

Upgrading the package does **not** rewrite an existing (locally modified) `/etc/freshroot-update.conf` — the new keys are optional and every tool defaults them sanely when absent. The default boot lineage lives outside the conffile, in `freshroot-state/default-lineage` on the btrfs top-level. The stage-1 menu never reads the conffile: its knobs are baked into its command line when it is built (`rd.freshroot.timeout`, `rd.freshroot.modules`, plus `rd.freshroot.dev` to pin the LUKS device).

## Usage

```bash
# Run an update manually (operates on the booted lineage)
sudo freshroot-update

# Update a specific lineage / stage from a specific snapshot or lineage
sudo freshroot-update --lineage ubuntu-26.04
sudo freshroot-update --from root.ubuntu-24.04.20260407T120000 --shell

# Interactive shell in staging (exit 0 to snapshot, non-zero to abort)
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

# Kernels (never through apt)
sudo freshroot-kernel list --remote              # store + newest mainline builds
sudo freshroot-kernel add --latest               # newest mainline build → store UKI
sudo freshroot-kernel add --mainline 6.16.9
sudo freshroot-kernel add --deb linux-image-*.deb --deb linux-modules-*.deb
sudo freshroot-kernel rebuild --all              # after changing dracut config
sudo freshroot-kernel remove 6.14.0-061400-generic
sudo freshroot-kernel gc                         # keep the newest KERNEL_KEEP

# Stage-1 boot menu on the ESP
sudo freshroot-kernel stage1 --install           # build + install, boot order untouched
sudo freshroot-kernel stage1 --test-next         # ... and boot it once on the next reboot
sudo freshroot-kernel stage1 --make-default      # ... and make it the default
sudo freshroot-kernel sb-status                  # Secure Boot / lockdown / signing state

# Check timer status
systemctl status freshroot-update.timer

# View logs
ls /var/log/freshroot-update/
journalctl -u freshroot-update.service
```

## Migrating an existing install to the stage-1 boot menu

For a system installed by an earlier freshroot (apt-managed kernels in
`/boot`, GRUB, modules already on a shared `@modules`). Each step is
reversible until the last one; GRUB keeps working throughout.

1. **Get the new package into a snapshot** with the *old* tooling. Copy the
   deb somewhere the staging container sees (`/var/cache/apt/` is bound in),
   then `sudo freshroot-update --shell` and inside it
   `apt install /var/cache/apt/freshroot_<version>_all.deb`; exit 0 to
   commit. The kernel pin lands in the tree and the GRUB conffiles are
   retired; the old host tool still regenerates `grub.cfg` after this
   commit, so the new snapshot gets a GRUB entry.
2. **Reboot through GRUB** into that snapshot. From here the new tools run.
   Update runs refuse to commit until the store has a kernel (step 4), so
   do the next steps promptly or stop the timer meanwhile.
3. **Optional but recommended — `@firmware`.** Inside
   `sudo freshroot-update --shell`: `btrfs subvolume create
   /run/freshroot-toplevel/@firmware`, copy `/usr/lib/firmware/.` into it,
   add the fstab line (see the installer's Phase 4 for the exact form) and
   commit. Without it, UKIs are built with the firmware inside the newest
   snapshot, as before.
4. **Adopt the running kernel:** `sudo freshroot-kernel adopt` (or
   `adopt --all` for every kernel with modules on `@modules`). The image is
   copied from `/boot` into the store and its UKI is built inside a clone of
   the step-1 snapshot — the one that carries `ukify`.
5. **Install and test stage 1 with Secure Boot still off:**
   `sudo freshroot-kernel stage1 --test-next && sudo reboot`. This builds
   stage 1, installs it on the ESP, registers the `freshroot` boot entry
   at the *end* of the boot order and boots it once. If it fails, the next
   boot is GRUB again.
6. **Validate** from the booted system: one passphrase prompt only,
   `findmnt /` shows `subvol=/@rootfs`, `/proc/cmdline` carries
   `rd.freshroot=1`, `/usr/lib/modules/$(uname -r)` exists, the tainted `t`
   entry boots `@` with the update units masked.
7. **Secure Boot (optional):** put `db.key`/`db.crt` in
   `freshroot-state/sb/` on the btrfs top-level (mount it with
   `mount -o subvolid=5 <btrfs device> /mnt`), run
   `sudo freshroot-kernel rebuild --all` to re-sign every kernel and UKI,
   enroll your PK/KEK/db, enable Secure Boot, then repeat step 5 and check
   `freshroot-kernel sb-status` (Secure Boot enabled, lockdown
   `[integrity]`, firmware db contains your certificate).
8. **Make it the default:** `sudo freshroot-kernel stage1 --make-default`.
   GRUB stays installed but idle: pick the `ubuntu` firmware entry to reach
   its menu, which is frozen at its last regeneration — the tainted `@`
   entry stays valid, its snapshot entries only until those snapshots are
   pruned. Decommissioning `/boot` is manual and last.

Afterwards every update run purges kernel packages from the tree, new
kernels come from `freshroot-kernel add --latest`, and `gc` retires the
adopted ones when you no longer need them.

## Porting to other distros

The btrfs layout, stage-1 boot menu, kernel store, quotas and staging
pipeline are distro-neutral; what is Ubuntu-specific is the **boot
ceremony** implementation (a dracut module) and apt/nspawn staging. To boot
a non-Ubuntu lineage (imported with `freshroot-install --import`), the
distro's initramfs must implement the ceremony, version 1:

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
ports are future work — until one exists, the stage-1 menu boots an
imported tree **without** `rd.freshroot` and labels it "NO CEREMONY"
(read-only root, no discard-on-reboot).

What the stage-1 menu expects from a foreign lineage:

- **Capability marker**: `/usr/lib/freshroot/ceremony` inside the tree
  (content: the ceremony version, currently `1`). Trees containing the
  90freshroot dracut module are recognized without the marker.
- **Kernels**: none in the tree. Every snapshot boots with a UKI from the
  shared store, whose initramfs is built from the *newest* snapshot's
  userspace — a foreign distro therefore boots only if that initramfs can
  handle its root (the dracut module and a matching `/etc/fstab` are what
  matter). Module trees the import brings along are shadowed by the
  `@modules` mount.
- **Unlock parameters**: entries get the host's dracut-style
  `rd.luks.uuid=<uuid> rd.luks.name=<uuid>=<name>` appended. If the
  distro's initramfs unlocks differently, ship a single-line
  `/etc/freshroot/cmdline` in the tree — it **replaces** the `rd.luks.*`
  parameters for that tree's entries.

`--import` bakes the host's persistent machine-id into the tree (the
snapshot is re-cloned every boot, so an unbaked machine-id would be minted
fresh each boot) and generates a minimal fstab (`/`, `/boot`, `/boot/efi`,
`/usr/lib/modules`, `/usr/lib/firmware`, `/home`, `/var/log`, swap); the
host's remaining Ubuntu-shaped state-dir mounts (`@gdm3`, `@snap`, …) are
written commented-out so you map them to the foreign distro's paths
deliberately. Package staging (`freshroot-update` runs `apt` inside nspawn)
is Ubuntu/Debian-shaped; for other package managers use
`freshroot-update --lineage <name> --shell` and drive the distro's tooling
by hand.

## Migrating from immutable-ubuntu

See [migrate.sh](migrate.sh) for the full upgrade path. In short: disable the old `immutable-update.timer`, `apt purge immutable-ubuntu`, install the new `freshroot` deb, port your config from `/etc/immutable-update.conf` to `/etc/freshroot-update.conf`, then follow *Migrating an existing install to the stage-1 boot menu* above.

## Important notes

- **Persistent data** (home directories, logs, apt cache, etc.) lives on separate btrfs subvolumes mounted independently via `/etc/fstab`. The update script and dracut module only touch `@rootfs`, `@staging`, and the snapshot directory; `freshroot-kernel` only touches the kernel store, `@kernelstage` and the ESP.
- **Post-update scripts must be idempotent.** Each repo's `install.sh` runs on every update cycle against the latest snapshot, not against a running system.
- **`rd.freshroot` kernel parameter** is the gate. The stage-1 menu adds it to every snapshot entry and omits it for the tainted `@` entry, which boots normally (the `@` subvolume serves as the tainted/recovery root).
- **On upgrades** (`apt upgrade freshroot` inside staging), nothing touches the boot path: the tools rebuild the store UKIs after the commit (`freshroot-kernel rebuild --if-stale`), and stage 1 is refreshed only when you run `freshroot-kernel stage1 --install`.
- **Dracut replaces initramfs-tools.** The package declares `Conflicts: initramfs-tools` so dpkg handles the swap.
- **Migration window:** after the new freshroot lands in a snapshot but before you reboot into it, the *running* (old) tools keep committing snapshots — harmless. The `@` subvolume keeps the install-time tooling forever, so tainted-boot updates run old code; refresh `@` (tainted boot + `apt install ./freshroot_*.deb`) before relying on updates from a tainted boot.
- **`@base` and release switches:** `freshroot-build`'s pinned `@base` stays on its original release. After switching lineages, reseed it (`btrfs subvolume delete <toplevel>/@base`, then `freshroot-build --init-base --from @snapshots/<new-lineage snapshot>`); the build tool warns when `@base`'s lineage differs from the booted one.
- **One initramfs per kernel, built from the newest snapshot.** A store UKI's initramfs comes from the newest snapshot at build time, whichever lineage it belongs to. On a multi-lineage machine the initramfs userspace may therefore be a release ahead of an older lineage it boots — fine for Ubuntu-to-Ubuntu, worth checking for foreign lineages.
- **`refusing to commit — the kernel store is empty`** means no UKI in `@modules/.freshroot/uki/` has a matching module tree. Run `freshroot-kernel add` or `adopt`; the retained `@staging` is reused by the next run.
- **Stage 1 ages on its own.** It embeds one kernel; `freshroot-kernel stage1 --install` rebuilds it on the newest store kernel whenever you want it to move. The ESP is a single point of failure: the previous stage 1 is kept as `freshroot-stage1-prev.efi`, and the `EFI/BOOT/BOOTX64.EFI` fallback is claimed only when free.
- **Removing a lineage** (`freshroot-install --remove`) leaves one thing to clean up: its `LINEAGE_QUOTAS` entry in the conffile (printed as a reminder). Kernels are lineage-independent.
