# for syntax checks
BASH_SCRIPTS = ./templates-ce/scripts/main.sh ./templates-ce/scripts/includes/* ./build_iso.sh ./build_templates.sh

all: build

build:
	@echo -n "Downloading deployment.sh scripts"; \
	wget -r --directory-prefix=./templates-ce/scripts/includes/netscript/ --reject "index.html*" \
	--no-parent --no-host-directories --cut-dirs=1 "http://deb.sipwise.com/netscript/" ; \
	echo " done.";
	@echo -n "Downloading Sipwise keyring 'sipwise.gpg'"; \
	wget -O ./templates-ce/scripts/includes/sipwise.gpg https://deb.sipwise.com/spce/sipwise.gpg ;\
	echo " done.";

syntaxcheck: shellcheck

shellcheck:
	@echo -n "Checking for shell syntax errors"; \
	for SCRIPT in $(BASH_SCRIPTS); do \
	        test -r $${SCRIPT} || continue ; \
	        bash -n $${SCRIPT} || exit ; \
	        echo -n "."; \
	done; \
	echo " done."; \

clean:
	rm -f templates-ce/boot/grub/sipwise_latest.cfg templates-ce/boot/grub/sipwise_lts.cfg \
	  templates-ce/boot/isolinux/sipwise_latest.cfg templates-ce/boot/isolinux/sipwise_lts.cfg
	rm -f templates-ce/boot/isolinux/syslinux.cfg
	rm -f templates/boot/grub/sipwise_latest.cfg templates/boot/grub/sipwise_lts.cfg \
	  templates/boot/isolinux/sipwise_latest.cfg templates/boot/isolinux/sipwise_lts.cfg
	rm -f templates/boot/isolinux/syslinux.cfg
	rm -rf templates-ce/scripts/includes/netscript
	rm -f templates-ce/scripts/includes/sipwise.gpg

dist-clean: clean
	rm -rf artifacts

.PHONY: clean dist-clean syntaxcheck build all
