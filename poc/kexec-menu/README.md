# kexec-menu PoC — GRUB-less freshroot boot via a minimal stage-1 UKI

A proof of concept for replacing freshroot's GRUB + unencrypted-`/boot`
boot path with a single **stage-1 UKI** on the ESP that:

1. **unlocks the LUKS2 volume first** (passphrase prompt; keyfile hook for
   automated tests),
2. mounts the btrfs top-level read-only and **presents the freshroot menu
   from live state** — lineages, snapshot history, tainted `@` — no
   generated `grub.cfg`, no `update-grub`,
3. **kexecs into the chosen snapshot's own kernel** — `vmlinuz` + `initrd`
   live **inside each snapshot's `/boot`**, encrypted and frozen by the
   snapshot's read-only-ness. A keyfile cpio appended to the target initrd
   lets stage 2 re-unlock LUKS without a second prompt.

Stage 2 is entirely unchanged: the menu constructs the same cmdline GRUB
emits today (`root=UUID=… ro rootflags=subvol=@snapshots/<name>
rd.luks.uuid=… rd.luks.name=… rd.freshroot=1`), so the existing
`90freshroot` dracut module does its `@rootfs` ceremony as always.

This is the ZFSBootMenu pattern (also Red Hat's "nmbl" direction) applied
to freshroot. Rejected alternative for the record: systemd-boot with BLS
entries avoids kexec but requires kernels on the unencrypted ESP —
defeating the fully-encrypted-kernels goal.

**Why this shape matters for freshroot:** once kernels are frozen inside
each read-only snapshot, the whole shared-`/boot` problem class disappears
by construction — the apt-hold scheme, the `/boot/freshroot/<name>/`
hardlink-archive corpus, flat-name lifecycle coupling. A snapshot *is* its
kernel. At integration time the archive corpus becomes deletable.

## Layout

```
build-stage1.sh                  build the stage-1 initramfs + UKI inside a guest tree's chroot
dracut-module/90freshroot-menu/  stage-1 dracut module
  module-setup.sh                  hooks + binaries + kernel drivers
  parse-freshroot-menu.sh          cmdline hook 91: root=freshroot -> rootok=1
  mount-freshroot-menu.sh          mount hook 98: hand over to the menu
  freshroot-menu.sh                the menu program (/bin/freshroot-menu)
  freshroot-menu-lib.sh            SYNC copy of the 06_freshroot lineage helpers
fixture/build-image.sh           build the disposable QEMU disk image
run-qemu.sh                      OVMF + serial-stdio QEMU wrapper
test/e2e.py                      pexpect scenarios A/B/C (see below)
```

The stage-1 initramfs is built **non-systemd** (dracut `--omit "systemd
systemd-initrd dracut-systemd …"`, ZFSBootMenu-style): stage 1 never hands
control to an init — it ends in `kexec -e` — and a plain bash menu owning
`/dev/console` beats fighting systemd's password agents for it.

## Running it

```
make check    # shellcheck + menu-logic unit tests — runs anywhere, no root
sudo make image   # build disk.img (root, loop devices, device-mapper, network, ~12 GB)
make run      # interactive serial console (passphrase: freshroot-test)
make test     # scenarios A/B/C via pexpect (pip install -r test/requirements.txt)
```

`test/menu-unit.sh` exercises the menu's decision logic (snapshot indexing,
lineage ordering, default-entry walk, in-tree kernel pairing) against a
directory fixture with `btrfs` stubbed — no root or btrfs needed.

Degradation ladder:

| Missing               | Effect |
|-----------------------|--------|
| KVM (`/dev/kvm`)      | TCG emulation — works, slow; e2e multiplies timeouts (`FRESHROOT_TCG_MULT`, default 8) |
| root / loop devices   | `make image` exits 77 (skip) with a message |
| device-mapper (`dm_mod`) | `make image` exits 77 — sandboxed containers usually can't open LUKS |
| everything            | `make check` still lints and unit-tests the PoC |

The fixture: GPT (512 MB ESP + LUKS2/btrfs), subvols `@ @home @log @tmp
@snapshots`, a minimal noble tree (mmdebstrap, debootstrap fallback) with
`linux-image-virtual` installed **with `/boot` as a plain directory** — the
kernel image is dpkg payload and the dracut kernel postinst hook writes the
initrd, so both land in-tree; the build asserts this and that the stage-2
initrd contains `freshroot-setup.sh`. Two read-only snapshots
(`…20260820T120000`, then `/etc/fixture-marker` = `second`,
`…20260822T090000`) make the boots distinguishable. LUKS uses a
deliberately weak PBKDF (fast unlock under TCG) — **test fixture only**.
Default-lineage state lives at `<btrfs top-level>/freshroot-state/
default-lineage` (no ext4 `/boot` exists to hold it).

