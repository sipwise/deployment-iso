#!/bin/bash
DATE="$(date +%Y%m%d)"
SIPWISE_ISO="grml64-sipwise-release_${DATE}.iso"
PUBLIC="${1:-no}"
TEMPLATES="templates"

if [ "${PUBLIC}" != "no" ]; then
	echo "*** Building public ISO ***"
	TEMPLATES="templates-ce"
fi

echo "*** Retrieving Grml Release ISO [${GRML_ISO}] ***"
wget --timeout=30 -q -c -O "$(basename $GRML_ISO)" "http://mirror.inode.at/data/grml/${GRML_ISO}"

echo "*** Checking sha1sum ***"
wget --timeout=30 -q -c -O "$(basename $GRML_ISO).sha1" "http://download.grml.org/${GRML_ISO}.sha1"
sha1sum -c $(basename $GRML_ISO).sha1

# make sure syslinux.cfg is same as isolinux.cfg so grml2usb works also
echo "*** Copying isolinux.cfg to syslinux.cfg for grml2usb support ***"
cp ./source/${TEMPLATES}/boot/isolinux/isolinux.cfg ./source/${TEMPLATES}/boot/isolinux/syslinux.cfg

echo "*** Generating Sipwise ISO ***"
sudo /usr/sbin/grml2iso -c ./source/${TEMPLATES} -o "${SIPWISE_ISO}" "$(basename $GRML_ISO)"

echo "*** Generating dd-able ISO ***"
sudo /usr/bin/isohybrid "${SIPWISE_ISO}"

echo "*** Calculating checksum file ***"
sha1sum "${SIPWISE_ISO}" > "${SIPWISE_ISO}.sha1"

mkdir -p artifacts
mv "${SIPWISE_ISO}" ${SIPWISE_ISO}.sha1 artifacts/
