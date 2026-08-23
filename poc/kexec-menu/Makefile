# kexec-menu PoC. `check` runs anywhere (CI-safe); the rest need root, loop
# devices, network, QEMU+OVMF, and ideally KVM — see README.md.

BASH_SCRIPTS := build-stage1.sh run-qemu.sh fixture/build-image.sh \
                dracut-module/90freshroot-menu/module-setup.sh \
                dracut-module/90freshroot-menu/freshroot-menu.sh \
                dracut-module/90freshroot-menu/freshroot-menu-lib.sh
SH_SCRIPTS   := dracut-module/90freshroot-menu/parse-freshroot-menu.sh \
                dracut-module/90freshroot-menu/mount-freshroot-menu.sh

.PHONY: check image run test clean

check:
	shellcheck -s bash -x $(BASH_SCRIPTS) test/menu-unit.sh
	shellcheck -s sh $(SH_SCRIPTS)
	python3 -m py_compile test/e2e.py
	bash test/menu-unit.sh

image:
	./fixture/build-image.sh

run: disk.img
	./run-qemu.sh

test: disk.img
	python3 test/e2e.py

disk.img:
	@echo "no disk.img — run 'make image' first (needs root)"; exit 1

clean:
	rm -f disk.img freshroot-menu.efi serial-*.log
	rm -rf test/__pycache__
