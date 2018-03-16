#!/bin/bash

set -e

SIPWISE_REPO_HOST="deb.sipwise.com"
SIPWISE_REPO_TRANSPORT="https"

CMD_LINE=$(cat /proc/cmdline)
stringInString() {
  local to_test_="$1"   # matching pattern
  local source_="$2"    # string to search in
  case "$source_" in *$to_test_*) return 0;; esac
  return 1
}

checkBootParam() {
  stringInString " $1" "$CMD_LINE"
  return "$?"
}

getBootParam() {
  local param_to_search="$1"
  local result=''

  stringInString " $param_to_search=" "$CMD_LINE" || return 1
  result="${CMD_LINE##*$param_to_search=}"
  result="${result%%[   ]*}"
  echo "$result"
  return 0
}

if checkBootParam ngcppro || checkBootParam ngcpsp1 || checkBootParam ngcpsp2 ; then
  if checkBootParam "sipwiserepo=" ; then
    SIPWISE_REPO_HOST=$(getBootParam sipwiserepo)
  fi
  URL="${SIPWISE_REPO_TRANSPORT}://${SIPWISE_REPO_HOST}/sppro/"
  available=$( curl -s -o /dev/null -w "%{http_code}" "$URL" || true )
  while [[ "$available" != 200 ]] ; do
	if dialog --yes-label Retry --no-label Exit --yesno \
      "You are installing Pro/Carrier version but ${SIPWISE_REPO_TRANSPORT}://${SIPWISE_REPO_HOST}/sppro/ repository not available. Please contact support@sipwise.com" 0 0 ; then
      available=$( curl -s -o /dev/null -w "%{http_code}" "$URL" || true )
    else
      break
    fi
  done
fi
