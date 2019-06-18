#!/bin/bash
# Purpose: automatically install Debian + Sipwise C5 platform
################################################################################

set -e

INSTALL_LOG='/tmp/deployment-installer-debug.log'
exec  > >(tee -a $INSTALL_LOG    )
exec 2> >(tee -a $INSTALL_LOG >&2)

# set version to git commit ID
SCRIPT_VERSION="%SCRIPT_VERSION%"

# not set? then fall back to timestamp of execution
if [ -z "$SCRIPT_VERSION" ] || [ "$SCRIPT_VERSION" = '%SCRIPT_VERSION%' ] ; then
  SCRIPT_VERSION=$(date +%s) # seconds since 1970-01-01 00:00:00 UTC
fi

# Never ever execute the script outside of a
# running Grml live system because partitioning
# disks might destroy data. Seriously.
if ! [ -r /etc/grml_cd ] ; then
  echo "Not running inside Grml, better safe than sorry. Sorry." >&2
  exit 1
fi

# better safe than sorry
export LC_ALL=C
export LANG=C

# avoid SHELL being set but not available, causing needrestart failure, see #788819
unset SHELL

# defaults
DEBUG_MODE=false
DEFAULT_INTERNAL_DEV=eth1
DEFAULT_IP1=192.168.255.251
DEFAULT_IP2=192.168.255.252
DEFAULT_IP_HA_SHARED=192.168.255.250
DEFAULT_INTERNAL_NETMASK=255.255.255.248
TARGET=/mnt
PRO_EDITION=false
CE_EDITION=false
CARRIER_EDITION=false
NGCP_INSTALLER=false
PUPPET=''
PUPPET_SERVER=puppet.mgm.sipwise.com
PUPPET_GIT_REPO=''
PUPPET_GIT_BRANCH=master
PUPPET_LOCAL_GIT="${TARGET}/tmp/puppet.git"
PUPPET_RESCUE_PATH="/mnt/rescue_drive"
PUPPET_RESCUE_LABEL="SIPWRESCUE*"
INTERACTIVE=false
DHCP=false
LOGO=true
RETRIEVE_MGMT_CONFIG=false
TRUNK_VERSION=false
DEBIAN_RELEASE=buster
HALT=false
REBOOT=false
STATUS_DIRECTORY=/srv/deployment/
STATUS_WAIT=0
VAGRANT=false
ADJUST_FOR_LOW_PERFORMANCE=false
ENABLE_VM_SERVICES=false
FILESYSTEM="ext4"
ROOTFS_SIZE="10G"
FALLBACKFS_SIZE="${ROOTFS_SIZE}"
SWAPFILE_SIZE_MB_MIN="4096"
SWAPFILE_SIZE_MB_MAX="16384"
SWAPFILE_SIZE_MB=""
SWRAID_DEVICE="/dev/md0"
SWRAID_DESTROY=false
GPG_KEY_SERVER="pool.sks-keyservers.net"
DEBIAN_REPO_HOST="debian.sipwise.com"
DEBIAN_REPO_TRANSPORT="https"
SIPWISE_REPO_HOST="deb.sipwise.com"
SIPWISE_REPO_TRANSPORT="https"
DEBIAN_URL="${DEBIAN_REPO_TRANSPORT}://${DEBIAN_REPO_HOST}"
SIPWISE_URL="${SIPWISE_REPO_TRANSPORT}://${SIPWISE_REPO_HOST}"
DPL_MYSQL_REPLICATION=true
FILL_APPROX_CACHE=true
VLAN_BOOT_INT=2
VLAN_SSH_EXT=300
VLAN_WEB_EXT=1718
VLAN_SIP_EXT=1719
VLAN_SIP_INT=1720
VLAN_HA_INT=1721
VLAN_RTP_EXT=1722
VIRTUALBOX_DIR="/usr/share/virtualbox"
VIRTUALBOX_ISO="VBoxGuestAdditions_5.2.26.iso"
VIRTUALBOX_ISO_CHECKSUM="b927c5d0d4c97a9da2522daad41fe96b616ed06bfb0c883f9c42aad2244f7c38" # sha256
VIRTUALBOX_ISO_URL_PATH="/files/${VIRTUALBOX_ISO}"
SIPWISE_APT_KEY_PATH="/etc/apt/trusted.gpg.d/sipwise-keyring.gpg"
NGCP_PXE_INSTALL=false
ADDITIONAL_PACKAGES=(git augeas-tools gdisk)


### helper functions {{{
get_deploy_status() {
  if [ -r "${STATUS_DIRECTORY}/status" ] ; then
    cat "${STATUS_DIRECTORY}/status"
  else
    echo 'error'
  fi
}

set_deploy_status() {
  [ -n "$1" ] || return 1
  echo "$*" > "${STATUS_DIRECTORY}"/status
}

enable_deploy_status_server() {
  mkdir -p "${STATUS_DIRECTORY}"

  # get rid of already running process
  PID=$(pgrep -f 'python.*SimpleHTTPServer') || true
  [ -n "$PID" ] && kill "$PID"

  (
    cd "${STATUS_DIRECTORY}"
    python -m SimpleHTTPServer 4242 >/tmp/status_server.log 2>&1 &
  )
}

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

# load ":"-separated nfs ip into array BP[client-ip], BP[server-ip], ...
# ip=<client-ip>:<server-ip>:<gw-ip>:<netmask>:<hostname>:<device>:<autoconf>
# $1: Array name (needs "declare -A BP" before call), $2: ip=... string
loadNfsIpArray() {
  [ -n "$1" ] && [ -n "$2" ] || return 0
  local IFS=":"
  local ind=(client-ip server-ip gw-ip netmask hostname device autoconf)
  local i
  for i in $2 ; do
    eval "$1[${ind[n++]}]=$i"
  done
  [ "$n" == "7" ] && return 0 || return 1
}

disable_systemd_tmpfiles_clean() {
  echo "Disabling systemd-tmpfiles-clean.timer"
  systemctl mask systemd-tmpfiles-clean.timer
}

debootstrap_sipwise_key() {
  mkdir -p /etc/debootstrap/pre-scripts/
  cat > /etc/debootstrap/pre-scripts/install-sipwise-key.sh << EOF
#!/bin/bash
# installed via deployment.sh
target_file=sipwise.gpg
if [[ "${KEYRING}" =~ trusted.gpg\$ ]]; then
  target_file=trusted.gpg
fi
cp ${KEYRING} "\${MNTPOINT}/etc/apt/trusted.gpg.d/\${target_file}"
EOF
  chmod 775 /etc/debootstrap/pre-scripts/install-sipwise-key.sh
}

