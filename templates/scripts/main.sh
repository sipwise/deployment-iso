#!/bin/bash

set -e

export LANG=C
export LC_ALL=C

working_dir="$(dirname "$0")"
scripts_dir="${working_dir}/includes/"
keys_dir="${working_dir}/keys/"

RC=0

YELLOW="$(tput setaf 3)"
NORMAL="$(tput op)"

. /etc/grml/lsb-functions

einfo "Executing grml-sipwise specific checks..."
eindent

install_sipwise_keyring() {
  if [ -f "${keys_dir}/sipwise.gpg" ]; then
    einfo "Installing sipwise keyring to '/etc/apt/trusted.gpg.d/sipwise.gpg'..."; eend 0
    cp "${keys_dir}/sipwise.gpg" /etc/apt/trusted.gpg.d/sipwise.gpg
  else
    ewarn "Sipwise keyring '${keys_dir}/sipwise.gpg' not found, continuing anyway." ; eend 0
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
      local ipaddr="$(ip -o addr show "$local_if" | grep ' inet ' | head -n 1 | sed -e 's/.*inet \([^ ]*\) .*/\1/' -e 's/\/.*//')"
    fi

    local local_if6=$(ip -6 -o route show | sed -nre '/^default /s/^default .*dev ([^ ]+).*/\1/p' | head -1)
    if [ -n "$local_if6" ] ; then
      local ipaddr6="$(ip -6 -o addr show "$local_if6" | grep ' inet6 ' | head -n 1 | sed -e 's/.*inet6 \([^ ]*\) .*/\1/' -e 's/\/.*//')"
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

  if echo "$EXISTING_VGS" | grep -q '^ngcp ' ; then
    # which disk has the PV named "ngcp"?
    local NGCP_DISK="$(echo "$EXISTING_VGS" | awk '/^ngcp/ {print $2}')"
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

deploy() {
  # choose appropriate deployment.sh script:
  local version=$(grep -Eo '\<ngcpvers=[^ ]+' /proc/cmdline || true)
  if [ "$version" ]; then
    version=${version#*=}
  else
    version="master"
  fi

  einfo "Running ${YELLOW}${version}${NORMAL} of deployment.sh..."; eend 0
  RC=0
  "${scripts_dir}/deployment.sh" || RC=$?
  if [ $RC -eq 0 ] ; then
    if dialog --yes-label Reboot --no-label Exit --yesno "Successfully finished deployment, enjoy your Sipwise C5 system. Reboot system now?" 0 0 ; then
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

"${scripts_dir}/verify_iso_image.sh"
install_sipwise_keyring
"${scripts_dir}/network_configuration.sh"
"${scripts_dir}/check_installing_version.sh"
"${scripts_dir}/disk_selection.sh"
if [[ ! -r '/tmp/disk_options' ]]; then
  eerror "There is no /tmp/disk_options which should be availible after disk selection" ; eend 0
fi
DISK_OPTIONS="$(cat '/tmp/disk_options')"
if [[ -z "${DISK_OPTIONS}" ]]; then
  ewarn "There are no disk options configured, continuing anyway." ; eend 0
fi
export ${DISK_OPTIONS}
check_for_existing_pvs
report_ssh_password
deploy

eend $RC
