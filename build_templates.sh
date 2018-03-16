#!/bin/bash
# Generate the grub options for all the releases
#
BASE="$(dirname "$0")"
TEMPLATES="${TEMPLATES:-templates}"
BOOT="${BASE}/${TEMPLATES}/boot"
MR="${MR:-trunk}"

if [[ ${MR} == 'trunk' ]]; then
    INFO_LINE="$( grep -E '^\w+.+LATEST$' "${BASE}"/releases )"
else
    INFO_LINE="$( grep -E "^${MR}" "${BASE}"/releases )"
fi

RELEASE=$( echo "${INFO_LINE}" | cut -d, -f1 )
DIST=$( echo "${INFO_LINE}" | cut -d, -f2 )
CARRIER=$( echo "${INFO_LINE}" | cut -d, -f3 )

echo "*** grub templates for RELEASE:${RELEASE} DIST:${DIST} CARRIER:${CARRIER} ***"

sed -e "s_##VERSION##_${RELEASE}_g" \
	-e "s_##DIST##_${DIST}_g" \
	"${BASE}/grub.cfg" > "${BOOT}/grub/grub.cfg"

echo "*** isolinux templates for RELEASE:${RELEASE} DIST:${DIST} CARRIER:${CARRIER} ***"

sed -e "s_##VERSION##_${RELEASE}_g" \
	-e "s_##DIST##_${DIST}_g" \
	"${BASE}/isolinux.cfg" > "${BOOT}/isolinux/isolinux.cfg"