check_package_version() {
  if [ $# -lt 2 ] ; then
    die "Usage: package_upgrade <package> <version>" >&2
  fi

  local package_name="$1"
  local required_version="$2"
  local present_version

  present_version=$(dpkg-query --show --showformat="\${Version}" "${package_name}")

  if dpkg --compare-versions "${present_version}" lt "${required_version}" ; then
    echo "${package_name} version ${present_version} is older than minimum required version ${required_version}."
    return 1
  fi

  return 0
}

ensure_recent_package_versions() {
  [[ -z "${UPGRADE_PACKAGES[*]}" ]] && return 0

  echo "Ensuring packages are installed in a recent enough version: ${UPGRADE_PACKAGES[*]}"

  # use temporary apt database for speed reasons
  local TMPDIR
  TMPDIR=$(mktemp -d)
  mkdir -p "${TMPDIR}/statedir/lists/partial" "${TMPDIR}/cachedir/archives/partial"
  local debsrcfile
  debsrcfile=$(mktemp)
  echo "deb ${SIPWISE_REPO_TRANSPORT}://${SIPWISE_REPO_HOST}/grml.org grml-testing main" >> "${debsrcfile}"

  DEBIAN_FRONTEND='noninteractive' apt-get \
    -o dir::cache="${TMPDIR}/cachedir" \
    -o dir::state="${TMPDIR}/statedir" \
    -o dir::etc::sourcelist="${debsrcfile}" \
    -o dir::etc::sourceparts=/dev/null \
    -o dir::etc::trustedparts="/etc/apt/trusted.gpg.d/" \
    update

  DEBIAN_FRONTEND='noninteractive' apt-get \
    -o dir::cache="${TMPDIR}/cachedir" \
    -o dir::state="${TMPDIR}/statedir" \
    -o dir::etc::sourcelist="${debsrcfile}" \
    -o dir::etc::sourceparts=/dev/null \
    -o dir::etc::trustedparts="/etc/apt/trusted.gpg.d/" \
    -y --no-install-recommends install "${UPGRADE_PACKAGES[@]}"

  for pkg in "${UPGRADE_PACKAGES[@]}"; do
    if is_package_installed "${pkg}"; then
      echo "Package '${pkg}' was installed correctly."
    else
      die "Error: Package '${pkg}' was not installed correctly, aborting."
    fi
  done
}

install_vbox_iso() {
  echo "Downloading virtualbox-guest-additions ISO"

  mkdir -p "${VIRTUALBOX_DIR}"
  vbox_isofile="${VIRTUALBOX_DIR}/${VIRTUALBOX_ISO}"
  wget --retry-connrefused --no-verbose -c -O "$vbox_isofile" "${SIPWISE_URL}${VIRTUALBOX_ISO_URL_PATH}"

  echo "${VIRTUALBOX_ISO_CHECKSUM} ${vbox_isofile}" | sha256sum --check || die "Error: failed to compute checksum for Virtualbox ISO. Exiting."
}

set_custom_grub_boot_options() {
  echo "Adjusting default GRUB boot options (enabling net.ifnames=0)"
  sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 net.ifnames=0"/' "${TARGET}/etc/default/grub"

  echo "Invoking update-grub"
  grml-chroot $TARGET update-grub

  if [ -d "${TARGET}/etc/.git" ]; then
    echo "Commit /etc/default/grub changes using etckeeper"
    chroot "$TARGET" etckeeper commit "/etc/default/grub changes"
  fi
}

die() {
  echo "$@" >&2
  set_deploy_status "error"
  exit 1
}

enable_trace() {
  if "${DEBUG_MODE}" ; then
    set -x
    export PS4='+\t (${BASH_SOURCE##*/}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): } '
  fi
}

disable_trace() {
  if "${DEBUG_MODE}" ; then
    set +x
    export PS4=''
  fi
}

is_package_installed() {
  local pkg="$1"

  if [ "$(dpkg-query -f "\${db:Status-Status} \${db:Status-Eflag}" -W "${pkg}" 2>/dev/null)" = 'installed ok' ]; then
    return 0
  else
    return 1
  fi
}

ensure_packages_installed() {
  [[ -z "${ADDITIONAL_PACKAGES[*]}" ]] && return 0

  local install_packages
  install_packages=()
  echo "Ensuring packages installed: ${ADDITIONAL_PACKAGES[*]}"
  for pkg in "${ADDITIONAL_PACKAGES[@]}"; do
    if is_package_installed "${pkg}"; then
      echo "Package '${pkg}' is already installed, nothing to do."
    else
      echo "Package '${pkg}' is not installed, scheduling..."
      install_packages+=("${pkg}")
    fi
  done

  if [ -z "${install_packages[*]}" ] ; then
    echo "No packages to install, skipping further ensure_packages_installed execution"
    return 0
  fi

  # Use separate apt database and source list because non management node has no internet access
  # so is installed from management node so these additional packages have to be accessible from
  # sipwise repo
  local TMPDIR
  TMPDIR=$(mktemp -d)
  mkdir -p "${TMPDIR}/etc/preferences.d" "${TMPDIR}/statedir/lists/partial" \
    "${TMPDIR}/cachedir/archives/partial"
  chown _apt -R "${TMPDIR}"

  echo "deb ${DEBIAN_URL}/debian/ buster main contrib non-free" > \
    "${TMPDIR}/etc/sources.list"

  DEBIAN_FRONTEND='noninteractive' apt-get \
    -o dir::cache="${TMPDIR}/cachedir" \
    -o dir::state="${TMPDIR}/statedir" \
    -o dir::etc="${TMPDIR}/etc" \
    -o dir::etc::trustedparts="/etc/apt/trusted.gpg.d/" \
    update

  DEBIAN_FRONTEND='noninteractive' apt-get \
    -o dir::cache="${TMPDIR}/cachedir" \
    -o dir::state="${TMPDIR}/statedir" \
    -o dir::etc="${TMPDIR}/etc" \
    -o dir::etc::trustedparts="/etc/apt/trusted.gpg.d/" \
    -y --no-install-recommends install "${install_packages[@]}"

  for pkg in "${install_packages[@]}"; do
    if is_package_installed "${pkg}"; then
      echo "Package '${pkg}' was installed correctly."
    else
      die "Error: Package '${pkg}' was not installed correctly, aborting."
    fi
  done
}

status_wait() {
  if [[ -n "${STATUS_WAIT}" ]] && [[ "${STATUS_WAIT}" != 0 ]]; then
    # if ngcpstatus boot option is used wait for a specific so a
    # remote host has a chance to check for deploy status "finished",
    # defaults to 0 seconds otherwise
    echo "Sleeping for ${STATUS_WAIT} seconds (as requested via boot option 'ngcpstatus')"
    sleep "${STATUS_WAIT}"
  fi
}

wait_exit() {
  local e_code="${?}"
  if [[ "${e_code}" -ne 0 ]]; then
    set_deploy_status "error"
  fi
  trap '' 1 2 3 6 15 ERR EXIT
  status_wait
  exit "${e_code}"
}

# check for EFI support, if not present try to enable it
efi_support() {
  if lsmod | grep -q efivars ; then
    echo "EFI support detected."
    return 0
  fi

  if modprobe efivars &>/dev/null ; then
    echo "EFI support enabled now."
    return 0
  fi

  return 1
}
# }}}

###################################################
# the script execution begins here

### trap signals: 1 SIGHUP, 2 SIGINT, 3 SIGQUIT, 6 SIGABRT, 15 SIGTERM
trap 'wait_exit;' 1 2 3 6 15 ERR EXIT

CMD_LINE=$(cat /proc/cmdline)

echo "Host IP: $(ip-screen)"
echo "Deployment version: $SCRIPT_VERSION"

enable_deploy_status_server

set_deploy_status "checkBootParam"

if checkBootParam debugmode ; then
  DEBUG_MODE=true
  enable_trace
  echo "CMD_LINE: ${CMD_LINE}"
fi

disable_systemd_tmpfiles_clean

if checkBootParam 'targetdisk=' ; then
  TARGET_DISK=$(getBootParam targetdisk)
fi

if checkBootParam "swraiddisk1=" ; then
  SWRAID_DISK1=$(getBootParam swraiddisk1)
  SWRAID_DISK1=${SWRAID_DISK1#/dev/}
fi

if checkBootParam "swraiddisk2=" ; then
  SWRAID_DISK2=$(getBootParam swraiddisk2)
  SWRAID_DISK2=${SWRAID_DISK2#/dev/}
fi

if checkBootParam swraiddestroy ; then
  SWRAID_DESTROY=true
fi

# if TARGET_DISK environment variable is set accept it
if [ -n "$TARGET_DISK" ] ; then
  export DISK="${TARGET_DISK}"
else # otherwise try to find sane default
  if [ -L /sys/block/vda ] ; then
    export DISK=vda # will be configured as /dev/vda
  else
    # in some cases, sda is not the HDD, but the CDROM,
    # so better walk through all devices.
    for i in /sys/block/sd*; do
      if grep -q 0 "${i}/removable"; then
        DISK=$(basename "$i")
        export DISK
        break
      fi
    done
  fi
fi

SWRAID=false
if [[ -n "${SWRAID_DISK1}" ]] && [[ -z "${SWRAID_DISK2}" ]] ; then
  die "Error: swraiddisk1 is set, but swraiddisk2 is unset."
elif [[ -z "${SWRAID_DISK1}" ]] && [[ -n "${SWRAID_DISK2}" ]] ; then
  die "Error: swraiddisk2 is set, but swraiddisk1 is unset."
elif [[ -n "${SWRAID_DISK1}" ]] && [[ -n "${SWRAID_DISK2}" ]] ; then
  echo "Identified valid boot options for Software RAID setup."
  SWRAID=true
else
  [[ -z "${DISK}" ]] && die "Error: No non-removable disk suitable for installation found"
fi

if checkBootParam 'ngcpstatus=' ; then
  STATUS_WAIT=$(getBootParam ngcpstatus)
  [ -n "$STATUS_WAIT" ] || STATUS_WAIT=30
fi

if checkBootParam noinstall ; then
  echo "Exiting as requested via bootoption noinstall."
  exit 0
fi

if checkBootParam nocolorlogo ; then
  LOGO=false
fi

if checkBootParam 'ngcpmgmt=' ; then
  MANAGEMENT_IP=$(getBootParam ngcpmgmt)
  RETRIEVE_MGMT_CONFIG=true
fi

## detect environment {{{
CHASSIS="No physical chassis found"
if dmidecode| grep -q 'Rack Mount Chassis' ; then
  CHASSIS="Running in Rack Mounted Chassis."
elif dmidecode| grep -q 'Location In Chassis: Not Specified'; then
  :
elif dmidecode| grep -q 'Location In Chassis'; then
  CHASSIS="Running in blade chassis $(dmidecode| awk '/Location In Chassis: Slot/ {print $4}')"
fi

if checkBootParam ngcpinst || checkBootParam ngcpsp1 || checkBootParam ngcpsp2 || \
  checkBootParam ngcppro || checkBootParam ngcpce ; then
  NGCP_INSTALLER=true
fi

if checkBootParam ngcpce ; then
  CE_EDITION=true
  NGCP_INSTALLER_EDITION_STR="Sipwise C5:        CE"
elif checkBootParam ngcppro || checkBootParam ngcpsp1 || checkBootParam ngcpsp2 ; then
  PRO_EDITION=true
  NGCP_INSTALLER_EDITION_STR="Sipwise C5:        PRO"
  if checkBootParam ngcpsp2 ; then
    ROLE=sp2
  else
    ROLE=sp1
  fi
elif checkBootParam "nongcp" ; then
  # installing plain debian without NGCP
  NGCP_INSTALLER_EDITION_STR=""
elif checkBootParam "puppetenv=" ; then
  # will be determined later
  :
else
  echo "Error: Could not determine 'edition' (spce, sppro, carrier)."
  exit 1
fi

# Carrier is a specialisation of Pro, Pro Role variables are needed
if checkBootParam 'ngcpcrole=' ; then
  CROLE=$(getBootParam ngcpcrole)
  CARRIER_EDITION=true
  NGCP_INSTALLER_EDITION_STR="Sipwise C5:        CARRIER"
fi

if checkBootParam "puppetenv=" ; then
  # we expected to get the environment for puppet
  PUPPET=$(getBootParam puppetenv)
fi

if checkBootParam "puppetserver=" ; then
  PUPPET_SERVER=$(getBootParam puppetserver)
fi

if checkBootParam "puppetgitrepo=" ; then
  PUPPET_GIT_REPO=$(getBootParam puppetgitrepo)
fi

if checkBootParam "puppetgitbranch=" ; then
  PUPPET_GIT_BRANCH=$(getBootParam puppetgitbranch)
fi

if checkBootParam "debianrelease=" ; then
  DEBIAN_RELEASE=$(getBootParam debianrelease)
fi

ARCH=$(dpkg --print-architecture)
if checkBootParam "arch=" ; then
  ARCH=$(getBootParam arch)
fi

# existing ngcp releases (like 2.2) with according repository and installer
if checkBootParam 'ngcpvers=' ; then
  SP_VERSION=$(getBootParam ngcpvers)
  if [ "${SP_VERSION:-}" = "trunk" ] ; then
    TRUNK_VERSION=true
  fi
fi

if checkBootParam nongcp ; then
  echo "Will not execute ngcp-installer as requested via bootoption nongcp."
  NGCP_INSTALLER=false
fi

# configure static network in installed system?
if checkBootParam ngcpnw.dhcp || pgrep dhclient &>/dev/null ; then
  DHCP=true
fi

if checkBootParam 'ngcphostname=' ; then
  TARGET_HOSTNAME="$(getBootParam ngcphostname)"
fi

if checkBootParam 'ngcpip1=' ; then
  IP1=$(getBootParam ngcpip1)
fi

if checkBootParam 'ngcpip2=' ; then
  IP2=$(getBootParam ngcpip2)
fi

if checkBootParam 'ngcpipshared=' ; then
  IP_HA_SHARED=$(getBootParam ngcpipshared)
fi

if checkBootParam 'ngcpnetmask=' ; then
  INTERNAL_NETMASK=$(getBootParam ngcpnetmask)
fi

if checkBootParam 'ngcpextnetmask=' ; then
  EXTERNAL_NETMASK=$(getBootParam ngcpextnetmask)
fi

if checkBootParam 'ngcpeaddr=' ; then
  EADDR=$(getBootParam ngcpeaddr)
fi

if checkBootParam "rootfssize=" ; then
  ROOTFS_SIZE=$(getBootParam rootfssize)
fi

if checkBootParam "fallbackfssize=" ; then
  FALLBACKFS_SIZE=$(getBootParam fallbackfssize)
fi

if checkBootParam ngcphalt ; then
  HALT=true
fi

if checkBootParam ngcpreboot ; then
  REBOOT=true
fi

if checkBootParam vagrant ; then
  VAGRANT=true
fi

if checkBootParam lowperformance ; then
  ADJUST_FOR_LOW_PERFORMANCE=true
fi

if checkBootParam enablevmservices ; then
  ENABLE_VM_SERVICES=true
fi

if checkBootParam "debianrepo=" ; then
  DEBIAN_REPO_HOST=$(getBootParam debianrepo)
fi

if checkBootParam "sipwiserepo=" ; then
  SIPWISE_REPO_HOST=$(getBootParam sipwiserepo)
fi

if checkBootParam ngcpnomysqlrepl ; then
  DPL_MYSQL_REPLICATION=false
fi

if checkBootParam 'ngcpvlanbootint=' ; then
  VLAN_BOOT_INT=$(getBootParam ngcpvlanbootint)
fi

if checkBootParam 'ngcpvlansshext=' ; then
  VLAN_SSH_EXT=$(getBootParam ngcpvlansshext)
fi

if checkBootParam 'ngcpvlanwebext=' ; then
  VLAN_WEB_EXT=$(getBootParam ngcpvlanwebext)
fi

if checkBootParam 'ngcpvlansipext=' ; then
  VLAN_SIP_EXT=$(getBootParam ngcpvlansipext)
fi

if checkBootParam 'ngcpvlansipint=' ; then
  VLAN_SIP_INT=$(getBootParam ngcpvlansipint)
fi

if checkBootParam 'ngcpvlanhaint=' ; then
  VLAN_HA_INT=$(getBootParam ngcpvlanhaint)
fi

if checkBootParam 'ngcpvlanrtpext=' ; then
  VLAN_RTP_EXT=$(getBootParam ngcpvlanrtpext)
fi

if checkBootParam 'ngcpppa=' ; then
  NGCP_PPA=$(getBootParam ngcpppa)
fi

if checkBootParam 'debianrepotransport=' ; then
  DEBIAN_REPO_TRANSPORT=$(getBootParam debianrepotransport)
fi

if checkBootParam 'sipwiserepotransport=' ; then
  SIPWISE_REPO_TRANSPORT=$(getBootParam sipwiserepotransport)
fi

if checkBootParam 'debootstrapkey=' ; then
  GPG_KEY=$(getBootParam debootstrapkey)
fi

if checkBootParam 'ngcppxeinstall' ; then
  NGCP_PXE_INSTALL=true
fi

if checkBootParam 'swapfilesize=' ; then
  SWAPFILE_SIZE_MB=$(getBootParam swapfilesize)
fi

DEBIAN_URL="${DEBIAN_REPO_TRANSPORT}://${DEBIAN_REPO_HOST}"
SIPWISE_URL="${SIPWISE_REPO_TRANSPORT}://${SIPWISE_REPO_HOST}"

## }}}

## interactive mode {{{
# support command line options, overriding autodetected defaults
INTERACTIVE=true

if [ -n "$NETSCRIPT" ] ; then
  echo "Automatic deployment via bootoption netscript detected."
  INTERACTIVE=false
fi

usage() {
  echo "$0 - automatically deploy Debian ${DEBIAN_RELEASE} and (optionally) ngcp ce/pro.

Control installation parameters:

  ngcppro          - install Pro Edition
  ngcpsp1          - install first node (Pro Edition only)
  ngcpsp2          - install second node (Pro Edition only)
  ngcpce           - install CE Edition
  ngcpcrole=...    - server role (Carrier)
  ngcpvers=...     - install specific SP/CE version
  nongcp           - do not install NGCP but install plain Debian only
  noinstall        - do not install neither Debian nor NGCP
  ngcpinst         - force usage of NGCP installer
  ngcpinstvers=... - use specific NGCP installer version
  debianrepo=...   - hostname of Debian APT repository mirror
  sipwiserepo=...  - hostname of Sipwise APT repository mirror
  ngcpnomysqlrepl  - skip MySQL sp1<->sp2 replication configuration/check
  ngcpppa=...      - use NGCP PPA Debian repository

Control target system:

  ngcpnw.dhcp      - use DHCP as network configuration in installed system
  ngcphostname=... - hostname of installed system (defaults to ngcp/sp[1,2])
                     NOTE: do NOT use when installing Pro Edition!
  ngcpeiface=...   - external interface device (defaults to eth0)
  ngcpip1=...      - IP address of first node
  ngcpip2=...      - IP address of second node
  ngcpipshared=... - HA shared IP address
  ngcpnetmask=...  - netmask of ha_int interface
  ngcpeaddr=...    - Cluster IP address
  swapfilesize=... - size of swap file in megabytes

The command line options correspond with the available bootoptions.
Command line overrides any present bootoption.

Usage examples:

  # ngcp-deployment ngcpce ngcpnw.dhcp

  # netcardconfig # configure eth0 with static configuration
  # ngcp-deployment ngcppro ngcpsp1

  # netcardconfig # configure eth0 with static configuration
  # ngcp-deployment ngcppro ngcpsp2
"
}

for param in "$@" ; do
  case $param in
    *-h*|*--help*|*help*) usage ; exit 0;;
    *ngcpsp1*) ROLE=sp1 ; TARGET_HOSTNAME=sp1; PRO_EDITION=true; CE_EDITION=false ; NGCP_INSTALLER=true ;;
    *ngcpsp2*) ROLE=sp2 ; TARGET_HOSTNAME=sp2; PRO_EDITION=true; CE_EDITION=false ; NGCP_INSTALLER=true ;;
    *ngcppro*) PRO_EDITION=true; CE_EDITION=false ; NGCP_INSTALLER=true ;;
    *ngcpce*) PRO_EDITION=false; CE_EDITION=true ; TARGET_HOSTNAME=spce ; ROLE='' ; NGCP_INSTALLER=true ;;
    *ngcpvers=*) SP_VERSION="${param//ngcpvers=/}";;
    *nongcp*) NGCP_INSTALLER=false;;
    *noinstall*) NGCP_INSTALLER=false;;
    *ngcpinst*) NGCP_INSTALLER=true;;
    *ngcphostname=*) TARGET_HOSTNAME="${param//ngcphostname=/}";;
    *ngcpeaddr=*) EADDR="${param//ngcpeaddr=/}";;
    *ngcpip1=*) IP1="${param//ngcpip1=/}";;
    *ngcpip2=*) IP2="${param//ngcpip2=/}";;
    *ngcpipshared=*) IP_HA_SHARED="${param//ngcpipshared=/}";;
    *ngcpnetmask=*) INTERNAL_NETMASK="${param//ngcpnetmask=/}";;
    *ngcpextnetmask=*) EXTERNAL_NETMASK="${param//ngcpextnetmask=/}";;
    *ngcpcrole=*) CARRIER_EDITION=true; CROLE="${param//ngcpcrole=/}";;
    *ngcpnw.dhcp*) DHCP=true;;
    *ngcphalt*) HALT=true;;
    *ngcpreboot*) REBOOT=true;;
    *vagrant*) VAGRANT=true;;
    *lowperformance*) ADJUST_FOR_LOW_PERFORMANCE=true;;
    *enablevmservices*) ENABLE_VM_SERVICES=true;;
    *ngcpvlanbootint*) VLAN_BOOT_INT="${param//ngcpvlanbootint=/}";;
    *ngcpvlansshext*) VLAN_SSH_EXT="${param//ngcpvlansshext=/}";;
    *ngcpvlanwebext*) VLAN_WEB_EXT="${param//ngcpvlanwebext=/}";;
    *ngcpvlansipext*) VLAN_SIP_EXT="${param//ngcpvlansipext=/}";;
    *ngcpvlansipint*) VLAN_SIP_INT="${param//ngcpvlansipint=/}";;
    *ngcpvlanhaint*) VLAN_HA_INT="${param//ngcpvlanhaint=/}";;
    *ngcpvlanrtpext*) VLAN_RTP_EXT="${param//ngcpvlanrtpext=/}";;
    *ngcpppa*) NGCP_PPA="${param//ngcpppa=/}";;
    *swapfilesize*) SWAPFILE_SIZE_MB="${param//swapfilesize=/}";;
  esac
  shift
done

ensure_packages_installed

case "${DEBIAN_RELEASE}" in
  buster)
    UPGRADE_PACKAGES=()
    echo "Upgrading grml-scripts + grml-debootstrap for usage with LVM on Debian/buster"

    if ! check_package_version grml-scripts 2.8.4 ; then
      UPGRADE_PACKAGES+=( grml-scripts )
    fi

    if ! check_package_version grml-debootstrap 0.86 ; then
      UPGRADE_PACKAGES+=( grml-debootstrap )
    fi

    ensure_recent_package_versions
    ;;
esac


if ! "$NGCP_INSTALLER" ; then
  CARRIER_EDITION=false
  PRO_EDITION=false
  CE_EDITION=false
  unset ROLE
fi

set_deploy_status "getconfig"

# when using ip=....:$HOSTNAME:eth0:off file /etc/hosts doesn't contain the
# hostname by default, avoid warning/error messages in the host system
# and use it for IP address check in pro edition
if [ -z "$TARGET_HOSTNAME" ] ; then
  if "$PRO_EDITION" ; then
    TARGET_HOSTNAME="$ROLE"
  elif "$CE_EDITION" ; then
    TARGET_HOSTNAME="spce"
  fi

  # if we don't install ngcp ce/pro but
  # $HOSTNAME is set via ip=.... then
  # take it, otherwise fall back to safe default
  if [ -z "$TARGET_HOSTNAME" ] ; then
    if [ -n "$HOSTNAME" ] ; then
      TARGET_HOSTNAME="$HOSTNAME"
    else
      TARGET_HOSTNAME="debian"
    fi
  fi
fi

[ -z "$HOSTNAME" ] && HOSTNAME="nohostname"
if [ -n "$TARGET_HOSTNAME" ] ; then
  HOSTNAME="$TARGET_HOSTNAME"
fi
export HOSTNAME

# get install device from "ip=<client-ip:<srv-ip>:..." boot arg
if checkBootParam 'ip=' ; then
  declare -A IP_ARR
  if loadNfsIpArray IP_ARR "$(getBootParam ip)" ; then
    INSTALL_DEV=${IP_ARR[device]}
    EXT_GW=${IP_ARR[gw-ip]}
    [[ "${IP_ARR[autoconf]}" == 'dhcp' ]] && DHCP=true
  fi
fi

cdr2mask () {
  # From https://stackoverflow.com/questions/20762575/explanation-of-convertor-of-cidr-to-netmask-in-linux-shell-netmask2cdir-and-cdir
  # Number of args to shift, 255..255, first non-255 byte, zeroes
  set -- $(( 5 - ("${1}" / 8) )) 255 255 255 255 $(( (255 << (8 - ("${1}" % 8))) & 255 )) 0 0 0
  if [[ "${1}" -gt 1 ]] ; then
    shift "${1}"
  else
    shift
  fi
  echo "${1:-0}.${2:-0}.${3:-0}.${4:-0}"
}

# Get current IP
## try ipv4
INSTALL_DEV=$(ip -4 r | awk '/default/ {print $5; exit}')
if [[ -z "${INSTALL_DEV}" ]]; then
  ## try ipv6
  INSTALL_DEV=$(ip -6 r | awk '/default/ {print $3; exit}')
  INSTALL_IP=$(ip -6 addr show "${INSTALL_DEV}" | sed -rn 's/^[ ]+inet6 ([a-fA-F0-9:]+)\/.*$/\1/p')
else
  external_ip_data=( $( ip -4 addr show "${INSTALL_DEV}" | sed -rn 's/^[ ]+inet ([0-9]+(\.[0-9]+){3})\/([0-9]+).*$/\1 \3/p' ) )
  INSTALL_IP="${external_ip_data[0]}"
  current_netmask="$( cdr2mask "${external_ip_data[1]}" )"
  EXTERNAL_NETMASK="${EXTERNAL_NETMASK:-${current_netmask}}"
  unset external_ip_data current_netmask
  GW="$(ip route show dev "${INSTALL_DEV}" | awk '/^default via/ {print $3; exit}')"
fi

echo "INSTALL_IP is ${INSTALL_IP}"

IP1="${IP1:-${DEFAULT_IP1}}"
IP2="${IP2:-${DEFAULT_IP2}}"
IP_HA_SHARED="${IP_HA_SHARED:-${DEFAULT_IP_HA_SHARED}}"
EXTERNAL_DEV="${EXTERNAL_DEV:-${INSTALL_DEV}}"
EXTERNAL_IP="${EXTERNAL_IP:-${INSTALL_IP}}"
EADDR="${EXTERNAL_IP:-${EADDR}}"
INTERNAL_NETMASK="${INTERNAL_NETMASK:-${DEFAULT_INTERNAL_NETMASK}}"
MANAGEMENT_IP="${MANAGEMENT_IP:-${IP_HA_SHARED}}"
INTERNAL_DEV="${INTERNAL_DEV:-${DEFAULT_INTERNAL_DEV}}"
if [[ -n "${EXT_GW}" ]]; then
  GW="${EXT_GW}"
fi
if [[ "${SWRAID}" = "true" ]] ; then
  DISK_INFO="Software-RAID with $SWRAID_DISK1 $SWRAID_DISK2"
else
  DISK_INFO="/dev/$DISK"
fi

set_deploy_status "settings"

### echo settings
[ -n "$SP_VERSION" ] && SP_VERSION_STR=$SP_VERSION || SP_VERSION_STR="<latest>"

echo "Deployment Settings:

  Install ngcp:      $NGCP_INSTALLER
  $NGCP_INSTALLER_EDITION_STR"

echo "
  Target disk:       $DISK_INFO
  Target Hostname:   $TARGET_HOSTNAME
  Installer version: $SP_VERSION_STR
  Install NW iface:  $INSTALL_DEV
  Install IP:        $INSTALL_IP
  Use DHCP in host:  $DHCP

  Installing in chassis? $CHASSIS

" | tee -a /tmp/installer-settings.txt

if "$PRO_EDITION" ; then
  echo "
  Host Role:         $ROLE
  Host Role Carrier: $CROLE

  External NW iface: $EXTERNAL_DEV
  Ext host IP:       $EXTERNAL_IP
  Ext cluster IP:    $EADDR
  Internal NW iface: $INTERNAL_DEV
  Int sp1 host IP:   $IP1
  Int sp2 host IP:   $IP2
  Int sp shared IP:  $IP_HA_SHARED
  Int netmask:       $INTERNAL_NETMASK
  MGMT address:      $MANAGEMENT_IP
" | tee -a /tmp/installer-settings.txt
fi

if "$INTERACTIVE" ; then
  echo "WARNING: Execution will override any existing data!"
  echo "Settings OK? y/N"
  read -r a
  if [[ "${a,,}" != "y" ]] ; then
    echo "Exiting as requested."
    exit 2
  fi
  unset a
fi
## }}}

##### all parameters set #######################################################

set_deploy_status "start"

# measure time of installation procedure - everyone loves stats!
start_seconds=$(cut -d . -f 1 /proc/uptime)

if "$LOGO" ; then
  disable_trace
  GRML_INFO=$(cat /etc/grml_version)
  IP_INFO=$(ip-screen)
  CPU_INFO=$(lscpu | awk '/^CPU\(s\)/ {print $2}')
  RAM_INFO=$(/usr/bin/gawk '/MemTotal/{print $2}' /proc/meminfo)
  DATE_INFO=$(date)
  INSTALLER_TYPE="Install CE: $CE_EDITION PRO: $PRO_EDITION [$ROLE] Carrier: $CARRIER_EDITION [$CROLE]"
  if [ -n "$NGCP_PPA" ] ; then
    PPA_INFO="| PPA: ${NGCP_PPA} "
  fi
  if efi_support ; then
    EFI_INFO="| EFI support"
  else
    EFI_INFO="| no EFI support"
  fi
  if [[ "${SWRAID}" = "true" ]] ; then
    SWRAID_INFO="| SW-RAID support [${SWRAID_DISK1} + ${SWRAID_DISK2}]"
  fi
  # color
  echo -ne "\ec\e[1;32m"
  clear
  #print logo
  echo "+++ Grml-Sipwise Deployment +++"
  echo ""
  echo "$GRML_INFO"
  echo "Host IP(s): $IP_INFO | Deployment version: $SCRIPT_VERSION"
  echo "$CPU_INFO CPU(s) | ${RAM_INFO}kB RAM | $CHASSIS"
  echo ""
  echo "Install ngcp: $NGCP_INSTALLER | $INSTALLER_TYPE"
  echo "Installing $SP_VERSION_STR platform | Debian: $DEBIAN_RELEASE $EFI_INFO $SWRAID_INFO $PPA_INFO"
  echo "Install IP: $INSTALL_IP | Started deployment at $DATE_INFO"
  # number of lines
  echo -ne "\e[10;0r"
  # reset color
  echo -ne "\e[9B\e[1;m"
  enable_trace
fi

# relevant only while deployment, will be overridden later
if [ -n "$HOSTNAME" ] ; then
  cat > /etc/hosts << EOF
127.0.0.1       grml    localhost
::1     ip6-localhost ip6-loopback grml
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts

127.0.0.1 $ROLE $HOSTNAME
$INSTALL_IP $ROLE $HOSTNAME
EOF
fi

# remote login ftw
service ssh start >/dev/null &
echo "root:sipwise" | chpasswd

## partition disk
set_deploy_status "disksetup"

if "$NGCP_INSTALLER" ; then
  VG_NAME="ngcp"
else
  VG_NAME="vg0"
fi

clear_partition_table() {
  local blockdevice="$1"

  if [[ ! -b "${blockdevice}" ]] ; then
    die "Error: ${blockdevice} doesn't look like a valid block device." >&2
  fi

  echo "Wiping disk signatures from ${blockdevice}"
  wipefs -a "${blockdevice}"

  # make sure parted doesn't fail if LVM is already present
  blockdev --rereadpt "$blockdevice"
  for disk in "$blockdevice"* ; do
    existing_pvs=$(pvs "$disk" -o vg_name --noheadings 2>/dev/null || true)
    if [ -n "$existing_pvs" ] ; then
      for pv in $existing_pvs ; do
        echo "Getting rid of existing VG $pv"
        vgremove -ff "$pv"
      done
    fi

    echo "Removing possibly existing LVM/PV label from $disk"
    pvremove "$disk" --force --force --yes || true
  done

  dd if=/dev/zero of="${blockdevice}" bs=1M count=1
  blockdev --rereadpt "${blockdevice}"
}

get_pvdevice_by_label() {
  local blockdevice="$1"
  if [[ -z "${blockdevice}" ]]; then
    die "Error: need a blockdevice to probe, nothing provided."
  fi
  local partlabel="$2"
  if [[ -z "${partlabel}" ]]; then
    die "Error: need a partlabel to search for, nothing provided."
  fi

  local pvdevice=""
  pvdevice=$(blkid -t PARTLABEL="${partlabel}" -o device "${blockdevice}"* || true)
  echo "${pvdevice}"
}

get_pvdevice_by_label_with_retries() {
  if [[ $# -ne 4 ]]; then
    die "Error: needs 4 arguments: a BLOCKDEVICE to probe, a PARTLABEL to search for, MAX_TRIES and name of variable to return PVDEVICE."
  fi

  local blockdevice="$1"
  if [[ -z "${blockdevice}" ]]; then
    die "Error: need a blockdevice to probe, nothing provided."
  fi
  local partlabel="$2"
  if [[ -z "${partlabel}" ]]; then
    die "Error: need a partlabel to search for, nothing provided."
  fi
  local max_tries="$3"
  if [[ -z "${max_tries}" ]]; then
    die "Error: need max_tries, nothing provided."
  fi
  # return result in this variable
  # shellcheck disable=SC2034
  declare -n ret="$4"

  local pvdevice_local
  for try in $(seq 1 "${max_tries}"); do
    pvdevice_local=$(get_pvdevice_by_label "${blockdevice}" "${partlabel}")
    if [[ -n "${pvdevice_local}" ]]; then
      echo "pvdevice is now available: ${pvdevice_local}"
      # it's a reference to an external variable that sets the return value
      # shellcheck disable=SC2034
      ret="${pvdevice_local}"
      break
    else
      if [[ "${try}" -lt "${max_tries}" ]]; then
        echo "pvdevice not yet available (blockdevice=${blockdevice}, partlabel='${partlabel}'), try #${try} of ${max_tries}, retrying in 1 second..."
        sleep 1s
      else
        die "Error: could not get pvdevice after #${try} tries"
      fi
    fi
  done
}

parted_execution() {
  local blockdevice="$1"

  echo "Creating partition table"
  parted -a optimal -s "${blockdevice}" mklabel gpt

  # BIOS boot with GPT
  parted -a optimal -s "${blockdevice}" mkpart primary 2048s 2M
  parted -a optimal -s "${blockdevice}" set 1 bios_grub on
  parted -a optimal -s "${blockdevice}" "name 1 'BIOS Boot'"

  # EFI boot with GPT
  parted -a optimal -s "${blockdevice}" mkpart primary 2M 512M
  parted -a optimal -s "${blockdevice}" "name 2 'EFI System'"
  parted -a optimal -s "${blockdevice}" set 2 boot on

  blockdev --flushbufs "${blockdevice}"

  echo "Get path of EFI partition"
  local max_tries=60
  EFI_PARTITION=""
  get_pvdevice_by_label_with_retries "${blockdevice}" "EFI System" "${max_tries}" EFI_PARTITION
}

set_up_partition_table_noswraid() {
  local blockdevice
  blockdevice="/dev/${DISK}"

  clear_partition_table "$blockdevice"

  parted_execution "$blockdevice"
  parted -a optimal -s "${blockdevice}" mkpart primary 512M 100%
  parted -a optimal -s "${blockdevice}" "name 3 'Linux LVM'"
  parted -a optimal -s "${blockdevice}" set 3 lvm on
  blockdev --flushbufs "${blockdevice}"

  local max_tries=60
  local pvdevice
  local partlabel="Linux LVM"
  get_pvdevice_by_label_with_retries "${blockdevice}" "${partlabel}" "${max_tries}" pvdevice

  echo "Creating PV + VG"
  pvcreate -ff -y "${pvdevice}"
  vgcreate "${VG_NAME}" "${pvdevice}"
  vgchange -a y "${VG_NAME}"
}

set_up_partition_table_swraid() {
  # make sure we don't overlook unassembled SW-RAIDs
  local raidev1
  local raidev2
  mdadm --assemble --scan || true # fails if there's nothing to assemble

  if [[ -b "${SWRAID_DEVICE}" ]] ; then
    if [[ "${SWRAID_DESTROY}" = "true" ]] ; then
      mdadm --remove "${SWRAID_DEVICE}"
      mdadm --stop "${SWRAID_DEVICE}"
      mdadm --zero-superblock "/dev/${SWRAID_DISK1}"
      mdadm --zero-superblock "/dev/${SWRAID_DISK2}"
    else
      echo "NOTE: if you are sure you don't need it SW-RAID device any longer, execute:"
      echo "      mdadm --remove ${SWRAID_DEVICE} ; mdadm --stop ${SWRAID_DEVICE}; mdadm --zero-superblock /dev/sd..."
      echo "      (also you can use boot option 'swraiddestroy' to destroy SW-RAID automatically)"
      die "Error: SW-RAID device ${SWRAID_DEVICE} exists already."
    fi
  fi

  for disk in "${SWRAID_DISK1}" "${SWRAID_DISK2}" ; do
    if grep -q "$disk" /proc/mdstat ; then
      die "Error: disk $disk seems to be part of an existing SW-RAID setup."
    fi
    clear_partition_table "/dev/${disk}"
  done

  parted_execution "/dev/${SWRAID_DISK1}"

  parted -a optimal -s "/dev/${SWRAID_DISK1}" mkpart primary 512M 100%
  parted -a optimal -s "/dev/${SWRAID_DISK1}" "name 3 'Linux RAID'"
  parted -a optimal -s "/dev/${SWRAID_DISK1}" set 3 raid on

  # clone partitioning from SWRAID_DISK1 to SWRAID_DISK2
  sgdisk "/dev/${SWRAID_DISK1}" -R "/dev/${SWRAID_DISK2}"
  # randomize the disk's GUID and all partitions' unique GUIDs after cloning
  sgdisk -G "/dev/${SWRAID_DISK2}"

  local partlabel="Linux RAID"
  local max_tries=60
  get_pvdevice_by_label_with_retries "/dev/${SWRAID_DISK1}" "${partlabel}" "${max_tries}" raidev1
  get_pvdevice_by_label_with_retries "/dev/${SWRAID_DISK2}" "${partlabel}" "${max_tries}" raidev2

  echo y | mdadm --create --verbose "${SWRAID_DEVICE}" --level=1 --raid-devices=2 "${raidev1}" "${raidev2}"

  echo "Creating PV + VG on ${SWRAID_DEVICE}"
  pvcreate -ff -y "${SWRAID_DEVICE}"
  vgcreate "${VG_NAME}" "${SWRAID_DEVICE}"
  vgchange -a y "${VG_NAME}"
}

set_up_partition_table() {
  if [[ "${SWRAID}" = "true" ]] ; then
    set_up_partition_table_swraid
  else
    set_up_partition_table_noswraid
  fi
}

create_ngcp_partitions() {
  # root
  echo "Creating LV 'root' with ${ROOTFS_SIZE}"
  lvcreate --yes -n root -L "${ROOTFS_SIZE}" "${VG_NAME}"

  echo "Creating ${FILESYSTEM} filesystem on /dev/${VG_NAME}/root"
  mkfs."${FILESYSTEM}" -FF /dev/"${VG_NAME}"/root

  # used later by installer
  ROOT_FS="/dev/mapper/${VG_NAME}-root"

  # fallback
  if [[ "${FALLBACKFS_SIZE}" != "0" ]]; then
    echo "Creating LV 'fallback' with ${FALLBACKFS_SIZE}"
    lvcreate --yes -n fallback -L "${FALLBACKFS_SIZE}" "${VG_NAME}"

    echo "Creating ${FILESYSTEM} filesystem on /dev/${VG_NAME}/fallback"
    mkfs."${FILESYSTEM}" -FF /dev/"${VG_NAME}"/fallback

    # used later by installer
    FALLBACK_FS="/dev/mapper/${VG_NAME}-fallback"
  fi

  # data
  local vg_free data_size unassigned
  vg_free=$(vgs "${VG_NAME}" -o vg_free --noheadings --nosuffix --units B)
  data_size=$(( vg_free * 18 / 20 )) # 90% of free space (in MB)
  unassigned=$(( vg_free - data_size ))
  # make sure we have 10% or at least 500MB unassigned space
  if [[ "${unassigned}" -lt 524288000 ]] ; then # 500MB
    data_size=$(( vg_free - 524288000 ))
  fi

  local data_size_mb
  data_size_mb=$(( data_size / 1024 / 1024 ))
  echo "Creating LV data with ${data_size_mb}M"
  lvcreate --yes -n data -L "${data_size_mb}M" "${VG_NAME}"

  echo "Creating ${FILESYSTEM} on /dev/${VG_NAME}/data"
  mkfs."${FILESYSTEM}" -FF /dev/"${VG_NAME}"/data

  # used later by installer
  DATA_PARTITION="/dev/mapper/${VG_NAME}-data"
}

create_debian_partitions() {
  # rootfs
  local root_size=8G
  echo "Creating LV root with ${root_size}"
  lvcreate --yes -n root -L "${root_size}" "${VG_NAME}"

  echo "Creating ${FILESYSTEM} on /dev/${VG_NAME}/root"
  mkfs."${FILESYSTEM}" -FF /dev/"${VG_NAME}"/root

  # used later by installer
  ROOT_FS="/dev/mapper/${VG_NAME}-root"
}

display_partition_table() {
  local blockdevice
  if [[ "${SWRAID}" = "true" ]] ; then
    for disk in "${SWRAID_DISK1}" "${SWRAID_DISK2}" ; do
      echo "Displaying partition table (of SW-RAID disk /dev/$disk) for reference:"
      parted -s "/dev/${disk}" unit GiB print
      lsblk "/dev/${disk}"
    done
  else
    echo "Displaying partition table (of /dev/$disk) for reference:"
    parted -s "/dev/${DISK}" unit GiB print
    lsblk "/dev/${DISK}"
  fi
}

lvm_setup() {
  local saved_options
  saved_options="$(set +o)"
  # be restrictive in what we execute
  set -euo pipefail

  if "$NGCP_INSTALLER" ; then
    VG_NAME="ngcp"
    set_up_partition_table
    create_ngcp_partitions
    display_partition_table
  else
    VG_NAME="vg0"
    set_up_partition_table
    create_debian_partitions
    display_partition_table
  fi

  # used later by installer
  ROOT_FS="/dev/mapper/${VG_NAME}-root"

  # restore original options/behavior
  eval "$saved_options"
}

lvm_setup

# otherwise e2fsck fails with "need terminal for interactive repairs"
echo FSCK=no >>/etc/debootstrap/config

echo "Clean the default /etc/debootstrap/packages"
echo > /etc/debootstrap/packages

if ! "$NGCP_INSTALLER" ; then

  echo "Install some packages to be able to login on the Debian plain system"
  cat >> /etc/debootstrap/packages << EOF
# to be able to login on the Debian plain system via SSH
openssh-server

# deployment supports LVM only
lvm2
EOF

  if [[ "${SWRAID}" = "true" ]] ; then
    cat >> /etc/debootstrap/packages << EOF
# required for Software-RAID support on plain debian and Puppet recovery
grub-pc
EOF
  fi

else # "$NGCP_INSTALLER" = true

  echo "Install some essential packages for NGCP bootstrapping"
  # WARNING: consider to add NGCP packages to NGCP metapackage!
  cat >> /etc/debootstrap/packages << EOF
# to be able to retrieve files, starting with Debian/buster no longer present by default
wget
# required for Software-RAID support
mdadm
EOF

fi # if ! "$NGCP_INSTALLER" ; then

# NOTE: we use the debian.sipwise.com CNAME by intention here
# to avoid conflicts with apt-pinning, preferring deb.sipwise.com
# over official Debian
MIRROR="${DEBIAN_URL}/debian/"
SEC_MIRROR="${DEBIAN_URL}/debian-security/"
DBG_MIRROR="${DEBIAN_URL}/debian-debug/"

if [ -z "${GPG_KEY}" ] ; then
  KEYRING="${SIPWISE_APT_KEY_PATH}"
else
  KEYRING='/etc/apt/trusted.gpg'

  echo "Fetching debootstrap keyring as GPG key '${GPG_KEY}'..."

  TRY=60
  while ! gpg --keyserver "${GPG_KEY_SERVER}" --recv-keys "${GPG_KEY}" ; do
    if [ ${TRY} -gt 0 ] ; then
      TRY=$((TRY-5))
      echo "Waiting for gpg keyserver '${GPG_KEY_SERVER}' availability ($TRY seconds)..."
      sleep 5
    else
      die "Failed to fetch GPG key '${GPG_KEY}' from '${GPG_KEY_SERVER}'"
    fi
  done

  if ! gpg -a --export "${GPG_KEY}" | apt-key add - ; then
    die "Failed to import GPG key '${GPG_KEY}' as apt-key"
  fi
fi

set_deploy_status "debootstrap"

mkdir -p /etc/debootstrap/etc/apt/
echo "Setting up /etc/debootstrap/etc/apt/sources.list"
cat > /etc/debootstrap/etc/apt/sources.list << EOF
# Set up via deployment.sh for grml-debootstrap usage
deb ${MIRROR} ${DEBIAN_RELEASE} main contrib non-free
deb ${SEC_MIRROR} ${DEBIAN_RELEASE}-security main contrib non-free
deb ${MIRROR} ${DEBIAN_RELEASE}-updates main contrib non-free
deb ${DBG_MIRROR} ${DEBIAN_RELEASE}-debug main contrib non-free
EOF

case "$DEBIAN_RELEASE" in
  stretch|buster)
    if ! [ -r "/usr/share/debootstrap/scripts/${DEBIAN_RELEASE}" ] ; then
      echo "Enabling ${DEBIAN_RELEASE} support for debootstrap via symlink to sid"
      ln -s /usr/share/debootstrap/scripts/sid "/usr/share/debootstrap/scripts/${DEBIAN_RELEASE}"
    fi
    ;;
esac

# defaults
DEBOPT_OPTIONS=("--keyring=${KEYRING} --no-merged-usr")
if checkBootParam nommdebstrap ; then
  echo "Boot option nommdebstrap found, disabling usage of mmdebstrap for installing Debian"
else
  # mmdebstrap is available only since buster, so ensure we're running on
  # a buster based Grml ISO
  case $(cat /etc/debian_version) in
    buster*|10*)
      echo "Using mmdebstrap for bootstrapping Debian"
      ADDITIONAL_PACKAGES+=(mmdebstrap)
      ensure_packages_installed
      export DEBOOTSTRAP=mmdebstrap  # for usage with grml-debootstrap
      # it's a no-op in mmdebstrap v0.4.1, but force its usage to not be surprised
      # if that default should ever change
      DEBOPT_OPTIONS=("--no-merged-usr")
      ;;
    *)
      echo "NOTE: not running on top of a Debian/buster based ISO, can't enable mmdebstrap usage"
      ;;
  esac
fi


if [[ -n "${EFI_PARTITION}" ]] ; then
  if efi_support ; then
    echo "EFI support present, enabling EFI support within grml-debootstrap"
    EFI_OPTION="--efi ${EFI_PARTITION}"
  else
    echo "EFI support NOT present, not enabling EFI support within grml-debootstrap"
  fi
fi

# Add sipwise key into chroot
debootstrap_sipwise_key

# install Debian
# shellcheck disable=SC2086
echo y | grml-debootstrap \
  --arch "${ARCH}" \
  --grub "/dev/${DISK}" \
  --filesystem "${FILESYSTEM}" \
  --hostname "${TARGET_HOSTNAME}" \
  --mirror "$MIRROR" \
  --debopt "${DEBOPT_OPTIONS[*]}" \
  --keep_src_list \
  --defaultinterfaces \
  -r "$DEBIAN_RELEASE" \
  -t "$ROOT_FS" \
  $EFI_OPTION \
  --password 'sipwise' 2>&1 | tee -a /tmp/grml-debootstrap.log

if [ "${PIPESTATUS[1]}" != "0" ]; then
  die "Error during installation of Debian ${DEBIAN_RELEASE}. Find details via: mount $ROOT_FS $TARGET ; ls $TARGET/debootstrap/*.log"
fi

sync
mount "$ROOT_FS" "$TARGET"

if [ -n "${DATA_PARTITION}" ] ; then
  mkdir -p "${TARGET}/ngcp-data"
fi

if [ -n "${FALLBACK_FS}" ] ; then
  mkdir -p "${TARGET}/ngcp-fallback"
fi

# TT#56903: mmdebstrap 0.4.1-2 does not properly remove this dir.
if [ -d "${TARGET}/var/lib/apt/lists/auxfiles" ]; then
  echo "Removing apt's > 1.6 auxfiles directory"
  rmdir "${TARGET}/var/lib/apt/lists/auxfiles"
fi

# MT#7805
if "$NGCP_INSTALLER" ; then
  cat << EOT | augtool --root="$TARGET"
insert opt after /files/etc/fstab/*[file="/"]/opt[last()]
set /files/etc/fstab/*[file="/"]/opt[last()] noatime
save
EOT
fi

# TT#41500: Make sure the timezone setup is coherent
grml-chroot "$TARGET" dpkg-reconfigure --frontend=noninteractive tzdata

# provide useable /ngcp-data partition
if [ -n "${DATA_PARTITION}" ] ; then
  echo "Enabling ngcp-data partition ${DATA_PARTITION} via /etc/fstab"
  cat >> "${TARGET}/etc/fstab" << EOF
${DATA_PARTITION} /ngcp-data               auto           noatime               0  0
EOF

  # Make sure /ngcp-data is mounted inside chroot
  # (some package might need to create folders structure on .postinst)
  grml-chroot "${TARGET}" mount /ngcp-data
fi

# provide useable /ngcp-fallback read-only partition
if [ -n "${FALLBACK_FS}" ] ; then
  echo "Enabling ngcp-fallback partition ${FALLBACK_FS} via /etc/fstab"
  cat >> "${TARGET}/etc/fstab" << EOF
${FALLBACK_FS} /ngcp-fallback               auto          ro,noatime,nofail     0  0
EOF
fi

if [[ -z "${SWAPFILE_SIZE_MB}" ]]; then
  # TT#11444 Calculate size of swapfile
  ramsize_mb="$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 1024))"
  SWAPFILE_SIZE_MB="$(( ramsize_mb / 2))"
  if [[ "${SWAPFILE_SIZE_MB}" -lt "${SWAPFILE_SIZE_MB_MIN}" ]]; then
    SWAPFILE_SIZE_MB="${SWAPFILE_SIZE_MB_MIN}"
  elif [[ "${SWAPFILE_SIZE_MB}" -gt "${SWAPFILE_SIZE_MB_MAX}" ]]; then
    SWAPFILE_SIZE_MB="${SWAPFILE_SIZE_MB_MAX}"
  fi
  SWAPFILE_SIZE_MB="${SWAPFILE_SIZE_MB}M"
  unset ramsize_mb
fi

# get rid of automatically installed packages
chroot $TARGET apt-get --purge -y autoremove

# purge removed packages
removed_packages=( $(chroot $TARGET dpkg --list | awk '/^rc/ {print $2}') )
if [ ${#removed_packages[@]} -ne 0 ]; then
  chroot "$TARGET" dpkg --purge "${removed_packages[@]}"
fi

# make sure `hostname` and `hostname --fqdn` return data from chroot
grml-chroot $TARGET hostname -F /etc/hostname

# make sure installations of packages works, will be overridden later again
cat > $TARGET/etc/hosts << EOF
127.0.0.1       localhost
127.0.0.1       ${HOSTNAME}. ${HOSTNAME}

::1             ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

# get list of available network devices
# (excl. some known-to-be-irrelevant ones, also see MT#8297)
NETWORK_DEVICES="$(tail -n +3 /proc/net/dev | sed -r 's/^ *([0-9a-zA-Z]+):.*$/\1/g' | \
  grep -ve '^vmnet' -ve '^vboxnet' -ve '^docker' -ve '^usb' -ve '^vlan' -ve '^bond' | sort -u)"

if "$PRO_EDITION" && [[ $(imvirt) != "Physical" ]] ; then
  echo "Generating udev persistent net rules."
  echo "## Generated by Sipwise deployment script" > \
    "${TARGET}/etc/udev/rules.d/70-persistent-net.rules"
  for dev in ${NETWORK_DEVICES}; do
    [[ "${dev}" =~ ^lo ]] && continue

    mac=$(udevadm info -a -p "/sys/class/net/${dev}" | sed -nr 's/^ *ATTR\{address\}=="(.+)".*$/\1/p')
    if [[ "${mac}" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
      echo "Adding device '${dev}' with MAC '${mac}'"
      cat >> "${TARGET}/etc/udev/rules.d/70-persistent-net.rules" <<EOL
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{address}=="${mac}", ATTR{dev_id}=="0x0", ATTR{type}=="1", KERNEL=="eth*", NAME="${dev}"
EOL
    fi
  done
  unset mac
fi

get_installer_path() {
  if [ -z "$SP_VERSION" ] && ! $TRUNK_VERSION ; then
    INSTALLER=ngcp-installer-latest.deb

    if "$PRO_EDITION" ; then
      INSTALLER_PATH="${SIPWISE_URL}/sppro/"
    else
      INSTALLER_PATH="${SIPWISE_URL}/spce/"
    fi

    return # we don't want to run any further code from this function
  fi

  # use pool directory according for ngcp release
  if "$PRO_EDITION" ; then
    if "$CARRIER_EDITION" ; then
      local installer_package='ngcp-installer-carrier'
    else
      local installer_package='ngcp-installer-pro'
    fi
    local repos_base_path="${SIPWISE_URL}/sppro/${SP_VERSION}/dists/${DEBIAN_RELEASE}/main/binary-amd64/"
    INSTALLER_PATH="${SIPWISE_URL}/sppro/${SP_VERSION}/pool/main/n/ngcp-installer/"
  else
    local installer_package='ngcp-installer-ce'
    local repos_base_path="${SIPWISE_URL}/spce/${SP_VERSION}/dists/${DEBIAN_RELEASE}/main/binary-amd64/"
    INSTALLER_PATH="${SIPWISE_URL}/spce/${SP_VERSION}/pool/main/n/ngcp-installer/"
  fi

  # use a separate repos for trunk releases
  if $TRUNK_VERSION ; then
    local repos_base_path="${SIPWISE_URL}/autobuild/dists/release-trunk-${DEBIAN_RELEASE}/main/binary-amd64/"
    INSTALLER_PATH="${SIPWISE_URL}/autobuild/pool/main/n/ngcp-installer/"
  fi

  if [ -n "${NGCP_PPA}" ] ; then
    local ppa_tmp_packages
    ppa_tmp_packages=$(mktemp)

    echo "NGCP PPA requested, checking ngcp-installer package availability in PPA repo"
    local ppa_repos_base_path="${SIPWISE_URL}/autobuild/dists/${NGCP_PPA}/main/binary-amd64/"
    wget --timeout=30 -O "${ppa_tmp_packages}" "${ppa_repos_base_path}/Packages.gz"

    local installer_ppa_version
    installer_ppa_version=$(zcat "${ppa_tmp_packages}" | sed "/./{H;\$!d;};x;/Package: ${installer_package}/b;d" | awk '/^Version: / {print $2}' | sort -u)
    rm -f "${ppa_tmp_packages}"

    if [ -n "${installer_ppa_version}" ]; then
      echo "NGCP PPA contains ngcp-installer, using it, version '${installer_ppa_version}'"
      local repos_base_path="${ppa_repos_base_path}"
      INSTALLER_PATH="${SIPWISE_URL}/autobuild/pool/main/n/ngcp-installer/"
    else
      echo "NGCP PPA does NOT contains ngcp-installer, using default ngcp-installer package"
    fi
  fi

  wget --timeout=30 -O Packages.gz "${repos_base_path}Packages.gz"
  # sed: display paragraphs matching the "Package: ..." string, then grab string "^Version: " and display the actual version via awk
  # sort -u to avoid duplicates in repositories shipping the ngcp-installer-pro AND ngcp-installer-pro-ha-v3 debs
  local version
  version=$(zcat Packages.gz | sed "/./{H;\$!d;};x;/Package: ${installer_package}/b;d" | awk '/^Version: / {print $2}' | sort -u)

  [ -n "$version" ] || die "Error: installer version for ngcp ${SP_VERSION}, Debian release $DEBIAN_RELEASE with installer package $installer_package could not be detected."

  if "$CARRIER_EDITION" ; then
    INSTALLER="ngcp-installer-carrier_${version}_all.deb"
  elif "$PRO_EDITION" ; then
    INSTALLER="ngcp-installer-pro_${version}_all.deb"
  else
    INSTALLER="ngcp-installer-ce_${version}_all.deb"
  fi
}

set_repos() {
  cat > $TARGET/etc/apt/sources.list << EOF
# Please visit /etc/apt/sources.list.d/ instead.
EOF

  cat > $TARGET/etc/apt/sources.list.d/debian.list << EOF
## custom sources.list, deployed via deployment.sh

# Debian repositories
deb ${MIRROR} ${DEBIAN_RELEASE} main contrib non-free
deb ${SEC_MIRROR} ${DEBIAN_RELEASE}-security main contrib non-free
deb ${MIRROR} ${DEBIAN_RELEASE}-updates main contrib non-free
deb ${DBG_MIRROR} ${DEBIAN_RELEASE}-debug main contrib non-free
EOF
}

gen_installer_config () {
  local conf_file
  conf_file="${TARGET}/etc/ngcp-installer/config_deploy.inc"
  truncate -s 0 "${conf_file}"
  if "${CARRIER_EDITION}" ; then
    cat >> "${conf_file}" << EOF
CROLE="${CROLE}"
VLAN_BOOT_INT="${VLAN_BOOT_INT}"
VLAN_SSH_EXT="${VLAN_SSH_EXT}"
VLAN_WEB_EXT="${VLAN_WEB_EXT}"
VLAN_SIP_EXT="${VLAN_SIP_EXT}"
VLAN_SIP_INT="${VLAN_SIP_INT}"
VLAN_HA_INT="${VLAN_HA_INT}"
VLAN_RTP_EXT="${VLAN_RTP_EXT}"
EOF
  fi
  if "${PRO_EDITION}" ; then
    cat >> "${conf_file}" << EOF
HNAME="${ROLE}"
IP1="${IP1}"
IP2="${IP2}"
IP_HA_SHARED="${IP_HA_SHARED}"
DPL_MYSQL_REPLICATION="${DPL_MYSQL_REPLICATION}"
TARGET_HOSTNAME="${TARGET_HOSTNAME}"
INTERNAL_DEV="${INTERNAL_DEV}"
NETWORK_DEVICES="${NETWORK_DEVICES}"
INTERNAL_NETMASK="${INTERNAL_NETMASK}"
MANAGEMENT_IP="${MANAGEMENT_IP}"
NGCP_PXE_INSTALL="${NGCP_PXE_INSTALL}"
FILL_APPROX_CACHE="${FILL_APPROX_CACHE}"
EOF
  fi

  cat >> "${conf_file}" << EOF
FORCE=no
ADJUST_FOR_LOW_PERFORMANCE="${ADJUST_FOR_LOW_PERFORMANCE}"
ENABLE_VM_SERVICES="${ENABLE_VM_SERVICES}"
SIPWISE_REPO_HOST="${SIPWISE_REPO_HOST}"
SIPWISE_URL="${SIPWISE_URL}"
NAMESERVER="$(awk '/^nameserver/ {print $2}' /etc/resolv.conf)"
NGCP_PPA="${NGCP_PPA}"
DEBUG_MODE="${DEBUG_MODE}"
EADDR="${EADDR}"
DHCP="${DHCP}"
EXTERNAL_DEV="${EXTERNAL_DEV}"
GW="${GW}"
EXTERNAL_NETMASK="${EXTERNAL_NETMASK}"
ORIGIN_INSTALL_DEV="${INSTALL_DEV}"
FALLBACKFS_SIZE="${FALLBACKFS_SIZE}"
ROOTFS_SIZE="${ROOTFS_SIZE}"
SWAPFILE_SIZE_MB="${SWAPFILE_SIZE_MB}"
DEPLOYMENT_SH=true
EOF

  if "${TRUNK_VERSION}" && checkBootParam ngcpupload ; then
    echo "NGCPUPLOAD=true" >> "${TARGET}/etc/ngcp-installer/config_deploy.inc"
  else
    echo "NGCPUPLOAD=false" >> "${TARGET}/etc/ngcp-installer/config_deploy.inc"
  fi
}

if "$NGCP_INSTALLER" ; then
  set_deploy_status "ngcp-installer"

  echo "Searching for proper ngcp-installer package ..."
  get_installer_path

  echo "Generating debian/sipwise APT repos ..."
  set_repos

  echo "Installing package ngcp-installer: ${INSTALLER}"
  grml-chroot "${TARGET}" wget "${INSTALLER_PATH}/${INSTALLER}"
  grml-chroot "${TARGET}" dpkg -i "${INSTALLER}"
  grml-chroot "${TARGET}" rm -f "${INSTALLER}"

  echo "Generating ngcp-installer configs ..."
  gen_installer_config

  echo "Generating ngcp-installer run script ..."
  cat > "${TARGET}/tmp/ngcp-installer-deployment.sh" << "EOT"
#!/bin/bash
echo "Running ngcp-installer via grml-chroot."
ngcp-installer 2>&1
RC=$?
if [ "${RC}" = "0" ]; then
  echo "OK, ngcp-installer finished successfully, continue netscript deployment."
else
  echo "ERROR: Fatal error while running ngcp-installer (exit code '${RC}')!"
  exit ${RC}
fi
EOT

  echo "Execute ngcp-installer inside deployment chroot environment ..."
  if grml-chroot "${TARGET}" /bin/bash /tmp/ngcp-installer-deployment.sh ; then
    echo "ngcp-installer finished successfully"

    # Check the current method of external interface
    # If it is manual - we need to reconfigure /e/n/i to get working network configuration after the reboot
    method=$( sed -rn "s/^iface ${INSTALL_DEV} inet ([A-Za-z]+)/\1/p" < /etc/network/interfaces )
    netcardconf="${TARGET}/usr/share/ngcp-deployment-scripts/includes/netcardconfig"
    if [[ "${method}" == 'manual' ]]; then
      if "${DHCP}" ; then
        NET_DEV="${INSTALL_DEV}" METHOD='dhcp' "${netcardconf}"
      else
        if "${PRO_EDITION}" && "${NGCP_PXE_INSTALL}" ; then
          NET_DEV="${INSTALL_DEV}" METHOD='static' IPADDR="${INSTALL_IP}" NETMASK="${EXTERNAL_NETMASK}" \
          "${netcardconf}"
        else
          NET_DEV="${INSTALL_DEV}" METHOD='static' IPADDR="${INSTALL_IP}" NETMASK="${EXTERNAL_NETMASK}" \
          GATEWAY="${GW}" "${netcardconf}"
        fi
      fi
    fi
    echo "Copying /etc/network/interfaces ..."
    cp /etc/network/interfaces "${TARGET}/etc/network/"
    sed -i '/iface lo inet dhcp/d' "${TARGET}/etc/network/interfaces"
    unset method netcardconf
  else
    die "Error during installation of ngcp. Find details at: ${TARGET}/var/log/ngcp-installer.log"
  fi

  echo "Temporary files cleanup ..."
  find "${TARGET}/var/log" -type f -size +0 -not -name \*.ini -not -name ngcp-installer.log -exec sh -c ":> \${1}" sh {} \;
  :>$TARGET/var/run/utmp
  :>$TARGET/var/run/wtmp

  echo "Backup grml-debootstrap.log for later investigation ..."
  if [ -r /tmp/grml-debootstrap.log ] ; then
    cp /tmp/grml-debootstrap.log "${TARGET}"/var/log/
  fi
fi

if [[ -n "${MANAGEMENT_IP}" ]] && "${RETRIEVE_MGMT_CONFIG}" ; then
  echo "Retrieving public key from management node"
  cat > "${TARGET}/tmp/retrieve_authorized_keys.sh" << EOT
#!/bin/bash
set -e
mkdir -p /root/.ssh
wget --timeout=30 -O /root/.ssh/authorized_keys "http://${MANAGEMENT_IP}:3000/ssh/id_rsa_pub"
chmod 600 /root/.ssh/authorized_keys
EOT
  grml-chroot "${TARGET}" /bin/bash /tmp/retrieve_authorized_keys.sh
fi

case "$DEBIAN_RELEASE" in
  stretch|buster)
    set_custom_grub_boot_options
    ;;
esac

vagrant_configuration() {
  # bzip2, linux-headers-amd64 and make are required for VirtualBox Guest Additions installer
  # less + sudo are required for Vagrant itself
  echo "Installing software for VirtualBox Guest Additions installer"
  if ! chroot "$TARGET" apt-get -y install bzip2 less linux-headers-amd64 make sudo ; then
    die "Error: failed to install 'bzip2 less linux-headers-amd64 make sudo' packages."
  fi

  vagrant_ssh_pub_key='/var/tmp/id_rsa_sipwise.pub'
  echo "Fetching Sipwise vagrant public key from builder.mgm.sipwise.com"
  if ! wget -O "${vagrant_ssh_pub_key}" http://builder.mgm.sipwise.com/vagrant-ngcp/id_rsa_sipwise.pub ; then
    die "Error: failed to wget public Sipwise SSH key for Vagrant boxes"
  fi

  if "$NGCP_INSTALLER" ; then
    local SIPWISE_HOME="/nonexistent"
    SIPWISE_HOME=$(chroot "${TARGET}" getent passwd 'sipwise' | cut -d':' -f6)
    if [[ ! -d "${TARGET}/${SIPWISE_HOME}" ]] ; then
      die "Error: cannot determine home of 'sipwise' user, it does not exist or not a directory: ${TARGET}/${SIPWISE_HOME}"
    fi

    # TODO: move PATH adjustment to ngcp-installer (ngcpcfg should have a template here)
    if ! grep -q '^# Added for Vagrant' "${TARGET}/${SIPWISE_HOME}/.profile" 2>/dev/null ; then
      echo "Adjusting PATH configuration for user Sipwise"
      echo "# Added for Vagrant" >> "${TARGET}/${SIPWISE_HOME}/.profile"
      echo "PATH=\$PATH:/sbin:/usr/sbin" >> "${TARGET}/${SIPWISE_HOME}/.profile"
    fi

    echo "Adjusting ssh configuration for user sipwise (add Vagrant SSH key)"
    mkdir -p "${TARGET}/${SIPWISE_HOME}/.ssh/"
    cat "${vagrant_ssh_pub_key}" >> "${TARGET}/${SIPWISE_HOME}/.ssh/sipwise_vagrant_key"
    chroot "${TARGET}" chown sipwise:sipwise "${SIPWISE_HOME}/.ssh" "${SIPWISE_HOME}/.ssh/sipwise_vagrant_key"
    chroot "${TARGET}" chmod 0600 "${SIPWISE_HOME}/.ssh/sipwise_vagrant_key"
  fi

  echo "Adjusting ssh configuration for user root"
  mkdir -p "${TARGET}/root/.ssh/"
  cat "${vagrant_ssh_pub_key}" >> "${TARGET}/root/.ssh/sipwise_vagrant_key"
  chroot "${TARGET}" chmod 0600 /root/.ssh/sipwise_vagrant_key
  sed -i 's|^[#\s]*\(AuthorizedKeysFile.*\)$|\1 %h/.ssh/sipwise_vagrant_key|g' "${TARGET}/etc/ssh/sshd_config"

  # see https://github.com/mitchellh/vagrant/issues/1673
  # and https://bugs.launchpad.net/ubuntu/+source/xen-3.1/+bug/1167281
  if ! grep -q 'adjusted for Vagrant' "${TARGET}/root/.profile" ; then
    echo "Adding workaround for annoying bug 'stdin: is not a tty' Vagrant message"
    sed -ri -e "s/mesg\s+n/# adjusted for Vagrant\ntty -s \&\& mesg n/" "${TARGET}/root/.profile"
  fi

  install_vbox_iso

  # shellcheck disable=SC2010
  KERNELHEADERS=$(basename "$(ls -d ${TARGET}/usr/src/linux-headers*amd64 | grep -v -- -rt-amd64 | sort -u -r -V | head -1)")
  if [ -z "$KERNELHEADERS" ] ; then
    die "Error: no kernel headers found for building the VirtualBox Guest Additions kernel module."
  fi
  KERNELVERSION=${KERNELHEADERS##linux-headers-}
  if [ -z "$KERNELVERSION" ] ; then
    die "Error: no kernel version could be identified."
  fi

  if [ ! -r "$vbox_isofile" ] ; then
    die "Error: could not find $vbox_isofile"
  fi

  mkdir -p "${TARGET}/media/cdrom"
  mountpoint "${TARGET}/media/cdrom" >/dev/null && umount "${TARGET}/media/cdrom"
  mount -t iso9660 "${vbox_isofile}" "${TARGET}/media/cdrom/"
  # avoid "ERROR: ld.so: object '/usr/lib/ngcp-deployment-scripts/fake-uname.so' from LD_PRELOAD cannot be preloaded: ignored."
  # messages caused by the host system when running grml-chroot process
  mkdir -p /usr/lib/ngcp-deployment-scripts/
  cp /mnt/usr/lib/ngcp-deployment-scripts/fake-uname.so /usr/lib/ngcp-deployment-scripts/
  UTS_RELEASE="${KERNELVERSION}" LD_PRELOAD="/usr/lib/ngcp-deployment-scripts/fake-uname.so" \
    grml-chroot "${TARGET}" /media/cdrom/VBoxLinuxAdditions.run --nox11
  tail -10 "${TARGET}/var/log/vboxadd-install.log"
  umount "${TARGET}/media/cdrom/"

  # VBoxLinuxAdditions.run chooses /usr/lib64 as soon as this directory exists, which
  # is the case for our PRO systems shipping the heartbeat-2 package; then the
  # symlink /sbin/mount.vboxsf points to the non-existing /usr/lib64/VBoxGuestAdditions/mount.vboxsf
  # file instead of pointing to /usr/lib/x86_64-linux-gnu/VBoxGuestAdditions/mount.vboxsf
  if ! chroot "$TARGET" readlink -f /sbin/mount.vboxsf ; then
    echo "Installing mount.vboxsf symlink to work around /usr/lib64 issue"
    ln -sf /usr/lib/x86_64-linux-gnu/VBoxGuestAdditions/mount.vboxsf ${TARGET}/sbin/mount.vboxsf
  fi

  # MACs are different on buildbox and on local VirtualBox
  # see http://ablecoder.com/b/2012/04/09/vagrant-broken-networking-when-packaging-ubuntu-boxes/
  echo "Removing /etc/udev/rules.d/70-persistent-net.rules"
  rm -f "${TARGET}/etc/udev/rules.d/70-persistent-net.rules"

  if [ -d "${TARGET}/etc/.git" ]; then
    echo "Commit /etc/* changes using etckeeper"
    chroot "$TARGET" etckeeper commit "Vagrant/VirtualBox changes on /etc/*"
  fi

  # disable vbox services so they are not run after reboot
  # remove manually as we are in chroot now so can not use systemctl calls
  # can be changed with systemd-nspawn
  rm -f "${TARGET}/etc/systemd/system/multi-user.target.wants/vboxadd-service.service"
  rm -f "${TARGET}/etc/systemd/system/multi-user.target.wants/vboxadd.service"
}

if "$VAGRANT" ; then
  echo "Bootoption vagrant present, executing vagrant_configuration."
  vagrant_configuration
fi

if [ -n "$PUPPET" ] ; then

check_puppet_rc () {
  local _puppet_rc="$1"
  local _expected_rc="$2"

  if [ "${_puppet_rc}" != "${_expected_rc}" ] ; then
    # an exit code of '0' happens for 'puppet agent --enable' only,
    # an exit code of '2' means there were changes,
    # an exit code of '4' means there were failures during the transaction,
    # an exit code of '6' means there were both changes and failures.
    set_deploy_status "error"
  fi
}

check_puppet_rerun() {
  local repeat=1

  if ! checkBootParam nopuppetrepeat && [ "$(get_deploy_status)" = "error" ] ; then
    echo "Do you want to [r]epeat puppet run or [c]ontinue?"
    while true; do
      read -r a
      case "${a,,}" in
        r)
          echo "Repeating puppet run."
          repeat=0
          set_deploy_status "puppet"
          break
          ;;
        c)
          echo "Continue without repeating puppet run."
          set_deploy_status "puppet"
          break
          ;;
        * ) echo -n "Please answer 'r' to repeat or 'c' to continue: " ;;
      esac
      unset a
    done
  fi

  return "${repeat}"
}

check_puppetserver_time() {
  while true; do
    offset=$(ntpdate -q "$PUPPET_SERVER" | sed -n '1s/.*offset \(.*\),.*/\1/p' | tr -d -)
    seconds=${offset%.*}
    if (( seconds < 10 )) ; then
      echo "All OK. Time offset between $PUPPET_SERVER and current server is $seconds seconds only."
      break
    elif checkBootParam nopuppetrepeat ; then
      echo "WARNING: time offset between $PUPPET_SERVER and current server is $seconds seconds."
      echo "(ignoring due to boot option nopuppetrepeat)"
      break
    else
      echo "WARNING: time difference between the current server and $PUPPET_SERVER is ${seconds} seconds (bigger than 10 seconds)."
      echo "Please synchronize time and press any key to recheck or [c]ontinue with puppet run."
      read -r a
      case "${a,,}" in
        c)
          echo "Continue ignoring time offset check."
          break
          ;;
        * ) echo -n "Rechecking the offset..." ;;
      esac
      unset a
    fi
  done
}