### e2e scenarios

- **A — default path**: passphrase → menu shows the newest snapshot as
  `[default]` → countdown expires → **no second passphrase prompt**
  (proves the keyfile handoff) → `/` is `subvol=/@rootfs`, cmdline carries
  the chosen snapshot + `rd.freshroot=1`, marker says `second`, fstab was
  rewritten by stage 2.
- **B — selection**: interrupt the countdown, pick entry 2 → the older
  snapshot boots (marker absent).
- **C — tainted**: `t` → boots `@` directly: no `rd.freshroot`, both
  `systemd.mask=freshroot-update.*` args present.

An emergency shell instead of `login:` is a hard fail; on timeout the
driver dumps the last 200 serial lines.

## Key mechanics

- **Keyfile handoff**: stage 1 unlocks with `printf '%s' "$PASS" |
  cryptsetup open --key-file=-`, so the bytes proven to unlock are byte-
  identical to the keyfile handed to stage 2 (cryptsetup keyfiles are
  verbatim — a trailing newline would become part of the passphrase). The
  keyfile is packed as a newc cpio, NUL-padded to 4 bytes, and concatenated
  onto the target initrd — the kernel's initramfs unpacker processes
  concatenated segments (same mechanism as early-microcode cpio). Stage 2's
  `systemd-cryptsetup-generator` picks it up via
  `rd.luks.key=/freshroot-luks.key` (plain-path form parses identically
  under dracut's and systemd's syntax); on failure it falls back to a
  prompt. If a second prompt appears despite a good keyfile, add
  `rd.luks.crypttab=0` to the constructed cmdline (initrd-embedded crypttab
  taking precedence).
- **kexec**: `kexec -s` (`kexec_file_load` — the right default for a
  Secure-Boot future) with legacy `kexec -l` fallback. Both copy segments
  into kernel memory at load time, so the merged initrd and keyfile are
  shredded after load, before `kexec -e`.

## Security caveats (PoC-accepted)

Passphrase bytes exist: in stage-1 shell memory; in the merged initrd until
shredded post-load; in the loaded kernel segments; in the stage-2 initramfs
until switch-root; and in un-scrubbed old RAM across kexec. Same exposure
class as any keyfile-in-initrd setup. Nothing key-related ever touches
persistent storage (top-level is mounted `ro`; staging files live in
initramfs RAM).

## Risks / limits recorded for integration

1. **kexec on real hardware**: GPU/firmware handoff (amdgpu, NVIDIA GSP,
   some NVMe/NICs behind IOMMU) is invisible in QEMU; stage 1 stays
   serial/efifb-only (`nomodeset` as belt-and-braces); a metal test matrix
   is required before productizing.
2. **Double-boot latency** (+3–8 s expected): one extra minimal kernel
   init; hostonly stage-2 initrds are the eventual fix.
3. **Secure Boot / lockdown (deferred)**: under lockdown `kexec_file_load`
   verifies target-kernel signatures (Ubuntu-signed kernels pass; custom
   kernels need MOK), `kexec_load` is blocked, and the stage-1 UKI itself
   would be MOK-signed.
4. **Hibernate is incompatible** as designed (stage 1 omits dracut's
   `resume` on purpose); long-term: detect a swap resume signature and
   refuse or chain.
5. **dracut's non-systemd path** is unexercised by Ubuntu and deprecating
   upstream (dracut-ng). Fallback design: a systemd stage 1 with the menu
   as a `Type=oneshot` service `Before=initrd.target` on the console.
6. **Baked stage-1 cmdline** (`console=`, timeout) is per-machine;
   production wants sd-stub addons or a per-host UKI rebuild.
7. **PoC menu limitations**: snapshots without a parseable timestamp
   (e.g. hand-made `root.golden`) are not listed; no per-snapshot kernel
   submenu (newest bootable pair only); `unknown`-lineage trees list but
   sort last.
8. **Eventual deb integration** (out of scope here): drop the `/boot` /
   `/boot/efi` staging bind mounts in `freshroot-update`, `freshroot-build`
   and `freshroot-install` so kernels land in-tree; retire the kernel-
   archive corpus in all three tools; replace `06_freshroot` + GRUB
   defaults with a UKI refresh step; installer Phases 4/10; `debian/control`
   + `postinst` (grub deps → `systemd-ukify`, `kexec-tools`); promote
   `freshroot-state` to a proper `@state` subvolume with `default-lineage`
   dual-written during any transition.
