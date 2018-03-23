#!/bin/bash

set -e

message="Do you want to check the install media?"
if dialog --yes-label Yes --no-label Skip --yesno "${message}" 0 0 ; then
  sudo apt-get update && sudo apt-get install isomd5sum --assume-yes
  if ! result="$( { checkisomd5 /dev/sr0 1>/dev/null; } 2>&1 )" ; then
    err_message="Integrity check failed. Reason: ${result}. Abort installation or continue anyway?"
    if dialog --yes-label Exit --no-label Continue --yesno "${err_message}" 0 0 ; then
      exit 1
    else
      exit 0
    fi
  fi
fi
