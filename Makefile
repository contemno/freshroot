PACKAGE  := freshroot
SRCDIR   := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
VERSION  := $(shell dpkg-parsechangelog -l $(SRCDIR)/debian/changelog -S Version)
DEB      := target/$(PACKAGE)_$(VERSION)_all.deb
SETUP    := target/freshroot-setup

SCRIPTS  := data/usr/sbin/freshroot-update \
            installer/freshroot-setup \
            data/usr/lib/dracut/modules.d/90freshroot/module-setup.sh \
            data/usr/lib/dracut/modules.d/90freshroot/freshroot-setup.sh \
            data/usr/lib/dracut/modules.d/90freshroot/freshroot-generator \
            data/etc/grub.d/06_freshroot

.PHONY: build clean lint

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
	shellcheck -s bash $(SCRIPTS)

clean:
	rm -rf target
	rm -f debian/debhelper-build-stamp debian/files
	rm -rf debian/.debhelper debian/$(PACKAGE)
	rm -f debian/*.substvars debian/*.log
