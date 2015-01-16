#!/bin/bash
# Generate the grub options for all the releases
#
BASE=$(dirname $0)
TEMPLATES="${TEMPLATES:-templates}"
BOOT="${BASE}/${TEMPLATES}/boot"
GRUB="${BOOT}/grub/grub.cfg"
ISO="${BOOT}/isolinux"
RELEASES=($(grep -v '#' ${BASE}/releases | cut -d, -f1 ))
DISTS=($(grep -v '#' ${BASE}/releases |cut -d, -f2 ))
CARRIER=($(grep -v '#' ${BASE}/releases |cut -d, -f3 ))
INFO=($(grep -v '#' ${BASE}/releases |cut -d, -f4 ))
MR="${MR:-no}"
PUBLIC="${PUBLIC:-no}"

rm -f ${BOOT}/grub/sipwise_*.cfg
rm -f ${BOOT}/isolinux/sipwise_*.cfg

for index in ${!RELEASES[*]}; do
	if [[ ${RELEASES[$index]} =~ ^mr[0-9]\.[0-9]$ ]] && [ "${MR}" = "no" ]; then
		echo "*** [SKIP] grub template for RELEASE:${RELEASES[$index]} DIST:${DISTS[$index]} ***"
		echo "*** [SKIP] isolinux template for RELEASE:${RELEASES[$index]} DIST:${DISTS[$index]} ***"
	else
		if [ "${PUBLIC}" != "no" ]; then
			if [ "${INFO[$index]}" = "LTS" ] || [ "${INFO[$index]}" = "LATEST" ]; then
				TYPE=$(echo ${INFO[$index]}| tr '[:upper:]' '[:lower:]')
				echo "*** grub template ${INFO[$index]} for RELEASE:${RELEASES[$index]} DIST:${DISTS[$index]} ***"
				sed -e "s_##VERSION##_${RELEASES[$index]}_g" \
					-e "s_##DIST##_${DISTS[$index]}_g" \
					${BASE}/grub.cfg_ce >> ${BOOT}/grub/sipwise_${TYPE}.cfg

				echo "*** isolinux template ${INFO[$index]} for RELEASE:${RELEASES[$index]} DIST:${DISTS[$index]} ***"
				sed -e "s_##VERSION##_${RELEASES[$index]}_g" \
					-e "s_##DIST##_${DISTS[$index]}_g" ${BASE}/isolinux.cfg_${TYPE} \
					 >> ${BOOT}/isolinux/sipwise_${TYPE}.cfg
			else
				echo "*** [SKIP] grub template for RELEASE:${RELEASES[$index]} DIST:${DISTS[$index]} ***"
				echo "*** [SKIP] isolinux template for RELEASE:${RELEASES[$index]} DIST:${DISTS[$index]} ***"
			fi
		else
			echo "*** grub template for RELEASE:${RELEASES[$index]} DIST:${DISTS[$index]} CARRIER:${CARRIER[$index]} ***"
			sed -e "s_##VERSION##_${RELEASES[$index]}_g" \
				-e "s_##DIST##_${DISTS[$index]}_g" \
				${BASE}/grub.cfg_ce >> ${BOOT}/grub/sipwise_ce.cfg
			sed -e "s_##VERSION##_${RELEASES[$index]}_g" \
				-e "s_##DIST##_${DISTS[$index]}_g" \
				${BASE}/grub.cfg_pro >> ${BOOT}/grub/sipwise_pro.cfg
			if [ "${CARRIER[$index]}" == "yes" ]; then
				sed -e "s_##VERSION##_${RELEASES[$index]}_g" \
					-e "s_##DIST##_${DISTS[$index]}_g" \
					${BASE}/grub.cfg_carrier >> ${BOOT}/grub/sipwise_carrier.cfg
			fi

			echo "*** isolinux template for RELEASE:${RELEASES[$index]} DIST:${DISTS[$index]} CARRIER:${CARRIER[$index]} ***"
			sed -e "s_##VERSION##_${RELEASES[$index]}_g" \
				-e "s_##DIST##_${DISTS[$index]}_g" ${BASE}/isolinux.cfg_ce \
				 >> ${BOOT}/isolinux/sipwise_ce.cfg
			sed -e "s_##VERSION##_${RELEASES[$index]}_g" \
				-e "s_##DIST##_${DISTS[$index]}_g" ${BASE}/isolinux.cfg_pro \
				>> ${BOOT}/isolinux/sipwise_pro.cfg
			if [ "${CARRIER[$index]}" == "yes" ]; then
				sed -e "s_##VERSION##_${RELEASES[$index]}_g" \
					-e "s_##DIST##_${DISTS[$index]}_g" ${BASE}/isolinux.cfg_carrier \
					>> ${BOOT}/isolinux/sipwise_carrier.cfg
			fi
		fi
	fi
done
