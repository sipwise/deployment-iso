#!/bin/bash

set -e

working_dir="$(dirname "$0")"

NETWORK='Common'
vlan_message="Enter network configuration:\n<VLAN number> <IP address> <netmask> <gateway> <DNS server>"

while ! "${working_dir}/check-for-network" ; do
  if ! NETWORK=$( dialog --ok-label OK --cancel-label Exit \
                    --stdout --menu "Configure network" 0 0 0 \
                    Common "Configure common network setup" \
                    VLAN "Configure network via VLAN" ) ; then
    exit 1
  fi

  if [[ "${NETWORK}" == Common ]]; then
    netcardconfig || true
  elif [[ "${NETWORK}" == VLAN ]]; then
    NET_CONFIG=( $( dialog --title 'Network configuration' --single-quoted --stdout \
                      --ok-label OK --cancel-label Exit \
                      --inputbox "${vlan_message}" 0 0 ) )
    if [ -z "${NET_CONFIG[*]}" ]; then
      continue
    fi
    config_message="Your network configuration is\nVLAN id: ${NET_CONFIG[0]}\nIP address ${NET_CONFIG[1]}\nNetmask: ${NET_CONFIG[2]}\nGateway: ${NET_CONFIG[3]}\nDNS server: ${NET_CONFIG[4]}"
    if ! dialog --yes-label Yes --no-label No --yesno "${config_message}" 0 0 ; then
      continue
    fi
    ip link set eth0 up
    ip link add link eth0 name eth0."${NET_CONFIG[0]}" type vlan id "${NET_CONFIG[0]}"
    ip link set eth0."${NET_CONFIG[0]}" up
    ip addr add "${NET_CONFIG[1]}"/"${NET_CONFIG[2]}" dev eth0."${NET_CONFIG[0]}"
    ip route del default || true
    ip route add default via "${NET_CONFIG[3]}" dev eth0."${NET_CONFIG[0]}"
    echo "nameserver ${NET_CONFIG[4]}" >> /etc/resolv.conf
  fi
done
