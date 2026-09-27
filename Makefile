PACKAGE  := freshroot
SRCDIR   := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
VERSION  := $(shell dpkg-parsechangelog -l $(SRCDIR)/debian/changelog -S Version)
DEB      := target/$(PACKAGE)_$(VERSION)_all.deb
SETUP    := target/freshroot-setup

SCRIPTS  := data/usr/sbin/freshroot-update \
            data/usr/sbin/freshroot-build \
            data/usr/sbin/freshroot-install \
            installer/freshroot-setup \
            data/usr/lib/dracut/modules.d/90freshroot/module-setup.sh \
            data/usr/lib/dracut/modules.d/90freshroot/freshroot-setup.sh \
            data/usr/lib/dracut/modules.d/90freshroot/freshroot-generator \
            data/usr/lib/dracut/modules.d/90freshroot-stage1/module-setup.sh \
            data/usr/lib/dracut/modules.d/90freshroot-stage1/freshroot-menu.sh \
            data/usr/lib/dracut/modules.d/90freshroot-stage1/freshroot-menu-lib.sh \
            data/etc/grub.d/06_freshroot \
            test/pe-unit.sh \
            test/menu-unit.sh
# dracut hooks are sourced by dracut's /bin/sh init — checked in sh dialect
SH_HOOKS  := data/usr/lib/dracut/modules.d/90freshroot-stage1/parse-freshroot-menu.sh \
            data/usr/lib/dracut/modules.d/90freshroot-stage1/mount-freshroot-menu.sh

.PHONY: build clean lint unit

build: $(DEB) $(SETUP)

$(DEB):
	dpkg-buildpackage -us -uc -b
	mkdir -p target
	mv ../$(PACKAGE)_$(VERSION)_all.deb target/
	mv ../$(PACKAGE)_$(VERSION)_*.buildinfo target/ 2>/dev/null || true
	mv ../$(PACKAGE)_$(VERSION)_*.changes target/ 2>/dev/null || true

$(SETUP): installer/freshroot-setup
	mkdir -p target
	install -m 0755 installer/freshroot-setup $(SETUP)

lint:
	shellcheck -s bash -x $(SCRIPTS)
	shellcheck -s sh $(SH_HOOKS)

# Unit tests that need no root, btrfs or QEMU (ukify/sbsign checks run when
# the tools are installed and are skipped otherwise)
unit:
	bash test/pe-unit.sh
	bash test/menu-unit.sh

clean:
	rm -rf target
	rm -f debian/debhelper-build-stamp debian/files
	rm -rf debian/.debhelper debian/$(PACKAGE)
	rm -f debian/*.substvars debian/*.log
