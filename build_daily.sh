#!/bin/bash
DATE="$(date +%Y%m%d)"
SIPWISE_ISO="grml64-sipwise-daily_${DATE}.iso"

echo "*** Retrieving Grml Daily ISO ***"
wget --timeout=30 -q -c -O grml64-full_testing_latest.iso http://daily.grml.org/grml64-full_testing/latest/grml64-full_testing_latest.iso

# identify ISO version (build time might not necessarily match ISO date)
ISO_DATE=$(isoinfo -d -i grml64-full_testing_latest.iso | awk '/^Volume id:/ {print $4}')
if [ -z "$ISO_DATE" ] ; then echo "ISO_DATE not identified, exiting." >&2 ; exit 1 ; fi
GRML_ISO="grml64-full_testing_${ISO_DATE}.iso"

mv grml64-full_testing_latest.iso "${GRML_ISO}"

wget --timeout=30 -O grml64-full_testing_latest.iso.sha1 http://daily.grml.org/grml64-full_testing/latest/grml64-full_testing_latest.iso.sha1
sha1sum -c grml64-full_testing_latest.iso.sha1

# make sure syslinux.cfg is same as isolinux.cfg so grml2usb works also
echo "*** Copying isolinux.cfg to syslinux.cfg for grml2usb support ***"
cp ./source/templates/boot/isolinux/isolinux.cfg ./source/templates/boot/isolinux/syslinux.cfg

# build grub.cfg release options
TEMPLATE=templates MR=yes PUBLIC="no" ./source/build.sh

echo "*** Generating Sipwise ISO ***"
sudo /usr/sbin/grml2iso -c ./source/templates -o "${SIPWISE_ISO}" "${GRML_ISO}"

echo "*** Generating dd-able ISO ***"
sudo /usr/bin/isohybrid "${SIPWISE_ISO}"

echo "*** Calculating checksum file ***"
sha1sum "${SIPWISE_ISO}" > "${SIPWISE_ISO}.sha1"

mkdir artifacts
mv "${SIPWISE_ISO}" ${SIPWISE_ISO}.sha1 artifacts/
