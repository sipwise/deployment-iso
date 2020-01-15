#!/bin/bash

set -e

SIPWISE_REPO_HOST="deb.sipwise.com"
SIPWISE_REPO_TRANSPORT="https"

CMD_LINE=$(cat /proc/cmdline)
stringInString() {
  local to_test_="$1"   # matching pattern
  local source_="$2"    # string to search in
  case "${source_}" in *${to_test_}*) return 0;; esac
  return 1
}

checkBootParam() {
  stringInString " $1" "${CMD_LINE}"
  return "$?"
}

getBootParam() {
  local param_to_search="$1"
  local result=''

  stringInString " ${param_to_search}=" "${CMD_LINE}" || return 1
  result="${CMD_LINE##*$param_to_search=}"
  result="${result%%[   ]*}"
  echo "${result}"
  return 0
}

if checkBootParam ngcppro ; then
  if checkBootParam "sipwiserepotransport=" ; then
    SIPWISE_REPO_TRANSPORT=$(getBootParam sipwiserepotransport)
  fi

  if checkBootParam "sipwiserepo=" ; then
    SIPWISE_REPO_HOST=$(getBootParam sipwiserepo)
  fi

  if checkBootParam 'ngcprescue' ; then
    exit 0
  fi

  URL="${SIPWISE_REPO_TRANSPORT}://${SIPWISE_REPO_HOST}/sppro/"
  err_message="You are installing Pro/Carrier version but ${SIPWISE_REPO_TRANSPORT}://${SIPWISE_REPO_HOST}/sppro/ repository not accessible. Please contact support@sipwise.com"
  while ! wget -q -T 10 -O /dev/null "${URL}" ; do
    if ! dialog --yes-label Retry --no-label Exit --yesno "${err_message}" 0 0 ; then
      exit 1
    fi
  done
fi
