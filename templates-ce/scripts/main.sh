#!/bin/bash

set -e

working_dir="$(dirname $0)"
scripts_dir="${working_dir}/includes/"

RC=0

RED="$(tput setaf 1)"
GREEN="$(tput setaf 2)"
YELLOW="$(tput setaf 3)"
BLUE="$(tput setaf 4)"
NORMAL="$(tput op)"

. /etc/grml/lsb-functions

einfo "Executing grml-sipwise specific checks..."
eindent

network_check() {
  if ${scripts_dir}/check-for-network ; then
    einfo "Looks like we have working network, continuing..." ; eend 0
  else
    if dialog --yesno "It looks like you don't have a working network connection yet. Do you want to configure the network now?" 0 0 ; then
      if netcardconfig ; then
	echo "continue"
      else
	echo TODO
      fi
    else
      eerror "no netcardconfig for me :(" ; eend 1
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

deploy() {
  # deploy only if we have the ngcpce or debianrelease boot option present
  if ! grep -q ngcpce /proc/cmdline && ! grep -q debianrelease /proc/cmdline ; then
    return 0
  fi

  # TODO - prompt for disk which should be used and ask user if he really wants to execute it
  if ${scripts_dir}/deployment.sh ; then
    dialog --msgbox "Successfully finished deployment, enjoy your sip:provider CE system. System will be rebooted once you press OK." 0 0
    reboot
  else
    dialog --msgbox "Looks like running the deployment script didn't work. Please provide a bug report to support@sipwise.com, providing information about your system and the files present in /tmp/*.log and /tmp/*.txt - dropping you to the rescue system for further investigation." 0 0
    RC=1
  fi
}

network_check
report_ssh_password
deploy

eend $RC
