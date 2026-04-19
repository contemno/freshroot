# 1. Disable the old timer so it can't fire mid-upgrade
systemctl disable --now immutable-update.timer

# 2. Purge old package (removes its conffiles + systemd units)
apt purge immutable-ubuntu

# 3. Install new package
apt install ./target/freshroot_0.1.1~test7_all.deb

# 4. Sanity check: confirm new units/files in place
ls /etc/freshroot-update.conf /etc/grub.d/06_freshroot
ls /usr/lib/dracut/modules.d/90freshroot/
systemctl status freshroot-update.timer

# 5. Edit your config (REPOS, EDITION, BIND_MOUNTS)
sudoedit /etc/freshroot-update.conf

# 6. Regenerate initramfs + GRUB so new rd.freshroot entries appear
dracut --regenerate-all --force
update-grub

# 7. Verify GRUB has Freshroot entries with rd.freshroot
grep -E 'Freshroot|rd\.freshroot' /boot/grub/grub.cfg | head

# 8. Reboot — pick a Freshroot entry from the menu
reboot