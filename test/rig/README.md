# QEMU rig for the stage-1 / kernel-store boot model

Builds a disposable disk image that mirrors a freshroot install as the
installer now lays it out — `@modules`/`@firmware` subvolumes, a kernel
handed to the store (`.freshroot/dist` + `.freshroot/uki`), kernel packages
purged and pinned, kernel-free snapshots, the packaged `90freshroot-stage1`
module built into a stage-1 UKI on the ESP, everything signed with test
Secure Boot keys — and drives it over the serial console.

```
make rig-image     # sudo: root, loop devices, device-mapper, network, ~12 GB
make rig-run       # interactive serial console (passphrase: freshroot-test)
make rig-test      # scenarios A B C D F via pexpect (pip install pexpect)
FRESHROOT_TEST_SB=1 ./run-qemu.sh   # boot the Secure Boot firmware by hand
```

| Missing                     | Effect |
|-----------------------------|--------|
| KVM (`/dev/kvm`)            | TCG emulation — works, slow; e2e multiplies timeouts (`FRESHROOT_TCG_MULT`, default 8) |
| root / loop devices / dm    | `build-image.sh` exits 77 (skip) |
| `python3-virt-firmware`     | image builds, but no `vars-sb.fd` — scenario F is skipped |
| OVMF `OVMF_CODE_4M.ms.fd`   | scenario F cannot run (needs the SMM/Secure-Boot build) |

Scenarios: **A** default countdown boot (newest snapshot, newest signed
kernel, no second passphrase prompt, `@rootfs` root, shared modules
mounted, no kernel in the tree); **B** older-snapshot selection; **C**
tainted `@` with the update units masked; **D** the `k` kernel picker
booting the second store entry; **F** Secure Boot with the test keys
enrolled (SecureBoot=1, `[integrity]` lockdown — the signed inner kernel
passed `kexec_file_load`).

An emergency shell instead of `login:` is a hard fail; on timeout the
driver dumps the last 200 serial lines. LUKS uses a deliberately weak
PBKDF (fast unlock under TCG) — test fixture only.
