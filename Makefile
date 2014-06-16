# for syntax checks
BASH_SCRIPTS = ./templates-ce/scripts/main.sh ./templates-ce/scripts/includes/* ./build_iso.sh ./build_templates.sh

VERSION=$(shell git log --pretty=format:"%h" -1 ./templates-ce/scripts/includes/deployment.sh)

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
	echo "Adjust version information string in ./templates-ce/scripts/includes/deployment.sh.sh to ${VERSION}"
	sed -i "s/SCRIPT_VERSION=\"%SCRIPT_VERSION%\"/SCRIPT_VERSION=${VERSION}/" ./templates-ce/scripts/includes/deployment.sh

clean:
	rm -f templates-ce/boot/grub/sipwise_latest.cfg templates-ce/boot/grub/sipwise_lts.cfg \
	  templates-ce/boot/isolinux/sipwise_latest.cfg templates-ce/boot/isolinux/sipwise_lts.cfg
	rm -f templates-ce/boot/isolinux/syslinux.cfg
	rm -f templates/boot/grub/sipwise_latest.cfg templates/boot/grub/sipwise_lts.cfg \
	  templates/boot/isolinux/sipwise_latest.cfg templates/boot/isolinux/sipwise_lts.cfg
	rm -f templates/boot/isolinux/syslinux.cfg

dist-clean: clean
	rm -rf artifacts

.PHONY: clean dist-clean syntaxcheck script_version
