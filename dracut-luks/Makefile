PREFIX  ?= /usr
SBINDIR ?= $(PREFIX)/sbin

SCRIPTS := dracut-luks-setup tests/discovery.sh

.PHONY: lint test install clean

lint:
	shellcheck -s bash $(SCRIPTS)

test:
	./tests/discovery.sh

install:
	install -d $(DESTDIR)$(SBINDIR)
	install -m 0755 dracut-luks-setup $(DESTDIR)$(SBINDIR)/dracut-luks-setup

clean:
	@:
