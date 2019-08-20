#!/bin/bash

set -e

# detect the underlying Debian version of the Grml ISO,
# keeping code backwards compatible for e.g. cherry-picking
if grep -q buster /etc/debian_version ; then
  DEBIAN_RELEASE="buster"
else
  DEBIAN_RELEASE="stretch"
fi

# Do not rely on apt sources.list setup of the running live system
TMPDIR=$(mktemp -d)
mkdir -p "${TMPDIR}/etc/preferences.d" "${TMPDIR}/statedir/lists/partial" \
  "${TMPDIR}/cachedir/archives/partial"
chown _apt -R "${TMPDIR}"

echo "deb https://debian.sipwise.com/debian/ ${DEBIAN_RELEASE} main contrib non-free" > \
  "${TMPDIR}/etc/sources.list"

echo "Updating list of packages..."
DEBIAN_FRONTEND='noninteractive' apt-get \
  -o dir::cache="${TMPDIR}/cachedir" \
  -o dir::state="${TMPDIR}/statedir" \
  -o dir::etc="${TMPDIR}/etc" \
  -o dir::etc::trustedparts="/etc/apt/trusted.gpg.d/" \
  update >/dev/null

echo "Installing required packages..."
DEBIAN_FRONTEND='noninteractive' apt-get \
  -o dir::cache="${TMPDIR}/cachedir" \
  -o dir::state="${TMPDIR}/statedir" \
  -o dir::etc="${TMPDIR}/etc" \
  -o dir::etc::trustedparts="/etc/apt/trusted.gpg.d/" \
  --assume-yes install isomd5sum
