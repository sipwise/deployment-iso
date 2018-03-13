# for syntax checks
BASH_SCRIPTS = ./templates/scripts/main.sh ./templates/scripts/includes/* ./build_iso.sh ./build_templates.sh

all: build

build:
	@echo -n "Downloading deployment.sh scripts"; \
	wget -r --directory-prefix=./templates/scripts/includes/netscript/ --reject "index.html*" \
	--no-parent --no-host-directories --cut-dirs=1 "http://deb.sipwise.com/netscript/" ; \
	echo " done.";
	@echo -n "Downloading Sipwise keyring 'sipwise.gpg'"; \
	wget -O ./templates/scripts/includes/sipwise.gpg https://deb.sipwise.com/spce/sipwise.gpg ;\
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
	rm -f templates/boot/grub/sipwise_*.cfg templates/boot/isolinux/sipwise_*.cfg
	rm -f templatese/boot/isolinux/syslinux.cfg
	rm -f templates/boot/grub/sipwise_*.cfg templates/boot/isolinux/sipwise_*.cfg
	rm -f templates/boot/isolinux/syslinux.cfg
	rm -rf templates/scripts/includes/netscript
	rm -f templates/scripts/includes/sipwise.gpg

dist-clean: clean
	rm -rf artifacts

.PHONY: clean dist-clean syntaxcheck build all