puppet_install_from_git () {
  local repeat

  : "${PUPPET_GIT_REPO?ERROR: variable 'PUPPET_GIT_REPO' is NOT defined, cannot continue.}"
  : "${PUPPET_LOCAL_GIT?ERROR: variable 'PUPPET_LOCAL_GIT' is NOT defined, cannot continue.}"
  : "${PUPPET_GIT_BRANCH?ERROR: variable 'PUPPET_GIT_BRANCH' is NOT defined, cannot continue.}"

  echo "Searching for Hiera rescue device by label '${PUPPET_RESCUE_LABEL}'..."
  local PUPPET_RESCUE_DRIVE
  PUPPET_RESCUE_DRIVE=$(blkid | grep -E "LABEL=\"${PUPPET_RESCUE_LABEL}" | head -1 | awk -F: '{print $1}')

  if [ -n "${PUPPET_RESCUE_DRIVE}" ] ; then
    echo "Found Hiera rescue device: '${PUPPET_RESCUE_DRIVE}'"
  else
    die "ERROR: No USB device found matching label '${PUPPET_RESCUE_LABEL}', cannot continue!"
  fi

  echo "Searching for Hiera rescue device type..."
  local DEVICE_TYPE
  DEVICE_TYPE=$(blkid | grep -E "LABEL=\"${PUPPET_RESCUE_LABEL}" | head -1 | sed 's/.*TYPE="\(.*\)".*/\1/')

  if [ -n "${DEVICE_TYPE}" ] ; then
    echo "Hiera rescue device type is:'${DEVICE_TYPE}'"
  else
    die "ERROR: Cannot detect device type for device '${PUPPET_RESCUE_LABEL}', cannot continue!"
  fi

  echo "Copying data from device '${PUPPET_RESCUE_DRIVE}' (mounted into '${PUPPET_RESCUE_PATH}', type '${DEVICE_TYPE}')"
  mkdir -p "${PUPPET_RESCUE_PATH}"
  mount -t "${DEVICE_TYPE}" -o ro "${PUPPET_RESCUE_DRIVE}" "${PUPPET_RESCUE_PATH}"
  mkdir -p "${TARGET}/etc/puppetlabs/code/hieradata/"
  chmod 0700 "${TARGET}/etc/puppetlabs/code/hieradata/"
  cp -a "${PUPPET_RESCUE_PATH}"/hieradata/* "${TARGET}/etc/puppetlabs/code/hieradata/"
  mkdir -p ~/.ssh
  cp "${PUPPET_RESCUE_PATH}"/hieradata/defaults.d/id_rsa_r10k ~/.ssh/
  chmod 600 ~/.ssh/id_rsa_r10k
  umount -f "${PUPPET_RESCUE_PATH}"
  rmdir "${PUPPET_RESCUE_PATH}"

  echo "Cloning Puppet git repository from '${PUPPET_GIT_REPO}' to '${PUPPET_LOCAL_GIT}' (branch '${PUPPET_GIT_BRANCH}')"
  echo 'ssh -i ~/.ssh/id_rsa_r10k -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $*' > ssh
  chmod +x ssh
  if ! GIT_SSH="${PWD}/ssh" git clone --depth 1 -b "${PUPPET_GIT_BRANCH}" "${PUPPET_GIT_REPO}" "${PUPPET_LOCAL_GIT}" ; then
    die "ERROR: Cannot clone git repository, see the error above, cannot continue!"
  fi
  rm "${PWD}/ssh"

  local PUPPET_CODE_PATH
  PUPPET_CODE_PATH="/etc/puppetlabs/code/environments/${PUPPET}"

  echo "Creating empty Puppet environment ${TARGET}/${PUPPET_CODE_PATH}"
  mkdir -p "${TARGET}/${PUPPET_CODE_PATH}"
  chmod 0755 "${TARGET}/${PUPPET_CODE_PATH}"

  echo "Deploying Puppet code from Git repository to ${TARGET}/${PUPPET_CODE_PATH}"
  cp -a "${PUPPET_LOCAL_GIT}"/* "${TARGET}/${PUPPET_CODE_PATH}"
  rm -rf "${PUPPET_LOCAL_GIT:?}"

  repeat=true
  while $repeat ; do
    repeat=false
    echo "Initializing Hiera config..."
    grml-chroot $TARGET puppet apply --test --modulepath="${PUPPET_CODE_PATH}/modules" \
          -e "include puppet::hiera" 2>&1 | tee -a /tmp/puppet.log
    check_puppet_rc "${PIPESTATUS[0]}" "2"
    check_puppet_rerun && repeat=true
  done

  repeat=true
  while $repeat ; do
    repeat=false
    echo "Running Puppet core deployment..."
    grml-chroot $TARGET puppet apply --test --modulepath="${PUPPET_CODE_PATH}/modules" --tags core,apt \
          "${PUPPET_CODE_PATH}/manifests/site.pp" 2>&1 | tee -a /tmp/puppet.log
    check_puppet_rc "${PIPESTATUS[0]}" "2"
    check_puppet_rerun && repeat=true
  done

  repeat=true
  while $repeat ; do
    repeat=false
    echo "Running Puppet main deployment..."
    grml-chroot $TARGET puppet apply --test --modulepath="${PUPPET_CODE_PATH}/modules" \
          "${PUPPET_CODE_PATH}/manifests/site.pp" 2>&1 | tee -a /tmp/puppet.log
    check_puppet_rc "${PIPESTATUS[0]}" "2"
    check_puppet_rerun && repeat=true
  done

  return 0
}

puppet_install_from_puppet () {
  local repeat

  check_puppetserver_time

  repeat=true
  while $repeat ; do
    repeat=false
    echo "Running Puppet core deployment..."
    grml-chroot $TARGET puppet agent --test --tags core,apt 2>&1 | tee -a /tmp/puppet.log
    check_puppet_rc "${PIPESTATUS[0]}" "2"
    check_puppet_rerun && repeat=true
  done

  repeat=true
  while $repeat ; do
    repeat=false
    echo "Running Puppet main deployment..."
    grml-chroot $TARGET puppet agent --test 2>&1 | tee -a /tmp/puppet.log
    check_puppet_rc "${PIPESTATUS[0]}" "2"
    check_puppet_rerun && repeat=true
  done

  return 0
}

  set_deploy_status "puppet"

  echo "Setting hostname to ${IP_ARR[hostname]}"
  echo "${IP_ARR[hostname]}" > "${TARGET}/etc/hostname"
  grml-chroot "$TARGET" hostname -F /etc/hostname

  chroot $TARGET apt-get -y install resolvconf libnss-myhostname

  case "$DEBIAN_RELEASE" in
    stretch|buster)
      if [ ! -x "${TARGET}/usr/bin/dirmngr" ] ; then
        echo  "Installing dirmngr on Debian ${DEBIAN_RELEASE}, otherwise 'apt-key adv --recv-keys' is failing to fetch GPG key"
        chroot $TARGET apt-get -y install dirmngr
      fi
      ;;
  esac

  echo "Installing 'puppet-agent' with dependencies"
  cat >> ${TARGET}/etc/apt/sources.list.d/puppetlabs.list << EOF
deb ${DEBIAN_URL}/puppetlabs/ ${DEBIAN_RELEASE} main puppet5 dependencies
EOF

  PUPPET_GPG_KEY="6F6B15509CF8E59E6E469F327F438280EF8D349F"

  TRY=60
  while ! grml-chroot ${TARGET} apt-key adv --recv-keys --keyserver "${GPG_KEY_SERVER}" "${PUPPET_GPG_KEY}" ; do
    if [ ${TRY} -gt 0 ] ; then
      TRY=$((TRY-5))
      echo "Waiting for gpg keyserver '${GPG_KEY_SERVER}' availability ($TRY seconds)..."
      sleep 5
    else
      die "Failed to fetch GPG key '${PUPPET_GPG_KEY}' from '${GPG_KEY_SERVER}'"
    fi
  done

  chroot ${TARGET} apt-get update
  chroot ${TARGET} apt-get -y install puppet-agent openssh-server lsb-release ntpdate

  # Fix Facter error while running in chroot, facter fails if /etc/mtab is absent:
  case "$DEBIAN_RELEASE" in
    stretch|buster)
      chroot ${TARGET} ln -s /proc/self/mounts /etc/mtab || true
      ;;
  esac

  cat > ${TARGET}/etc/puppetlabs/puppet/puppet.conf<< EOF
# This file has been created by deployment.sh
[main]
server=${PUPPET_SERVER}
environment=${PUPPET}
EOF

  if [ -f "${TARGET}/etc/profile.d/puppet-agent.sh" ] ; then
    echo "Exporting Puppet 4 new PATH (otherwise /opt/puppetlabs/bin/puppet is not found)"
    source "${TARGET}/etc/profile.d/puppet-agent.sh"
  fi

  if [ -n "${PUPPET_GIT_REPO}" ] ; then
    echo "Installing from Puppet Git repository using 'puppet apply'"
    puppet_install_from_git
  else
    echo "Installing from Puppet server '${PUPPET_SERVER}' using 'puppet agent'"
    puppet_install_from_puppet
  fi

fi # if [ -n "$PUPPET" ] ; then

if [ -r "${INSTALL_LOG}" ] && [ -d "${TARGET}"/var/log/ ] ; then
  cp "${INSTALL_LOG}" "${TARGET}"/var/log/
fi

if [[ "${SWRAID}" = "true" ]] ; then
  if efi_support ; then
    grml-chroot "${TARGET}" mount /boot/efi

    if efibootmgr | grep -q 'NGCP Fallback' ; then
      echo "Deleting existing NGCP Fallback entry from EFI boot manager"
      efi_entry=$(efibootmgr | awk '/ NGCP Fallback$/ {print $1; exit}' | sed 's/^Boot//; s/\*$//')
      efibootmgr -b "$efi_entry" -B
    fi

    echo "Adding NGCP Fallback entry to EFI boot manager"
    efibootmgr --create --disk "/dev/${SWRAID_DISK2}" -p 2 -w --label 'NGCP Fallback' --load '\EFI\debian\grubx64.efi'
  fi

  for disk in "${SWRAID_DISK1}" "${SWRAID_DISK2}" ; do
    grml-chroot "$TARGET" grub-install "/dev/$disk"
  done

  grml-chroot "$TARGET" update-grub
fi

# unmount /ngcp-data partition inside chroot (if available)
if [ -n "${DATA_PARTITION}" ] ; then
  grml-chroot "${TARGET}" umount /ngcp-data
fi

# don't leave any mountpoints
sync

umount ${TARGET}/boot/efi || true
umount ${TARGET}/proc    || true
umount ${TARGET}/sys     || true
umount ${TARGET}/dev/pts || true
umount ${TARGET}/dev     || true
sync

# unmount chroot - what else?
umount $TARGET || umount -l $TARGET # fall back if a process is still being active

# make sure no device mapper handles are open, otherwise
# rereading partition table won't work
dmsetup remove_all || true

if [[ "${SWRAID}" = "true" ]] ; then
  if efi_support ; then
    partlabel="EFI System"
    max_tries=60
    get_pvdevice_by_label_with_retries "/dev/${SWRAID_DISK1}" "${partlabel}" "${max_tries}" efidev1
    get_pvdevice_by_label_with_retries "/dev/${SWRAID_DISK2}" "${partlabel}" "${max_tries}" efidev2

    echo "Cloning EFI partition from ${efidev1} to ${efidev2}"
    dd if="${efidev1}" of="${efidev2}" bs=10M
  fi
fi

if ! blockdev --rereadpt "/dev/${DISK}" ; then
  echo "Something on disk /dev/${DISK} (mountpoint $TARGET) seems to be still active, debugging output follows:"
  systemctl status || true
fi

# party time! who brings the whiskey?
echo "Installation finished. \o/"
echo
echo

[ -n "$start_seconds" ] && SECONDS="$(( $(cut -d . -f 1 /proc/uptime) - start_seconds))" || SECONDS="unknown"
echo "Successfully finished deployment process [$(date) - running ${SECONDS} seconds]"

if [ "$(get_deploy_status)" != "error" ] ; then
  set_deploy_status "finished"
fi

if "$INTERACTIVE" ; then
  exit 0
fi

status_wait

# do not prompt when running in automated mode
if "$REBOOT" ; then
  echo "Rebooting system as requested via ngcpreboot"
  systemctl reboot
fi

if "$HALT" ; then
  echo "Halting system as requested via ngcphalt"
  systemctl poweroff
fi

echo "Do you want to [r]eboot or [h]alt the system now? (Press any other key to cancel.)"
unset a
read -r a
case "${a,,}" in
  r)
    echo "Rebooting system as requested."
    systemctl reboot
  ;;
  h)
    echo "Halting system as requested."
    systemctl poweroff
  ;;
  *)
    echo "Not halting system as requested. Please do not forget to reboot."
    ;;
esac

## END OF FILE #################################################################1
