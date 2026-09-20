#!/bin/sh
# mount hook 98: hand the boot over to the freshroot menu. By this point
# udev has triggered and settled, so block devices exist. On the happy path
# the menu never returns (kexec -e); if it does return, fall through so
# dracut's init reaches its own emergency handling for root=freshroot.

# shellcheck disable=SC2154  # root is assigned by dracut's init (parse-root-opts)
case "$root" in
    freshroot)
        /bin/freshroot-menu
        echo "freshroot-menu returned — falling through to dracut error handling" >&2
        ;;
esac
