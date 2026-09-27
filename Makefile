PACKAGE  := freshroot
SRCDIR   := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
VERSION  := $(shell dpkg-parsechangelog -l $(SRCDIR)/debian/changelog -S Version)
DEB      := target/$(PACKAGE)_$(VERSION)_all.deb
SETUP    := target/freshroot-setup

SCRIPTS  := data/usr/sbin/freshroot-update \
            data/usr/sbin/freshroot-build \
            data/usr/sbin/freshroot-install \
            data/usr/sbin/freshroot-kernel \
            installer/freshroot-setup \
            data/usr/lib/dracut/modules.d/90freshroot/module-setup.sh \
            data/usr/lib/dracut/modules.d/90freshroot/freshroot-setup.sh \
            data/usr/lib/dracut/modules.d/90freshroot/freshroot-generator \
            data/usr/lib/dracut/modules.d/90freshroot-stage1/module-setup.sh \
            data/usr/lib/dracut/modules.d/90freshroot-stage1/freshroot-menu.sh \
            data/usr/lib/dracut/modules.d/90freshroot-stage1/freshroot-menu-lib.sh \
            test/pe-unit.sh \
            test/menu-unit.sh \
            test/kernel-unit.sh \
            test/sign-unit.sh \
            test/rig/build-image.sh \
            test/rig/run-qemu.sh
# dracut hooks are sourced by dracut's /bin/sh init — checked in sh dialect
SH_HOOKS  := data/usr/lib/dracut/modules.d/90freshroot-stage1/parse-freshroot-menu.sh \
            data/usr/lib/dracut/modules.d/90freshroot-stage1/mount-freshroot-menu.sh

.PHONY: build clean lint unit rig-image rig-run rig-test rig-clean

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
	bash test/kernel-unit.sh
	bash test/sign-unit.sh
	python3 -m py_compile test/rig/e2e.py

# QEMU end-to-end rig (root, loop devices, device-mapper, QEMU+OVMF;
# skips itself with exit 77 where the environment cannot support it)
rig-image:
	test/rig/build-image.sh

rig-run:
	test/rig/run-qemu.sh

rig-test:
	cd test/rig && python3 e2e.py

rig-clean:
	rm -f test/rig/disk.img test/rig/vars-sb.fd test/rig/serial-*.log
	rm -rf test/rig/sb test/rig/__pycache__

clean:
	rm -rf target
	rm -f debian/debhelper-build-stamp debian/files
	rm -rf debian/.debhelper debian/$(PACKAGE)
	rm -f debian/*.substvars debian/*.log debian/*.debhelper
