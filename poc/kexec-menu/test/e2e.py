#!/usr/bin/env python3
"""End-to-end scenarios for the kexec-menu PoC, driven over the QEMU serial
console with pexpect.

Scenarios:
  A  default path : passphrase -> countdown expires -> newest snapshot boots
                    via kexec with NO second passphrase prompt (keyfile
                    handoff), lands on @rootfs cloned from SNAP_NEW.
  B  selection    : interrupt the countdown, pick the older snapshot.
  C  tainted      : boot @ directly (no rd.freshroot, update units masked).

Run from poc/kexec-menu/:  python3 test/e2e.py [A B C]
Needs: the fixture image (make image) and QEMU+OVMF on the host.
Serial logs land in serial-<scenario>.log next to the disk image.
"""

import os
import re
import sys
import time

import pexpect

HERE = os.path.dirname(os.path.abspath(__file__))
POC = os.path.dirname(HERE)

CONF = {}
with open(os.path.join(POC, "fixture", "fixture.conf")) as f:
    for line in f:
        m = re.match(r'^([A-Z_]+)="?([^"#]*)"?\s*$', line.strip())
        if m:
            CONF[m.group(1)] = m.group(2).strip()

PASSPHRASE = CONF["PASSPHRASE"]
ROOT_PASSWORD = CONF["ROOT_PASSWORD"]
SNAP_OLD = CONF["SNAP_OLD"]
SNAP_NEW = CONF["SNAP_NEW"]

# TCG (no /dev/kvm) boots the kernel twice at emulated speed — stretch every
# timeout. Override with FRESHROOT_TCG_MULT.
MULT = int(os.environ.get(
    "FRESHROOT_TCG_MULT",
    "1" if os.access("/dev/kvm", os.R_OK | os.W_OK) else "8"))

T_PROMPT = 300 * MULT   # firmware + stage-1 kernel + udev to the passphrase prompt
T_MENU = 60 * MULT
T_LOGIN = 300 * MULT    # kexec + stage-2 kernel + ceremony + getty
T_CMD = 30 * MULT

PASSPHRASE_RE = r"freshroot: enter passphrase"


class Failure(Exception):
    pass


def spawn(scenario):
    log = open(os.path.join(POC, f"serial-{scenario}.log"), "wb")
    child = pexpect.spawn(
        "bash", [os.path.join(POC, "run-qemu.sh")],
        timeout=T_PROMPT, logfile=log, cwd=POC)
    return child


def expect(child, pattern, timeout, why):
    try:
        child.expect(pattern, timeout=timeout)
    except (pexpect.TIMEOUT, pexpect.EOF) as e:
        tail = child.before or b""
        tail = tail.decode(errors="replace").splitlines()[-200:]
        raise Failure(f"{why}: waiting for {pattern!r} "
                      f"({type(e).__name__})\n--- serial tail ---\n"
                      + "\n".join(tail)) from None


def login(child):
    expect(child, r"login:", T_LOGIN, "no login prompt after kexec")
    child.sendline("root")
    expect(child, r"Password:", T_CMD, "no password prompt")
    child.sendline(ROOT_PASSWORD)
    expect(child, r"[#$] ", T_CMD, "no shell after login")


def run(child, cmd, why):
    """Run a command, return its stdout (between the sentinels)."""
    child.sendline(f"echo BEGIN-E2E; {cmd}; echo END-E2E")
    expect(child, r"BEGIN-E2E\r?\n(.*?)END-E2E", T_CMD, why)
    return child.match.group(1).decode(errors="replace")


def assert_in(needle, hay, why):
    if needle not in hay:
        raise Failure(f"{why}: {needle!r} not found in:\n{hay}")


def assert_not_in(needle, hay, why):
    if needle in hay:
        raise Failure(f"{why}: {needle!r} unexpectedly present in:\n{hay}")


def common_asserts(child, snapshot, expect_freshroot):
    cmdline = run(child, "cat /proc/cmdline", "read /proc/cmdline")
    if snapshot:
        assert_in(f"rootflags=subvol=@snapshots/{snapshot}", cmdline,
                  "wrong snapshot on cmdline")
    if expect_freshroot:
        assert_in("rd.freshroot=1", cmdline, "ceremony flag missing")
        assert_in("rd.luks.key=/freshroot-luks.key", cmdline,
                  "keyfile handoff arg missing")
        opts = run(child, "findmnt -no OPTIONS /", "findmnt /")
        assert_in("subvol=/@rootfs", opts, "/ is not the ephemeral @rootfs")
        fstab = run(child, "grep -c 'subvol=@rootfs,' /etc/fstab",
                    "check fstab rewrite")
        if fstab.strip() == "0":
            raise Failure("stage-2 fstab rewrite did not run")


def unlock(child):
    expect(child, PASSPHRASE_RE, T_PROMPT, "no stage-1 passphrase prompt")
    child.sendline(PASSPHRASE)


