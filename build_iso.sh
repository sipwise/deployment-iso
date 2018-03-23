#!/bin/bash

set -e

DATE="$(date +%Y%m%d_%H%M%S)"
WGET_OPT="--timeout=30 -q -c"
# First (former RELEASE) parameter isn't used but kept for backward compatibility
_="$1"
GRML_ISO="$2"
MR="$3"
DIST="$4"
TEMPLATES="templates"
GRML_URL="${GRML_URL:-https://deb.sipwise.com/files/grml/}"
GRML_HASH_URL="${GRML_HASH_URL:-http://download.grml.org/}"
SIPWISE_ISO="sip_provider_${MR}_${DATE}.iso"

usage () {
  echo "Usage: $0 compat <grml.iso> <mr version> <Debian dist>"
  echo "Sample: $0 compat 'grml64-full_2014.11.iso' mr6.2.1 stretch"
  exit 1
}

check_sha1 () {
  local _GRML_ISO="$1"
  echo "*** Checking sha1sum of ISO [${_GRML_ISO}] ***"
  sha1sum -c "${_GRML_ISO}.sha1"
}


if [ -z "${MR}" ]; then
  echo "Parameter <mr version> is missing" >&2
  usage
elif [ -z "${DIST}" ]; then
  echo "Parameter <Debian dist> is missing" >&2
  usage
fi

if [ "${GRML_ISO}" != "" ]; then
  if [[ "${GRML_ISO}" =~ ^devel/.*\.iso$ ]]; then
    GRML_URL+="devel/"
    GRML_HASH_URL+="devel/"
  fi
  GRML_ISO=$(basename "${GRML_ISO}")
else
  usage
fi

echo "*** Building ${MR} ISO ***"

echo "*** Retrieving Grml ISO [${GRML_ISO}] ***"
# shellcheck disable=SC2086
wget ${WGET_OPT} -O "${GRML_ISO}" "${GRML_URL}${GRML_ISO}"
# shellcheck disable=SC2086
wget ${WGET_OPT} -O "${GRML_ISO}.sha1" "${GRML_HASH_URL}${GRML_ISO}.sha1"

if grep -q "${GRML_ISO}" "${GRML_ISO}.sha1" ; then
  check_sha1 "${GRML_ISO}"
else
  echo "*** Renaming Grml ISO (from the latest to exact build version) ***"
  # identify ISO version (build time might not necessarily match ISO date)
  ISO_DATE=$(isoinfo -d -i "${GRML_ISO}" | awk '/^Volume id:/ {print $4}')
  if [ -z "${ISO_DATE}" ]; then echo "ISO_DATE not identified, exiting." >&2 ; exit 1 ; fi
  GRML_ISO_DATE="grml64-full_testing_${ISO_DATE}.iso"
  mv "${GRML_ISO}" "${GRML_ISO_DATE}"
  check_sha1 "${GRML_ISO}"
  GRML_ISO="${GRML_ISO_DATE}"
fi

# build grub.cfg release options
echo "*** Building templates [TEMPLATES=${TEMPLATES} MR=${MR}] ***"
TEMPLATES="${TEMPLATES}" MR="${MR}" DIST="${DIST}" ./build_templates.sh

# make sure syslinux.cfg is same as isolinux.cfg so grml2usb works also
echo "*** Copying isolinux.cfg to syslinux.cfg for grml2usb support ***"
cp ${TEMPLATES}/boot/isolinux/isolinux.cfg ${TEMPLATES}/boot/isolinux/syslinux.cfg

echo "*** Generating Sipwise ISO ***"
sudo /usr/sbin/grml2iso -c ./${TEMPLATES} -o "${SIPWISE_ISO}" "${GRML_ISO}"

echo "*** Generating dd-able ISO ***"
sudo /usr/bin/isohybrid "${SIPWISE_ISO}"

sudo implantisomd5 "${SIPWISE_ISO}"

echo "*** Generating SHA1 and MD5 checksum files ***"
sha1sum "${SIPWISE_ISO}" > "${SIPWISE_ISO}.sha1"
md5sum  "${SIPWISE_ISO}" > "${SIPWISE_ISO}.md5"

mkdir -p artifacts
echo "*** Moving ${SIPWISE_ISO} ${SIPWISE_ISO}.sha1 ${SIPWISE_ISO}.md5 to artifacts/ ***"
mv "${SIPWISE_ISO}" "${SIPWISE_ISO}.sha1" "${SIPWISE_ISO}.md5" artifacts/
