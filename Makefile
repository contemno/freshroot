PACKAGE := dracut-luks
VERSION := $(shell dpkg-parsechangelog -l debian/changelog -S Version)
DEB     := target/$(PACKAGE)_$(VERSION)_all.deb

SCRIPTS := data/usr/sbin/dracut-luks-setup tests/discovery.sh

# Sourced fragments, not standalone scripts: check them as sh/bash without
# complaining about the variables their caller provides.
SOURCED_SH   := data/usr/lib/dracut-luks/discover.sh \
                data/etc/default/grub.d/99-dracut-luks.cfg
SOURCED_BASH := data/etc/dracut.conf.d/10-luks.conf \
                data/etc/dracut.conf.d/20-luks-tokens.conf

.PHONY: build lint test install clean

build: $(DEB)

$(DEB):
	dpkg-buildpackage -us -uc -b
	mkdir -p target
	mv ../$(PACKAGE)_$(VERSION)_all.deb target/
	mv ../$(PACKAGE)_$(VERSION)_*.buildinfo target/ 2>/dev/null || true
	mv ../$(PACKAGE)_$(VERSION)_*.changes target/ 2>/dev/null || true

lint:
	shellcheck -s bash -e SC1091 $(SCRIPTS)
	shellcheck -s sh -e SC2034,SC1091 $(SOURCED_SH)
	shellcheck -s bash -e SC2034,SC2154 $(SOURCED_BASH)

test:
	./tests/discovery.sh

install:
	install -d $(DESTDIR)/usr/sbin $(DESTDIR)/usr/lib/dracut-luks \
	           $(DESTDIR)/etc/dracut.conf.d $(DESTDIR)/etc/default/grub.d
	install -m 0755 data/usr/sbin/dracut-luks-setup $(DESTDIR)/usr/sbin/
	install -m 0644 data/usr/lib/dracut-luks/discover.sh $(DESTDIR)/usr/lib/dracut-luks/
	install -m 0644 data/etc/dracut.conf.d/*.conf $(DESTDIR)/etc/dracut.conf.d/
	install -m 0644 data/etc/default/grub.d/*.cfg $(DESTDIR)/etc/default/grub.d/

clean:
	rm -rf target
	rm -f debian/debhelper-build-stamp debian/files
	rm -rf debian/.debhelper debian/$(PACKAGE)
	rm -f debian/*.substvars debian/*.log
