#!/bin/bash
# Generate the grub options for all the releases
#
BASE="$(dirname "$0")"
TEMPLATES="${TEMPLATES:-templates}"
BOOT="${BASE}/${TEMPLATES}/boot"
MR="${MR:-trunk}"
DIST="${DIST:-bullseye}"

echo "*** grub templates for RELEASE:${MR} DIST:${DIST} ***"

sed -e "s_##VERSION##_${MR}_g" \
	-e "s_##DIST##_${DIST}_g" \
	"${BASE}/grub.cfg" > "${BOOT}/grub/grub.cfg"

echo "*** isolinux templates for RELEASE:${MR} DIST:${DIST} ***"

sed -e "s_##VERSION##_${MR}_g" \
	-e "s_##DIST##_${DIST}_g" \
	"${BASE}/isolinux.cfg" > "${BOOT}/isolinux/isolinux.cfg"
