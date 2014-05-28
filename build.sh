#!/bin/bash
# Generate the grub options for all the releases
#
BOOT="templates/boot"
GRUB="${BOOT}/grub/grub.cfg"
ISO="${BOOT}/isolinux"
RELEASES=($(grep -v '#' releases | cut -d, -f1 ))
DISTS=($(grep -v '#' releases |cut -d, -f2 ))

rm -f ${BOOT}/grub/sipwise_ce.cfg ${BOOT}/grub/sipwise_pro.cfg
rm -f ${BOOT}/isolinux/sipwise_ce.cfg ${BOOT}/isolinux/sipwise_pro.cfg

for index in ${!RELEASES[*]}; do
	echo "*** grub template for RELEASE:${RELEASES[$index]} DIST:${DISTS[$index]} ***"
	sed -e "s_##VERSION##_${RELEASES[$index]}_g" \
		-e "s_##DIST##_${DISTS[$index]}_g" grub.cfg_ce >> ${BOOT}/grub/sipwise_ce.cfg
	sed -e "s_##VERSION##_${RELEASES[$index]}_g" \
		-e "s_##DIST##_${DISTS[$index]}_g" grub.cfg_pro >> ${BOOT}/grub/sipwise_pro.cfg

	echo "*** isolinux template for RELEASE:${RELEASES[$index]} DIST:${DISTS[$index]} ***"
	sed -e "s_##VERSION##_${RELEASES[$index]}_g" \
		-e "s_##DIST##_${DISTS[$index]}_g" isolinux.cfg_ce >> ${BOOT}/isolinux/sipwise_ce.cfg
	sed -e "s_##VERSION##_${RELEASES[$index]}_g" \
		-e "s_##DIST##_${DISTS[$index]}_g" isolinux.cfg_pro >> ${BOOT}/isolinux/sipwise_pro.cfg
done
