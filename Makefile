# for syntax checks
BASH_SCRIPTS = ./templates/scripts/main.sh ./templates/scripts/includes/* ./build_iso.sh ./build_templates.sh
NGCP_VERSION ?= $(shell git log --pretty=format:"%h" -1)
NGCP_VERSION := $(strip $(NGCP_VERSION))

all: build

build:
	 $(MAKE) -C src

syntaxcheck: shellcheck

shellcheck:
	@echo -n "Checking for shell syntax errors"; \
	for SCRIPT in $(BASH_SCRIPTS); do \
		test -r $${SCRIPT} || continue ; \
		bash -n $${SCRIPT} || exit ; \
		echo -n "."; \
	done; \
	echo " done."; \

script_version:
	echo "Adjust version information string in deployment.sh to ${NGCP_VERSION}"
	sed -i "s/SCRIPT_VERSION=\"%SCRIPT_VERSION%\"/SCRIPT_VERSION=${NGCP_VERSION}/" \
		templates/scripts/includes/deployment.sh

clean:
	rm -f templates/boot/isolinux/syslinux.cfg
	rm -f templates/boot/grub/grub.cfg
	rm -f templates/boot/isolinux/isolinux.cfg
	$(MAKE) -C src $@

dist-clean: clean
	rm -rf artifacts
	rm -f *.iso
	rm -f *.iso.sha1
	rm -rf grml_build/grml_cd
	rm -rf grml_build/grml_chroot
	rm -rf grml_build/grml_isos
	rm -rf grml_build/grml_logs
	rm -rf grml_build/netboot
	rm -f fake-uname.so

.PHONY: clean dist-clean syntaxcheck shellcheck build all script_version
