#!/bin/bash

set -e

DATE="$(date +%Y%m%d_%H%M%S)"
WGET_OPT="--timeout=30 -q -c"
RELEASE="$1"
GRML_ISO="$2"

usage () {
  echo "Usage: $0 daily|private|public <grml.iso>"
  echo "Sample: $0 'daily' 'grml64-full_testing_latest.iso'"
  exit 1
}

check_sha1 () {
  local _GRML_ISO="$1"
  echo "*** Checking sha1sum of ISO [${_GRML_ISO}] ***"
  sha1sum -c "${_GRML_ISO}.sha1"
}

echo "*** Building ${RELEASE} ISO ***"

case ${RELEASE} in
daily)
  TEMPLATES="templates"
  MR="yes"
  PUBLIC="no"
  SIPWISE_ISO="grml64-sipwise-daily_${DATE}.iso"
  GRML_URL="http://daily.grml.org/grml64-full_testing/latest/"
  GRML_HASH_URL="${GRML_URL}"
  ;;
private)
  TEMPLATES="templates"
  MR="no"
  PUBLIC="no"
  SIPWISE_ISO="grml64-sipwise-release_${DATE}.iso"
  GRML_URL="https://deb.sipwise.com/files/grml/"
  GRML_HASH_URL="https://deb.sipwise.com/files/grml/"
  ;;
public)
  TEMPLATES="templates-ce"
  MR="no"
  PUBLIC="yes"
  SIPWISE_ISO="sip_provider_CE_installcd.iso"
  GRML_URL="https://deb.sipwise.com/files/grml/"
  GRML_HASH_URL="https://deb.sipwise.com/files/grml/"
  ;;
*)
  usage
  ;;
esac

if [ "${GRML_ISO}" != "" ]; then
  if [[ "${GRML_ISO}" =~ ^devel/.*\.iso$ ]]; then
    GRML_URL+="devel/"
    GRML_HASH_URL+="devel/"
  fi
  GRML_ISO=$(basename "${GRML_ISO}")
else
  usage
fi

echo "*** Retrieving Grml ${RELEASE} ISO [${GRML_ISO}] ***"
# shellcheck disable=SC2086
wget ${WGET_OPT} -O "${GRML_ISO}" "${GRML_URL}${GRML_ISO}"
# shellcheck disable=SC2086
wget ${WGET_OPT} -O "${GRML_ISO}.sha1" "${GRML_HASH_URL}${GRML_ISO}.sha1"

if [ "${RELEASE}" = "daily"  ]; then
  echo "*** Renaming Grml ISO (from the latest to exact build version) ***"
  # identify ISO version (build time might not necessarily match ISO date)
  ISO_DATE=$(isoinfo -d -i "${GRML_ISO}" | awk '/^Volume id:/ {print $4}')
  if [ -z "${ISO_DATE}" ] ; then echo "ISO_DATE not identified, exiting." >&2 ; exit 1 ; fi
  GRML_ISO_DATE="grml64-full_testing_${ISO_DATE}.iso"
  mv "${GRML_ISO}" "${GRML_ISO_DATE}"
  check_sha1 "${GRML_ISO}"
  GRML_ISO="${GRML_ISO_DATE}"
else
  check_sha1 "${GRML_ISO}"
fi

# make sure syslinux.cfg is same as isolinux.cfg so grml2usb works also
echo "*** Copying isolinux.cfg to syslinux.cfg for grml2usb support ***"
cp ${TEMPLATES}/boot/isolinux/isolinux.cfg ${TEMPLATES}/boot/isolinux/syslinux.cfg

# build grub.cfg release options
echo "*** Building templates [TEMPLATES=${TEMPLATES} MR=${MR} PUBLIC=${PUBLIC}] ***"
TEMPLATES="${TEMPLATES}" MR="${MR}" PUBLIC="${PUBLIC}" ./build_templates.sh

echo "*** Generating Sipwise ISO ***"
sudo /usr/sbin/grml2iso -c ./${TEMPLATES} -o "${SIPWISE_ISO}" "${GRML_ISO}"

echo "*** Generating dd-able ISO ***"
sudo /usr/bin/isohybrid "${SIPWISE_ISO}"

echo "*** Generating SHA1 and MD5 checksum files ***"
sha1sum "${SIPWISE_ISO}" > "${SIPWISE_ISO}.sha1"
md5sum  "${SIPWISE_ISO}" > "${SIPWISE_ISO}.md5"

mkdir -p artifacts
mv "${SIPWISE_ISO}" ${SIPWISE_ISO}.sha1 ${SIPWISE_ISO}.md5 artifacts/
