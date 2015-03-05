#!/bin/bash

set -e

export LANG=C
export LC_ALL=C

working_dir="$(dirname $0)"
scripts_dir="${working_dir}/includes/"
netscript_dir="${scripts_dir}/netscript/"

RC=0

RED="$(tput setaf 1)"
GREEN="$(tput setaf 2)"
YELLOW="$(tput setaf 3)"
BLUE="$(tput setaf 4)"
NORMAL="$(tput op)"

. /etc/grml/lsb-functions

einfo "Executing grml-sipwise specific checks..."
eindent

install_sipwise_keyring() {
  if -f "${working_dir}/sipwise.gpg" ; then
    einfo "Installing sipwise keyring to '/etc/apt/trusted.gpg.d/sipwise.gpg'..."; eend 0
  else
    ewarn "Failed to find sipwise keyring '${scripts_dir}/sipwise.gpg', continuing anyway." ; eend 0
  fi

  cp "${working_dir}/sipwise.gpg" /etc/apt/trusted.gpg.d/sipwise.gpg
}

network_check() {
  if ${scripts_dir}/check-for-network ; then
    einfo "Looks like we have working network, continuing..." ; eend 0
  else
    if dialog --yes-label Yes --no-label Exit --yesno "It looks like you don't have a working network connection yet. Do you want to configure the network now?" 0 0 ; then
      if ! netcardconfig ; then
        ewarn "Failed to configure network, continuing anyway." ; eend 0
      fi
    else
      ewarn "Cancelling as requested by user." ; eend 0
      return 1
    fi
  fi
}

report_ssh_password() {
  local rootpwd=$(grep -Eo '\<ssh=[^ ]+' /proc/cmdline || true)

  if [ "$rootpwd" ]; then
    rootpwd=${rootpwd#*=}

    local user=$(getent passwd 1000 | cut -d: -f1)
    [ -n "$user" ] || user="grml"

    local local_if=$(ip -o route show | sed -nre '/^default /s/^default .*dev ([^ ]+).*/\1/p' | head -1)
    if [ -n "$local_if" ] ; then
      local ipaddr=$(ip -o addr show $local_if | grep ' inet ' | head -n 1 | sed -e 's/.*inet \([^ ]*\) .*/\1/' -e 's/\/.*//')
    fi

    local local_if6=$(ip -6 -o route show | sed -nre '/^default /s/^default .*dev ([^ ]+).*/\1/p' | head -1)
    if [ -n "$local_if6" ] ; then
      local ipaddr6=$(ip -6 -o addr show $local_if6 | grep ' inet6 ' | head -n 1 | sed -e 's/.*inet6 \([^ ]*\) .*/\1/' -e 's/\/.*//')
    fi

  fi

  if [ -n "$ipaddr" ] ; then
    einfo "You can connect to this system with SSH to: ${YELLOW}$ipaddr $ipaddr6${NORMAL}" ; eend 0
  fi

  if [ -n "$rootpwd" ] ; then
    einfo "The password for user root/$user is: ${YELLOW}${rootpwd}${NORMAL}"; eend 0
  fi
}

check_for_existing_pvs()
{
  # make sure we don't have a PV named "ngcp" on a different disk,
  # otherwise partitioning and booting won't work
  local EXISTING_VGS=$(pvs | awk '/\/dev\// {print $2 " " $1}')

  if echo $EXISTING_VGS | grep -q '^ngcp ' ; then
    # which disk has the PV named "ngcp"?
    local NGCP_DISK="$(echo $EXISTING_VGS | awk '/^ngcp/ {print $2}')"
    # drop any trailing digits, so we get e.g. /dev/sda for /dev/sda1
    NGCP_DISK="${NGCP_DISK%%[0-9]*}"

    # if the user tries to (re)install to the disk that provides an "ngcp"
    # PV already we should allow overwriting data
    if [[ "${NGCP_DISK}" == "/dev/${TARGET_DISK}" ]] ; then
      return 0
    fi

    dialog --title "LVM PVS check" \
      --msgbox "Sorry, there seems to be a physical volume named 'ngcp' on disk $NGCP_DISK present already. Installation can't continue, please remove/detach the disk and rerun installation procedure." 0 0
    return 1
  fi
}

prompt_for_target()
{
  AVAILABLE_DISKS=$(awk '/[a-z]$/ {print $4}' /proc/partitions | grep -v '^name$' | sort -u)

  if [ -z "$AVAILABLE_DISKS" ] ; then
    dialog --title "Disk selection" \
      --msgbox "Sorry, no disks found. Please make sure to have a hard disk attached to your system/VM." 0 0
    return 1
  fi

  # display disk ID next to the disk name
  DISK_LIST=$(for i in $AVAILABLE_DISKS ; do
                for file in /dev/disk/by-id/* ; do
                   case "$(realpath $file)" in
                     (/dev/"$i") disk_info="${file#/dev/disk/by-id/}" ; break ;;
                             (*) disk_info="$file" ;;
                   esac
                done
                echo ${i} ${disk_info}
              done)

  if ! TARGET_DISK=$(dialog --title "Disk selection" --single-quoted --stdout \
                       --ok-label OK --cancel-label Exit \
                       --menu "Please select the target disk for installing Debian/ngcp:" 0 0 0 \
                       $DISK_LIST) ; then
    ewarn "Cancelling as requested by user during disk selection." ; eend 0
    return 1
  fi
}
# }}}


deploy() {
  # deploy only if we have the ngcpce or debianrelease boot option present
  if ! grep -q ngcpce /proc/cmdline && ! grep -q debianrelease /proc/cmdline ; then
    return 0
  fi

  # choose appropriate deployment.sh script:
  local version=$(grep -Eo '\<ngcpvers=[^ ]+' /proc/cmdline || true)
  if [ "$version" ]; then
    version=${version#*=}
  else
    version="master"
  fi

  einfo "Running ${YELLOW}${version}${NORMAL} of deployment.sh..."; eend 0
  RC=0
  TARGET_DISK=$TARGET_DISK /bin/bash ${netscript_dir}/${version}/deployment.sh || RC=$?
  if [ $RC -eq 0 ] ; then
    if dialog --yes-label Reboot --no-label Exit --yesno "Successfully finished deployment, enjoy your sip:provider CE system. Reboot system now?" 0 0 ; then
      reboot
    else
      ewarn "Not rebooting as requested, please don't forget to reboot your system." ; eend 0
    fi
  elif [ $RC -eq 2 ] ; then
    ewarn "Installation was cancelled by user. Switching into rescue mode." ; eend 0
  else
    dialog --msgbox "Looks like running the deployment script didn't work. Please provide a bug report to support@sipwise.com, providing information about your system and the files present in /tmp/*.log and /tmp/*.txt - dropping you to the rescue system for further investigation." 0 0
  fi
}

install_sipwise_keyring
prompt_for_target
check_for_existing_pvs
network_check
report_ssh_password
deploy

eend $RC