def mark_kexec(child):
    expect(child, r"freshroot-menu: executing kexec", T_MENU,
           "menu did not reach kexec")


def no_second_prompt(child):
    """After kexec, reaching login: without another passphrase prompt proves
    the keyfile handoff. pexpect consumes the stream in order, so expecting
    both patterns and failing on the passphrase one is exact."""
    i = child.expect([r"login:", PASSPHRASE_RE], timeout=T_LOGIN)
    if i == 1:
        raise Failure("stage 2 asked for the passphrase again — "
                      "keyfile handoff failed (consider rd.luks.crypttab=0)")


def scenario_a():
    child = spawn("A")
    try:
        unlock(child)
        expect(child, r"freshroot boot menu", T_MENU, "no menu")
        expect(child, re.escape(SNAP_NEW) + r".*\[default\]", T_MENU,
               "newest snapshot is not the default entry")
        mark_kexec(child)          # countdown expires on its own
        no_second_prompt(child)
        child.sendline("root")
        expect(child, r"Password:", T_CMD, "no password prompt")
        child.sendline(ROOT_PASSWORD)
        expect(child, r"[#$] ", T_CMD, "no shell after login")
        common_asserts(child, SNAP_NEW, expect_freshroot=True)
        marker = run(child, "cat /etc/fixture-marker", "read marker")
        assert_in("second", marker, "wrong snapshot content (marker)")
        run(child, "echo FRESHROOT_E2E_PASS", "sentinel")
        child.sendline("systemctl poweroff")
        child.expect(pexpect.EOF, timeout=T_CMD)
    finally:
        child.close(force=True)


def scenario_b():
    child = spawn("B")
    try:
        unlock(child)
        expect(child, r"press any key for menu", T_MENU, "no countdown")
        child.send(" ")            # interrupt the countdown
        expect(child, r"boot: ", T_MENU, "no selection prompt")
        # entry 2 = the older snapshot (default lineage newest-first)
        child.sendline("2")
        mark_kexec(child)
        no_second_prompt(child)
        child.sendline("root")
        expect(child, r"Password:", T_CMD, "no password prompt")
        child.sendline(ROOT_PASSWORD)
        expect(child, r"[#$] ", T_CMD, "no shell after login")
        common_asserts(child, SNAP_OLD, expect_freshroot=True)
        marker = run(child, "ls /etc/fixture-marker 2>&1 || true",
                     "marker absence")
        assert_in("No such file", marker,
                  "old snapshot unexpectedly contains the marker")
        child.sendline("systemctl poweroff")
        child.expect(pexpect.EOF, timeout=T_CMD)
    finally:
        child.close(force=True)


def scenario_c():
    child = spawn("C")
    try:
        unlock(child)
        expect(child, r"press any key for menu", T_MENU, "no countdown")
        child.send(" ")
        expect(child, r"boot: ", T_MENU, "no selection prompt")
        child.sendline("t")
        mark_kexec(child)
        no_second_prompt(child)
        child.sendline("root")
        expect(child, r"Password:", T_CMD, "no password prompt")
        child.sendline(ROOT_PASSWORD)
        expect(child, r"[#$] ", T_CMD, "no shell after login")
        cmdline = run(child, "cat /proc/cmdline", "read /proc/cmdline")
        assert_in("rootflags=subvol=@ ", cmdline + " ", "not booted from @")
        assert_not_in("rd.freshroot", cmdline, "tainted boot carries ceremony flag")
        assert_in("systemd.mask=freshroot-update.service", cmdline,
                  "update service not masked")
        assert_in("systemd.mask=freshroot-update.timer", cmdline,
                  "update timer not masked")
        opts = run(child, "findmnt -no OPTIONS /", "findmnt /")
        assert_in("subvol=/@", opts, "/ not mounted from @")
        assert_not_in("subvol=/@rootfs", opts, "tainted boot used @rootfs")
        child.sendline("systemctl poweroff")
        child.expect(pexpect.EOF, timeout=T_CMD)
    finally:
        child.close(force=True)


SCENARIOS = {"A": scenario_a, "B": scenario_b, "C": scenario_c}


def main():
    picks = sys.argv[1:] or list(SCENARIOS)
    failed = []
    for name in picks:
        print(f"=== scenario {name} (timeout multiplier {MULT}) ===",
              flush=True)
        start = time.time()
        try:
            SCENARIOS[name]()
            print(f"=== scenario {name}: PASS ({time.time()-start:.0f}s) ===",
                  flush=True)
        except Failure as e:
            print(f"=== scenario {name}: FAIL ===\n{e}", flush=True)
            failed.append(name)
    if failed:
        sys.exit(f"failed scenarios: {', '.join(failed)}")
    print("all scenarios passed")


if __name__ == "__main__":
    main()
