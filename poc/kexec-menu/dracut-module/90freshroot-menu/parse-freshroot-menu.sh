#!/bin/sh
# cmdline hook 91: legitimize the synthetic root=freshroot so dracut's base
# init proceeds to the mount hooks instead of dropping to emergency for lack
# of a root device. No device is registered with the initqueue — the menu
# (mount hook 98) does its own bounded wait after udev has settled. The menu
# must NOT run here: udev has not triggered yet, disks do not exist.

# shellcheck disable=SC2154  # root is assigned by dracut's init (parse-root-opts)
case "$root" in
    freshroot)
        # shellcheck disable=SC2034  # rootok is read by dracut's init
        rootok=1
        ;;
esac
