#!/bin/bash

set -e

DATE="$(date +%Y%m%d_%H%M%S)"
declare -a WGET_OPTS=()
WGET_OPTS+=('--timeout=30')
WGET_OPTS+=('-q')
WGET_OPTS+=('-c')
# First (former RELEASE) parameter isn't used but kept for backward compatibility
_="$1"
GRML_ISO="$2"
MR="$3"
DIST="$4"
TEMPLATES="templates"
GRML_URL="${GRML_URL:-https://deb.sipwise.com/deployment-iso/grml/}"
GRML_HASH_URL="${GRML_HASH_URL:-https://deb.sipwise.com/deployment-iso/grml/}"
SIPWISE_ISO="sip_provider_${MR}_${DATE}.iso"

usage () {
  echo "Usage: $0 compat <grml.iso> <mr version> <Debian dist>"
  echo "Sample: $0 compat 'grml64-full_2014.11.iso' mr6.2.1 buster"
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

if [[ -n "${GRML_ISO}" ]]; then
  GRML_ISO=$(basename "${GRML_ISO}")
else
  usage
fi


SCRIPT="$(readlink -f "$0")"
SCRIPTPATH="$(dirname "${SCRIPT}")"
pushd "${SCRIPTPATH}" &>/dev/null

echo "*** Retrieving Grml ISO [${GRML_ISO}] ***"
if [[ -f "${SCRIPTPATH}/${GRML_ISO}" ]]; then
  echo "*** Grml ISO [${GRML_ISO}] is already here, checking sha1 file ***"
  if [[ -f "${SCRIPTPATH}/${GRML_ISO}.sha1" ]]; then
    echo "*** Grml ISO sha1 [${GRML_ISO}.sha1] is already here ***"
  else
    echo "*** Downloading Grml ISO sha1 [${GRML_ISO}.sha1] ***"
    wget "${WGET_OPTS[@]}" -O "${GRML_ISO}.sha1" "${GRML_HASH_URL}${GRML_ISO}.sha1"
  fi
else
  echo "*** Downloading Grml ISO and sha1 files [${GRML_ISO}] ***"
  wget "${WGET_OPTS[@]}" -O "${GRML_ISO}" "${GRML_URL}${GRML_ISO}"
  wget "${WGET_OPTS[@]}" -O "${GRML_ISO}.sha1" "${GRML_HASH_URL}${GRML_ISO}.sha1"
fi

echo "*** Building ${MR} ISO ***"

if grep -q "${GRML_ISO}" "${GRML_ISO}.sha1" ; then
  check_sha1 "${GRML_ISO}"
else
  echo "*** Renaming Grml ISO (from the latest to exact build version) ***"
  # identify ISO version (build time might not necessarily match ISO date)
  ISO_DATE=$(isoinfo -d -i "${GRML_ISO}" | awk '/^Volume id:/ {print $4}')
  if [ -z "${ISO_DATE}" ]; then echo "ISO_DATE not identified, exiting." >&2 ; exit 1 ; fi
  GRML_ISO_DATE="grml64-small_testing_${ISO_DATE}.iso"
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

if [[ ! -d grml2usb.git ]] ; then
  GRML2USB_VERSION='v0.17.0'
  if ! git clone -b "${GRML2USB_VERSION}" --single-branch --depth 1 https://github.com/grml/grml2usb grml2usb.git ; then
    echo "Cloning grml2usb from github failed, falling back to git.grml.org"
    git clone -b "${GRML2USB_VERSION}" --single-branch --depth 1 git://git.grml.org/grml2usb.git
  fi
fi
GRML2USB_DIR=$(pwd)/grml2usb.git

sudo GRML2USB="${GRML2USB_DIR}/grml2usb" "${GRML2USB_DIR}/grml2iso" -c ./${TEMPLATES} -o "${SIPWISE_ISO}" "${GRML_ISO}"

sudo implantisomd5 "${SIPWISE_ISO}"

echo "*** Generating SHA1 and MD5 checksum files ***"
sha1sum "${SIPWISE_ISO}" > "${SIPWISE_ISO}.sha1"
md5sum  "${SIPWISE_ISO}" > "${SIPWISE_ISO}.md5"

mkdir -p artifacts
echo "*** Moving ${SIPWISE_ISO} ${SIPWISE_ISO}.sha1 ${SIPWISE_ISO}.md5 to artifacts/ ***"
mv "${SIPWISE_ISO}" "${SIPWISE_ISO}.sha1" "${SIPWISE_ISO}.md5" artifacts/

docker run --rm -i --privileged -v "$(pwd)":/code/ docker.mgm.sipwise.com/deployment-iso-buster:latest \
  /code/t/iso-tester /code/artifacts/"${SIPWISE_ISO}" /code/artifacts/memtest.jpg /code/t/screenshots/01-memtest.jpg

popd &>/dev/null
