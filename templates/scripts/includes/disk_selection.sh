#!/bin/bash

set -e
set -u

prompt_for_raid() {
  # display disk ID next to the disk name
  declare -a DISK_LIST
  DISK_LIST=( $(for i in "${AVAILABLE_DISKS[@]}" ; do
                disk_info=$(get_disk_info "${i}")
                echo "${i}" "${disk_info}" off
              done) )
  local TMP
  TMP=$(mktemp -t ngcp-deployment-raid-prompt.XXXXXXXXXX)
  if ! dialog --title "Disk selection for Software RAID" --separate-output \
    --checklist "Please select the disks you would like to use for your RAID1:" 0 0 0 \
    "${DISK_LIST[@]}" 2>"${TMP}" ; then
    rm -f "${TMP}"
    echo "Cancelling as requested by user during disk selection." >&2
    exit 1
  fi
  TARGET_DISK=( $(cat "${TMP}") ); rm -f "${TMP}"
  if [[ "${#TARGET_DISK[@]}" -ne 2 ]]; then
    dialog --title "Disk selection for Software RAID" \
      --msgbox "Exactly 2 disks need to be selected, cannot continue." 0 0
    rerun=true
  fi
}

prompt_for_target() {
  # display disk ID next to the disk name
  declare -a DISK_LIST
  DISK_LIST=( $(for i in "${AVAILABLE_DISKS[@]}" ; do
                disk_info=$(get_disk_info "${i}")
                echo "${i}" "${disk_info}"
              done) )

  local TMP
  TMP=$(mktemp -t ngcp-deployment-target-prompt.XXXXXXXXXX)
  if ! dialog --title "Disk selection" --single-quoted \
    --ok-label OK --cancel-label Exit \
    --menu "Please select the target disk for installing Debian/ngcp:" 0 0 0 \
    "${DISK_LIST[@]}" 2>"${TMP}" ; then
    rm -f "${TMP}"
    echo "Cancelling as requested by user during disk selection." >&2
    exit 1
  fi
  TARGET_DISK=( $(cat "${TMP}") ); rm -f "${TMP}"
}

get_disk_info() {
  local disk="${1}"

  local disk_info
  for file in /dev/disk/by-id/* ; do
    case "$(realpath "${file}")" in
      "/dev/${disk}")
        disk_info="${file#/dev/disk/by-id/}"
        break
      ;;
      *)
        disk_info="${file}"
      ;;
    esac
  done
  echo "${disk_info}"

  return 0
}

rm -f /tmp/disk_options

declare -a AVAILABLE_DISKS
AVAILABLE_DISKS=( $(lsblk --list -o NAME,TYPE | awk '$2 == "disk" {print $1}' | sort -u) )

if [[ -z "${AVAILABLE_DISKS[*]}" ]] ; then
  dialog --title "Disk selection" \
    --msgbox "Sorry, no disks found. Please make sure to have a hard disk attached to your system/VM." 0 0
  exit 1
fi

SW_RAID='false'
message="Do you want to configure Software RAID?
Please notice that only RAID level 1 is currently supported. Configuration will take place using mdadm."

if dialog --stdout --title "Software RAID" --defaultno --yesno "${message}" 0 0 ; then
  SW_RAID='true'
fi

declare -a TARGET_DISK

if "${SW_RAID}" ; then
  rerun=true
  while "${rerun}"; do
    rerun=false
    prompt_for_raid
  done
  echo "SWRAID_DISK1=${TARGET_DISK[0]} SWRAID_DISK2=${TARGET_DISK[1]}" > /tmp/disk_options
else
  prompt_for_target
  echo "TARGET_DISK=${TARGET_DISK[0]}" > /tmp/disk_options
fi

exit 0
