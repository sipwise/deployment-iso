#!/bin/bash

set -e
set -u

rm -f /tmp/disk_options

AVAILABLE_DISKS=( $(awk '/[a-z]$/ {print $4}' /proc/partitions | grep -v '^name$' | sort -u) )
if [[ -z "${AVAILABLE_DISKS[*]}" ]] ; then
  dialog --title "Disk selection" \
    --msgbox "Sorry, no disks found. Please make sure to have a hard disk attached to your system/VM." 0 0
  exit 1
fi

declare -a TARGET_DISK

prompt_for_raid() {
  declare -a DISK_LIST
  DISK_LIST=( $(for i in "${AVAILABLE_DISKS[@]}" ; do
                for file in /dev/disk/by-id/* ; do
                   case "$(realpath "${file}")" in
                     (/dev/"${i}") disk_info="${file#/dev/disk/by-id/}" ; break ;;
                             (*) disk_info="${file}" ;;
                   esac
                done
                echo "${i}" "${disk_info}" "off"
              done) )
  local TMP
  TMP=$(mktemp)
  if ! dialog --title "Disk selection for Software RAID" --separate-output \
    --checklist "Please select the disks you would like to use for your RAID1:" 0 0 0 \
    "${DISK_LIST[@]}" 2>"${TMP}" ; then
    rm -f "${TMP}"
    echo "Cancelling as requested by user during disk selection." >2
    exit 1
  fi
  TARGET_DISK=( $(cat "${TMP}") )
  echo "${TARGET_DISK[@]}" >> /tmp/disk.log
  if [[ "${#TARGET_DISK[@]}" -ne 2 ]]; then
    echo "Selected not 2 disks, can not continue" >2
    exit 1
  fi
}

prompt_for_target() {
  # display disk ID next to the disk name
  declare -a DISK_LIST
  DISK_LIST=( $(for i in "${AVAILABLE_DISKS[@]}" ; do
                for file in /dev/disk/by-id/* ; do
                   case "$(realpath "${file}")" in
                     (/dev/"${i}") disk_info="${file#/dev/disk/by-id/}" ; break ;;
                             (*) disk_info="$file" ;;
                   esac
                done
                echo "${i}" "${disk_info}"
              done) )

  local TMP
  TMP=$(mktemp)
  if ! dialog --title "Disk selection" --single-quoted \
    --ok-label OK --cancel-label Exit \
    --menu "Please select the target disk for installing Debian/ngcp:" 0 0 0 \
    "${DISK_LIST[@]}" 2>"${TMP}" ; then
    rm -f "${TMP}"
    echo "Cancelling as requested by user during disk selection." >2
    exit 1
  fi
  TARGET_DISK=( $(cat "${TMP}") ); rm -f "${TMP}"
  echo "${TARGET_DISK[@]}" >> /tmp/disk.log
}

SW_RAID='false'
message="Do you want to configure Software RAID?
Please notice that only RAID level 1 is currently supported. Configuration will take place using mdadm."

if dialog --stdout --title "Software RAID" --defaultno --yesno "${message}" 0 0 ; then
  SW_RAID='true'
fi

if "${SW_RAID}" ; then
  prompt_for_raid
  echo "SWRAID_DISK1=${TARGET_DISK[0]} SWRAID_DISK2=${TARGET_DISK[1]}" > /tmp/disk_options
else
  prompt_for_target
  echo "TARGET_DISK=${TARGET_DISK[0]}" > /tmp/disk_options
fi

exit 0
