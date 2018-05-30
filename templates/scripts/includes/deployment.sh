#!/bin/bash
# Purpose: automatically install Debian + sip:provider platform
################################################################################

set -e
set -u

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
TARGET=/mnt
PRO_EDITION=false
CE_EDITION=false
CARRIER_EDITION=false
NGCP_INSTALLER=false
PUPPET=''
PUPPET_SERVER=puppet2.mgm.sipwise.com
PUPPET_GIT_REPO=''
PUPPET_GIT_BRANCH=master
PUPPET_LOCAL_GIT="${TARGET}/tmp/puppet.git"
PUPPET_RESCUE_PATH="/mnt/rescue_drive"
PUPPET_RESCUE_LABEL="SIPWRESCUE*"
INTERACTIVE=false
LOGO=true
TRUNK_VERSION=false
DEBIAN_RELEASE=stretch
HALT=false
REBOOT=false
STATUS_DIRECTORY=/srv/deployment/
STATUS_WAIT=0
LVM=true
VAGRANT=false
FILESYSTEM="ext4"
GPG_KEY_SERVER="pool.sks-keyservers.net"
DEBIAN_REPO_HOST="debian.sipwise.com"
DEBIAN_REPO_TRANSPORT="https"
SIPWISE_REPO_HOST="deb.sipwise.com"
SIPWISE_REPO_TRANSPORT="https"
NGCP_INIT_SYSTEM="systemd"
NETSCRIPT=${NETSCRIPT:-''}

# Get current IP


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

disable_systemd_tmpfiles_clean() {
  echo "Disabling systemd-tmpfiles-clean.timer"
  systemctl mask systemd-tmpfiles-clean.timer
}

debootstrap_sipwise_key() {
  mkdir -p /etc/debootstrap/pre-scripts/
  cat > /etc/debootstrap/pre-scripts/install-sipwise-key.sh << EOF
#!/bin/bash
# installed via deployment.sh
cp /etc/apt/trusted.gpg.d/sipwise.gpg "\${MNTPOINT}"/etc/apt/trusted.gpg.d/
EOF
  chmod 775 /etc/debootstrap/pre-scripts/install-sipwise-key.sh
}

install_sipwise_key() {
  if [ -f "/etc/apt/trusted.gpg.d/sipwise.gpg" ]; then
    md5sum_sipwise_key=$(md5sum /etc/apt/trusted.gpg.d/sipwise.gpg | awk '{print $1}')
    echo "Sipwise keyring already installed (MD5: [${md5sum_sipwise_key}]), debootstrap sipwise key"
    debootstrap_sipwise_key
    return
  else
    echo "Sipwise keyring not found, downloading."
  fi

  for x in 1 2 3; do

    if "$PRO_EDITION" ; then
      wget -O /etc/apt/trusted.gpg.d/sipwise.gpg ${SIPWISE_REPO_TRANSPORT}://${SIPWISE_REPO_HOST}/sppro/sipwise.gpg
    else
      wget -O /etc/apt/trusted.gpg.d/sipwise.gpg ${SIPWISE_REPO_TRANSPORT}://${SIPWISE_REPO_HOST}/spce/sipwise.gpg
    fi

    md5sum_sipwise_key_expected=bcd09c9ad563b2d380152a97d5a0ea83
    md5sum_sipwise_key_calculated=$(md5sum /etc/apt/trusted.gpg.d/sipwise.gpg | awk '{print $1}')

    if [ "$md5sum_sipwise_key_calculated" != "$md5sum_sipwise_key_expected" ] ; then
      echo "Sipwise keyring has wrong checksum (expected: [$md5sum_sipwise_key_expected] - got: [$md5sum_sipwise_key_calculated]), retry $x"
    else
      break
    fi
  done

  if [ "$md5sum_sipwise_key_calculated" != "$md5sum_sipwise_key_expected" ] ; then
    die "Error validating sipwise keyring for apt usage, aborting installation."
  fi

  debootstrap_sipwise_key
}

install_package_git () {
  echo "Installing package git (it is missed on GRML 'small')"

  if [ "$(dpkg-query -f "\${db:Status-Status} \${db:Status-Eflag}" -W git 2>/dev/null)" = 'installed ok' ]; then
    echo "git is already installed, nothing to do about it."
    return 0
  fi

  # use temporary apt database for speed reasons
  local TMPDIR
  TMPDIR=$(mktemp -d)
  mkdir -p "${TMPDIR}/etc/preferences.d" "${TMPDIR}/statedir/lists/partial" \
    "${TMPDIR}/cachedir/archives/partial"
  echo "deb http://${DEBIAN_REPO_HOST}/debian/ ${DEBIAN_RELEASE} main contrib non-free" > \
    "${TMPDIR}/etc/sources.list"

  DEBIAN_FRONTEND='noninteractive' apt-get -o dir::cache="${TMPDIR}/cachedir" \
    -o dir::state="${TMPDIR}/statedir" -o dir::etc="${TMPDIR}/etc" \
    -o dir::etc::trustedparts="/etc/apt/trusted.gpg.d/" update

  DEBIAN_FRONTEND='noninteractive' apt-get -o dir::cache="${TMPDIR}/cachedir" \
    -o dir::etc="${TMPDIR}/etc" -o dir::state="${TMPDIR}/statedir" \
    -o dir::etc::trustedparts="/etc/apt/trusted.gpg.d/" \
    -y --no-install-recommends install git
}

install_vbox_iso() {
  echo "Downloading virtualbox-guest-additions ISO"

  local vbox_checksum="6df8c8ab6e7ac3a70a5e29116f8a5dcdb7dfbd0b226ef849a5cd9502e956b06f" # sha256
  local vbox_iso="VBoxGuestAdditions_5.1.26.iso"

  mkdir -p "/usr/share/virtualbox/"
  vbox_isofile="/usr/share/virtualbox/${vbox_iso}"
  wget -c -O "$vbox_isofile" "https://deb.sipwise.com/files/${vbox_iso}"

  echo "${vbox_checksum} ${vbox_isofile}" | sha256sum --check || die "Error: failed to compute checksum for Virtualbox ISO. Exiting."
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

ensure_augtool_present() {
  if [ -x /usr/bin/augtool ] ; then
    echo "/usr/bin/augtool is present, nothing to do"
    return 0
  fi

  echo "augtool isn't present, installing augeas-tools package:"

  # use temporary apt database for speed reasons
  local TMPDIR
  TMPDIR=$(mktemp -d)
  mkdir -p "${TMPDIR}/etc/preferences.d" "${TMPDIR}/statedir/lists/partial" \
    "${TMPDIR}/cachedir/archives/partial"
  echo "deb http://${DEBIAN_REPO_HOST}/debian/ ${DEBIAN_RELEASE} main contrib non-free" > \
    "${TMPDIR}/etc/sources.list"

  DEBIAN_FRONTEND='noninteractive' apt-get -o dir::cache="${TMPDIR}/cachedir" \
    -o dir::state="${TMPDIR}/statedir" -o dir::etc="${TMPDIR}/etc" \
    -o dir::etc::trustedparts="/etc/apt/trusted.gpg.d/" update

  DEBIAN_FRONTEND='noninteractive' apt-get -o dir::cache="${TMPDIR}/cachedir" \
    -o dir::etc="${TMPDIR}/etc" -o dir::state="${TMPDIR}/statedir" \
    -o dir::etc::trustedparts="/etc/apt/trusted.gpg.d/" \
    -y --no-install-recommends install augeas-tools
}
### }}}

# logging {{{
#cat > /etc/rsyslog.d/logsend.conf << EOF
#*.*  @@192.168.51.28
#EOF
#service rsyslog restart

logit() {
  logger -t grml-deployment "$@"
}

die() {
  logger -t grml-deployment "$@"
  echo "$@" >&2
  set_deploy_status "error"
  exit 1
}

enable_trace() {
  if "${DEBUG_MODE}" ; then
    set -x
    PS4='+\t '
  fi
}

disable_trace() {
  if "${DEBUG_MODE}" ; then
    set +x
    PS4=''
  fi
}


logit "host-IP: $(ip-screen)"
logit "deployment-version: $SCRIPT_VERSION"
# }}}

enable_deploy_status_server

set_deploy_status "checkBootParam"

if checkBootParam debugmode ; then
  DEBUG_MODE=true
  enable_trace
fi

disable_systemd_tmpfiles_clean

if checkBootParam 'targetdisk=' ; then
  TARGET_DISK=$(getBootParam targetdisk)
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

[ -z "${DISK}" ] && die "Error: No non-removable disk suitable for installation found"

if checkBootParam 'ngcpstatus=' ; then
  STATUS_WAIT=$(getBootParam ngcpstatus || true)
  [ -n "$STATUS_WAIT" ] || STATUS_WAIT=30
fi

if checkBootParam noinstall ; then
  echo "Exiting as requested via bootoption noinstall."
  exit 0
fi

if checkBootParam nocolorlogo ; then
  LOGO=false
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
fi

if checkBootParam ngcppro || checkBootParam ngcpsp1 || checkBootParam ngcpsp2 ; then
  PRO_EDITION=true
fi

if "$PRO_EDITION" ; then
  ROLE=sp1

  if checkBootParam ngcpsp2 ; then
    ROLE=sp2
  fi
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

ARCH=$(dpkg --print-architecture)
if checkBootParam "arch=" ; then
  ARCH=$(getBootParam arch)
fi

# test unfinished releases against
# "https://deb.sipwise.com/autobuild/ release-$AUTOBUILD_RELEASE"
if checkBootParam 'ngcpautobuildrelease=' ; then
  AUTOBUILD_RELEASE=$(getBootParam ngcpautobuildrelease)
  export SKIP_SOURCES_LIST=true # make sure it's available within grml-chroot subshell
fi

# existing ngcp releases (like 2.2) with according repository and installer
if checkBootParam 'ngcpvers=' ; then
  SP_VERSION=$(getBootParam ngcpvers)
  if [ "${SP_VERSION:-}" = "trunk" ] ; then
    TRUNK_VERSION=true
  fi
  export TRUNK_VERSION # make sure it's available within grml-chroot subshell
fi

if checkBootParam nongcp ; then
  echo "Will not execute ngcp-installer as requested via bootoption nongcp."
  NGCP_INSTALLER=false
fi

if checkBootParam 'ngcphostname=' ; then
  TARGET_HOSTNAME="$(getBootParam ngcphostname)" || true
fi

if checkBootParam 'ngcpcrole=' ; then
  CROLE=$(getBootParam ngcpcrole)
  CARRIER_EDITION=true
fi

if checkBootParam ngcpnolvm ; then
  logit "Disabling LVM due to ngcpnolvm boot option"
  LVM=false
fi

# allow forcing LVM mode
if checkBootParam ngcplvm ; then
  logit "Enabling LVM due to ngcplvm boot option"
  LVM=true
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

if checkBootParam "debianrepo=" ; then
  DEBIAN_REPO_HOST=$(getBootParam debianrepo)
fi

if checkBootParam "sipwiserepo=" ; then
  SIPWISE_REPO_HOST=$(getBootParam sipwiserepo)
fi

if checkBootParam 'ngcpppa=' ; then
  NGCP_PPA=$(getBootParam ngcpppa)
fi

if checkBootParam 'ngcpppainstaller=' ; then
  NGCP_PPA_INSTALLER=$(getBootParam ngcpppainstaller)
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

if checkBootParam 'ngcpinitsystem=' ; then
  NGCP_INIT_SYSTEM=$(getBootParam ngcpinitsystem)
  logit "Using init system '${NGCP_INIT_SYSTEM}' as requested via boot option ngcpinitsystem"
fi
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
  ngcpppa=...      - use NGCP PPA Debian repository

Control target system:

  ngcphostname=... - hostname of installed system (defaults to ngcp/sp[1,2])
                     NOTE: do NOT use when installing Pro Edition!

The command line options correspond with the available bootoptions.
Command line overrides any present bootoption.

Usage examples:

  # ngcp-deployment ngcpce

  # ngcp-deployment ngcppro ngcpsp1

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
    *ngcpcrole=*) CARRIER_EDITION=true; CROLE="${param//ngcpcrole=/}";;
    *ngcphalt*) HALT=true;;
    *ngcpreboot*) REBOOT=true;;
    *vagrant*) VAGRANT=true;;
    *ngcpppainstaller*) NGCP_PPA_INSTALLER="${param//ngcpppainstaller=/}";;
    *ngcpppa*) NGCP_PPA="${param//ngcpppa=/}";;
    *ngcpinitsystem*) NGCP_INIT_SYSTEM="${param//ngcpinitsystem=/}";;
  esac
  shift
done

if ! "$NGCP_INSTALLER" ; then
  CARRIER_EDITION=false
  PRO_EDITION=false
  CE_EDITION=false
  unset ROLE
fi

set_deploy_status "installing_sipwise_keys"
install_sipwise_key

if "$NGCP_INSTALLER" ; then
  set_deploy_status "ensure_augtool_present"
  ensure_augtool_present
fi

set_deploy_status "getconfig"

# when using ip=....:$HOSTNAME:eth0:off file /etc/hosts doesn't contain the
# hostname by default, avoid warning/error messages in the host system
# and use it for IP address check in pro edition
if [ -z "$TARGET_HOSTNAME" ] ; then
  if "$PRO_EDITION" ; then
    TARGET_HOSTNAME="$ROLE"
  fi

  if "$CE_EDITION" ; then
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

# ASM
logit "INSTALL_IP is $INSTALL_IP"

set_deploy_status "settings"

### echo settings
[ -n "$SP_VERSION" ] && SP_VERSION_STR=$SP_VERSION || SP_VERSION_STR="<latest>"

echo "Deployment Settings:

  Install ngcp:      $NGCP_INSTALLER"

if "$CARRIER_EDITION" ; then
  echo "  sip:carrier"
elif "$PRO_EDITION" ; then
  echo "  sip:provider:      PRO"
elif "$CE_EDITION" ; then
  echo "  sip:provider:      CE"
fi

echo "
  Target disk:       /dev/$DISK
  Target Hostname:   $TARGET_HOSTNAME
  Installer version: $SP_VERSION_STR
  Install IP:        $INSTALL_IP

  Installing in chassis? $CHASSIS

" | tee -a /tmp/installer-settings.txt

if "$PRO_EDITION" ; then
  echo "
  Host Role:         $ROLE
  Host Role Carrier: $CROLE
  Profile:           $PROFILE
" | tee -a /tmp/installer-settings.txt
fi

if "$INTERACTIVE" ; then
  echo "WARNING: Execution will override any existing data!"
  echo "Settings OK? y/N"
  read a
  if [[ "$a" != "y" ]] ; then
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
  if [ -n "$NGCP_PPA_INSTALLER" ] ; then
    PPA_INFO+="| Installer PPA: ${NGCP_PPA_INSTALLER}"
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
  echo "Installing $SP_VERSION_STR platform | Debian: $DEBIAN_RELEASE $PPA_INFO"
  echo "Install IP: $INSTALL_IP | Started deployment at $DATE_INFO"
  # number of lines
  echo -ne "\e[10;0r"
  # reset color
  echo -ne "\e[9B\e[1;m"
  enable_trace
fi

if "$PRO_EDITION" ; then
  # ipmi on IBM hardware
  if ifconfig usb0 &>/dev/null ; then
    ifconfig usb0 169.254.1.102 netmask 255.255.0.0
  fi
fi

set_deploy_status "diskverify"

# TODO - hardcoded for now, to avoid data damage
check_for_supported_disk() {
  if grep -q 'ServeRAID' "/sys/block/${DISK}/device/model" ; then
    return 0
  fi

  # IBM System x3250 M3
  if grep -q 'Logical Volume' "/sys/block/${DISK}/device/model" && \
    grep -q "LSILOGIC" "/sys/block/${DISK}/device/vendor" ; then
    return 0
  fi

  # IBM System HS23 LSISAS2004
  if grep -q 'Logical Volume' "/sys/block/${DISK}/device/model" && \
    grep -q "LSI" "/sys/block/${DISK}/device/vendor" ; then
    return 0
  fi

  # PERC H700, PERC H710,...
  if grep -q 'PERC' "/sys/block/${DISK}/device/model" && \
    grep -q "DELL" "/sys/block/${DISK}/device/vendor" ; then
    return 0
  fi

  # proxmox on blade, internal system
  if grep -q 'COMSTAR' "/sys/block/${DISK}/device/model" && \
    grep -q "OI" "/sys/block/${DISK}/device/vendor" ; then
    FIRMWARE_PACKAGES="$FIRMWARE_PACKAGES firmware-qlogic"
    return 0
  fi

  local disk_model
  disk_model=$(cat "/sys/block/${DISK}/device/model") || true
  local disk_vendor
  disk_vendor=$(cat "/sys/block/${DISK}/device/vendor") || true

  echo "WARNING: Cannot detect supported device vendor/model." >&2
  echo "(Disk: ${DISK}  Vendor: ${disk_vendor}  Model: ${disk_model})" >&2
  echo "Would you like to continue anyway? (yes/NO)" >&2
  read a
  case "$a" in
    y|Y|yes|YES)
      echo "Continue anyway as requested."
      return 0
      ;;
    *)
      echo "Aborting installation using disk '${DISK}'" >&2
      return 1
      ;;
  esac
  unset a

  # no match so far?
  return 1
}

# run in according environment only
if [ -n "$TARGET_DISK" ] ; then
  logit "Skipping check for supported disk as TARGET_DISK variable is set."
else
  if [[ $(imvirt 2>/dev/null) == "Physical" ]] ; then

    if ! check_for_supported_disk ; then
      die "Error: /dev/${DISK} does not look like a VirtIO, ServeRAID, LSILOGIC or PowerEdge disk/controller. Exiting to avoid possible data damage."
    fi

  else
    # make sure it runs only within qemu/kvm
    if [[ "${DISK}" == "vda" ]] && readlink -f /sys/block/vda/device | grep -q 'virtio' ; then
      echo "Looks like a virtio disk, ok."
    elif grep -q 'QEMU HARDDISK' "/sys/block/${DISK}/device/model" ; then
      echo "Looks like a QEMU harddisk, ok."
    elif grep -q 'VBOX HARDDISK' "/sys/block/${DISK}/device/model" ; then
      echo "Looks like a VBOX harddisk, ok."
    elif grep -q 'Virtual disk' "/sys/block/${DISK}/device/model" && [[ $(imvirt) == "VMware ESX Server" ]] ; then
      echo "Looks like a VMware ESX Server harddisk, ok."
    else
      die "Error: /dev/${DISK} does not look like a virtual disk. Exiting to avoid possible data damage. Note: imvirt output is $(imvirt)"
    fi
  fi
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

# 2000GB = 2097152000 blocks in /proc/partitions - so make a rough estimation
if [ "$(awk "/ ${DISK}$/ {print \$3}" /proc/partitions)" -gt 2000000000 ] ; then
  TABLE=gpt
else
  TABLE=msdos
fi

if "$LVM" ; then
  if "$NGCP_INSTALLER" ; then
    VG_NAME="ngcp"
  else
    VG_NAME="vg0"
  fi
fi

clear_partition_table() {
  local blockdevice
  blockdevice="/dev/${DISK}"

  echo "Wiping disk signatures from ${blockdevice}"
  wipefs -a "${blockdevice}"

  # make sure parted doesn't fail if LVM is already present
  blockdev --rereadpt "$blockdevice"
  for disk in "$blockdevice"* ; do
    existing_pvs=$(pvs "$disk" -o vg_name --noheadings 2>/dev/null || true)
    if [ -n "$existing_pvs" ] ; then
      for pv in $existing_pvs ; do
        logit "Getting rid of existing VG $pv"
        vgremove -ff "$pv"
      done
    fi

    logit "Removing possibly existing LVM/PV label from $disk"
    pvremove "$disk" --force --force --yes || true
  done

  dd if=/dev/zero of="/dev/${DISK}" bs=1M count=1
  blockdev --rereadpt "/dev/${DISK}"
}

set_up_partition_table() {
  clear_partition_table

  local blockdevice
  blockdevice="/dev/${DISK}"

  echo "Creating partition table"
  parted -a optimal -s "${blockdevice}" mklabel "$TABLE"

  parted -a optimal -s "${blockdevice}" mkpart primary 2048s 100%
  parted -a optimal -s "${blockdevice}" set 1 lvm on

  echo "Creating PV + VG"
  pvcreate -ff -y "${blockdevice}"1
  vgcreate "${VG_NAME}" "${blockdevice}"1
  vgchange -a y "${VG_NAME}"
}

create_ngcp_partitions() {
  local memory swap_size

  memory=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
  swap_size=$(( memory / 2 / 1024)) # 50% of RAM in MB

  # rootfs
  local vg_free rootfs_size
  vg_free=$(vgs "${VG_NAME}" -o vg_free --noheadings --nosuffix --units B)
  rootfs_size=$(( (vg_free - ( swap_size * 1024 * 1024 )) * 19 / 20 / 1024 / 1024 )) # 95% of free space, excl. swap (in MB)
  echo "Creating LV root with ${rootfs_size}M"
  lvcreate --yes -n root -L "${rootfs_size}M" "${VG_NAME}"

  echo "Creating ${FILESYSTEM} filesystem on /dev/${VG_NAME}/root"
  mkfs."${FILESYSTEM}" -FF /dev/"${VG_NAME}"/root

  # swap
  echo "Creating LV swap with ${swap_size}"
  lvcreate --yes -n swap -L "${swap_size}M" "${VG_NAME}"

  echo "Creating swap space on /dev/${VG_NAME}/swap"
  mkswap /dev/"${VG_NAME}"/swap

  # used later by installer
  ROOT_FS="/dev/mapper/${VG_NAME}-root"
  SWAP_PARTITION="/dev/mapper/${VG_NAME}-swap"
}

create_debian_partitions() {
  local memory swap_size

  memory=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
  swap_size=$(( memory / 2 / 1024)) # 50% of RAM in MB

  # rootfs
  local root_size=8G
  echo "Creating LV root with ${root_size}"
  lvcreate --yes -n root -L "${root_size}" "${VG_NAME}"

  echo "Creating ${FILESYSTEM} on /dev/${VG_NAME}/root"
  mkfs."${FILESYSTEM}" -FF /dev/"${VG_NAME}"/root

  # swap
  echo "Creating LV swap with ${swap_size}"
  lvcreate --yes -n swap -L "${swap_size}M" "${VG_NAME}"

  echo "Creating swap on /dev/${VG_NAME}/swap"
  mkswap /dev/"${VG_NAME}"/swap

  # used later by installer
  ROOT_FS="/dev/mapper/${VG_NAME}-root"
  SWAP_PARTITION="/dev/mapper/${VG_NAME}-swap"
}

display_partition_table() {
  local blockdevice
  blockdevice="/dev/${DISK}"

  echo "Displaying partition table for reference:"
  parted -s "${blockdevice}" unit GiB print
  lsblk "${blockdevice}"
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
  SWAP_PARTITION="/dev/mapper/${VG_NAME}-swap"

  # restore original options/behavior
  eval "$saved_options"
}

plain_disk_setup() {
  parted -s -a optimal "/dev/${DISK}" mktable "${TABLE}" || die "Failed to set up partition table"
  # hw-raid with rootfs + swap partition
  parted -s -a optimal "/dev/${DISK}" 'mkpart primary ext4 2048s 95%' || die "Failed to set up primary partition"
  parted -s -a optimal "/dev/${DISK}" 'mkpart primary linux-swap 95% -1' || die "Failed to set up swap partition"
  sync

  # used later by installer
  ROOT_FS="/dev/${DISK}1"
  SWAP_PARTITION="/dev/${DISK}2"

  echo "Initialising swap partition $SWAP_PARTITION"
  mkswap -L ngcp-swap "$SWAP_PARTITION" || die "Failed to initialise swap partition"

  # for later usage in /etc/fstab use /dev/disk/by-label/ngcp-swap instead of /dev/${DISK}2
  SWAP_PARTITION="/dev/disk/by-label/ngcp-swap"
}

if "$LVM" ; then
  lvm_setup
else # no LVM
  plain_disk_setup
fi

# otherwise e2fsck fails with "need terminal for interactive repairs"
echo FSCK=no >>/etc/debootstrap/config

# package selection
cat > /etc/debootstrap/packages << EOF
# addons: packages which d-i installs but debootstrap doesn't
eject
grub-pc
pciutils
usbutils
ucf
# locales -> but we want locales-all instead:
locales-all

# required e.g. for "Broadcom NetXtreme II BCM5709S Gigabit Ethernet"
# lacking the firmware will result in non-working network on
# too many physical server systems, so just install it by default
firmware-bnx2
firmware-bnx2x

# MT#7999 ethtool used in bonding
ethtool

# support acpi (d-i installs them as well)
acpi acpid acpi-support-base

# be able to login on the system, even if just installing plain Debian
openssh-server

# support bridge / vlan
bridge-utils
vlan

# MT#13637 support https in sources.list
apt-transport-https

# TT#5444 ca-certificates is necessary to wget ngcp-installer over https
ca-certificates

# packages d-i installs but we ignore/skip:
#discover
#gettext-base
#installation-report
#kbd
#laptop-detect
#os-prober

# support bonding
ifenslave

# required for dkms
linux-headers-amd64
EOF

if "$LVM" ; then
  cat >> /etc/debootstrap/packages << EOF
# support LVM
lvm2
EOF
fi

if [ -n "$FIRMWARE_PACKAGES" ] ; then
  cat >> /etc/debootstrap/packages << EOF
# firmware packages for hardware specific needs
$FIRMWARE_PACKAGES
EOF
fi

# NOTE: we use the debian.sipwise.com CNAME by intention here
# to avoid conflicts with apt-pinning, preferring deb.sipwise.com
# over official Debian
MIRROR="${DEBIAN_REPO_TRANSPORT}://${DEBIAN_REPO_HOST}/debian/"
SEC_MIRROR="${DEBIAN_REPO_TRANSPORT}://${DEBIAN_REPO_HOST}/debian-security/"
DBG_MIRROR="${DEBIAN_REPO_TRANSPORT}://${DEBIAN_REPO_HOST}/debian-debug/"

if [ -z "${GPG_KEY}" ] ; then
  KEYRING='/etc/apt/trusted.gpg.d/sipwise.gpg'
else
  KEYRING='/etc/apt/trusted.gpg'

  echo "Fetching debootstrap keyring as GPG key '${GPG_KEY}'..."
  logit "Fetching debootstrap keyring as GPG key '${GPG_KEY}'..."

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
logit "Setting up /etc/debootstrap/etc/apt/sources.list"
cat > /etc/debootstrap/etc/apt/sources.list << EOF
# Set up via deployment.sh for grml-debootstrap usage
deb ${MIRROR} ${DEBIAN_RELEASE} main contrib non-free
EOF

echo "deb ${SEC_MIRROR} ${DEBIAN_RELEASE}-security main contrib non-free" >> /etc/debootstrap/etc/apt/sources.list
echo "deb ${MIRROR} ${DEBIAN_RELEASE}-updates main contrib non-free" >> /etc/debootstrap/etc/apt/sources.list
echo "deb ${DBG_MIRROR} ${DEBIAN_RELEASE}-debug main contrib non-free" >> /etc/debootstrap/etc/apt/sources.list

if [ "$DEBIAN_RELEASE" = "stretch" ] && [ ! -r /usr/share/debootstrap/scripts/stretch ] ; then
  echo  "Enabling stretch support for debootstrap via symlink to sid"
  ln -s /usr/share/debootstrap/scripts/sid /usr/share/debootstrap/scripts/stretch
fi

# install Debian
# shellcheck disable=SC2086
echo y | grml-debootstrap \
  --arch "${ARCH}" \
  --grub "/dev/${DISK}" \
  --filesystem "${FILESYSTEM}" \
  --hostname "${TARGET_HOSTNAME}" \
  --mirror "$MIRROR" \
  --debopt "--keyring=${KEYRING}" $EXTRA_DEBOOTSTRAP_OPTS \
  --keep_src_list \
  --defaultinterfaces \
  -r "$DEBIAN_RELEASE" \
  -t "$ROOT_FS" \
  --password 'sipwise' 2>&1 | tee -a /tmp/grml-debootstrap.log

if [ "${PIPESTATUS[1]}" != "0" ]; then
  die "Error during installation of Debian ${DEBIAN_RELEASE}. Find details via: mount $ROOT_FS $TARGET ; ls $TARGET/debootstrap/*.log"
fi

sync
mount "$ROOT_FS" "$TARGET"

# MT#7805
if "$NGCP_INSTALLER" ; then
  cat << EOT | augtool --root="$TARGET"
insert opt after /files/etc/fstab/*[file="/"]/opt[last()]
set /files/etc/fstab/*[file="/"]/opt[last()] noatime
save
EOT
fi

# provide useable swap partition
echo "Enabling swap partition $SWAP_PARTITION via /etc/fstab"
cat >> "${TARGET}/etc/fstab" << EOF
$SWAP_PARTITION                      none           swap       sw,pri=0  0  0
EOF

if "$PRO_EDITION" ; then
  echo "Pro edition: keeping firmware* packages."
else
  chroot $TARGET apt-get --purge -y remove \
  firmware-linux firmware-linux-free firmware-linux-nonfree || true
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
127.0.0.1       $HOSTNAME

::1             localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

get_installer_path() {
  if [ -z "$SP_VERSION" ] && ! $TRUNK_VERSION ; then
    INSTALLER=ngcp-installer-latest.deb

    if "$PRO_EDITION" ; then
      INSTALLER_PATH="${SIPWISE_REPO_TRANSPORT}://${SIPWISE_REPO_HOST}/sppro/"
    else
      INSTALLER_PATH="${SIPWISE_REPO_TRANSPORT}://${SIPWISE_REPO_HOST}/spce/"
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
    local repos_base_path="${SIPWISE_REPO_TRANSPORT}://${SIPWISE_REPO_HOST}/sppro/${SP_VERSION}/dists/${DEBIAN_RELEASE}/main/binary-amd64/"
    INSTALLER_PATH="${SIPWISE_REPO_TRANSPORT}://${SIPWISE_REPO_HOST}/sppro/${SP_VERSION}/pool/main/n/ngcp-installer/"
  else
    local installer_package='ngcp-installer-ce'
    local repos_base_path="${SIPWISE_REPO_TRANSPORT}://${SIPWISE_REPO_HOST}/spce/${SP_VERSION}/dists/${DEBIAN_RELEASE}/main/binary-amd64/"
    INSTALLER_PATH="${SIPWISE_REPO_TRANSPORT}://${SIPWISE_REPO_HOST}/spce/${SP_VERSION}/pool/main/n/ngcp-installer/"
  fi

  # use a separate repos for trunk releases
  if $TRUNK_VERSION ; then
    local repos_base_path="${SIPWISE_REPO_TRANSPORT}://${SIPWISE_REPO_HOST}/autobuild/dists/release-trunk-${DEBIAN_RELEASE}/main/binary-amd64/"
    INSTALLER_PATH="${SIPWISE_REPO_TRANSPORT}://${SIPWISE_REPO_HOST}/autobuild/pool/main/n/ngcp-installer/"
  fi

  if [ -n "$NGCP_PPA_INSTALLER" ] ; then
    local repos_base_path="${SIPWISE_REPO_TRANSPORT}://${SIPWISE_REPO_HOST}/autobuild/dists/${NGCP_PPA_INSTALLER}/main/binary-amd64/"
    INSTALLER_PATH="${SIPWISE_REPO_TRANSPORT}://${SIPWISE_REPO_HOST}/autobuild/pool/main/n/ngcp-installer/"
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

  # support testing rc releases without providing an according installer package ahead
  if [ -n "$AUTOBUILD_RELEASE" ] ; then
    echo "Running installer with sources.list for $DEBIAN_RELEASE + autobuild release-$AUTOBUILD_RELEASE"

    cat > $TARGET/etc/apt/sources.list.d/sipwise.list << EOF
## custom sources.list, deployed via deployment.sh

# Sipwise repositories
deb [arch=amd64] ${SIPWISE_REPO_TRANSPORT}://${SIPWISE_REPO_HOST}/autobuild/release/release-${AUTOBUILD_RELEASE} release-${AUTOBUILD_RELEASE} main
EOF
  fi
}

gen_installer_config() {
  # ASM
  return 0
}

if "$NGCP_INSTALLER" ; then
  # set INSTALLER_PATH and INSTALLER depending on release/version
  get_installer_path

  # generate debian/sipwise repos
  set_repos

  set_deploy_status "ngcp-installer"

  # install ngcp-installer
  logit "ngcp-installer: $INSTALLER"
  cat << EOT | grml-chroot $TARGET /bin/bash
wget ${INSTALLER_PATH}/${INSTALLER}
dpkg -i $INSTALLER
EOT

  # generate installer configs
  gen_installer_config

  # generate ngcp-installer run script
  cat > "${TARGET}/tmp/ngcp-installer-deployment.sh" << "EOT"
#!/bin/bash
echo "Running ngcp-installer via grml-chroot." | tee -a /tmp/ngcp-installer-debug.log
ngcp-installer 2>&1 | tee -a /tmp/ngcp-installer-debug.log
RC=${PIPESTATUS[0]}
if [ "${RC}" = "0" ] ; then
  echo "OK, ngcp-installer finished with exit code '${RC}', continue netscript deployment." | tee -a /tmp/ngcp-installer-debug.log
else
  echo "ERROR: Fatal error while running ngcp-installer (exit code '${RC}')!" | tee -a /tmp/ngcp-installer-debug.log >&2
  exit ${RC}
fi
EOT

  # execute ngcp-installer
  if grml-chroot "${TARGET}" /bin/bash /tmp/ngcp-installer-deployment.sh ; then
    logit "installer: success"
  else
    logit "installer: error"
    die "Error during installation of ngcp. Find details at: ${TARGET}/tmp/ngcp-installer.log ${TARGET}/tmp/ngcp-installer-debug.log"
  fi

  # nuke files
  find "${TARGET}/var/log" -type f -size +0 -not -name \*.ini -exec sh -c ":> \${1}" sh {} \;
  :>$TARGET/var/run/utmp
  :>$TARGET/var/run/wtmp

  # make a backup of the installer logfiles for later investigation
  if [ -r "${TARGET}"/tmp/ngcp-installer.log ] ; then
    cp "${TARGET}"/tmp/ngcp-installer.log "${TARGET}"/var/log/
  fi
  if [ -r "${TARGET}"/tmp/ngcp-installer-debug.log ] ; then
    cp "${TARGET}"/tmp/ngcp-installer-debug.log "${TARGET}"/var/log/
  fi
  if [ -r /tmp/grml-debootstrap.log ] ; then
    cp /tmp/grml-debootstrap.log "${TARGET}"/var/log/
  fi

  {
    echo "# deployment.sh running on $(date)"
    echo "SCRIPT_VERSION=${SCRIPT_VERSION}"
    echo "CMD_LINE=\"${CMD_LINE}\""
    echo "NGCP_INSTALLER_CMDLINE=\"TRUNK_VERSION=$TRUNK_VERSION SKIP_SOURCES_LIST=$SKIP_SOURCES_LIST ngcp-installer $ROLE $IP1 $IP2 $EADDR $EIFACE $IP_HA_SHARED\""
  } > "${TARGET}"/var/log/deployment.log

fi

case "$DEBIAN_RELEASE" in
  stretch)
    set_custom_grub_boot_options
    ;;
esac

fake_uname() {
   cat > "${TARGET}/tmp/uname.c" << EOF
#include <stdio.h>
#include <string.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <sys/syslog.h>
#include <sys/utsname.h>

#ifndef UTS_RELEASE
#define UTS_RELEASE "0.0.0"
#endif

#ifndef RTLD_NEXT
#define RTLD_NEXT      ((void *) -1l)
#endif

typedef int (*uname_t) (struct utsname * buf);

static void *get_libc_func(const char *funcname)
{
  void *func;
  char *error;

  func = dlsym(RTLD_NEXT, funcname);
  if ((error = dlerror()) != NULL) {
    fprintf(stderr, "Can't locate libc function \`%s' error: %s", funcname, error);
    _exit(EXIT_FAILURE);
  }
  return func;
}

int uname(struct utsname *buf)
{
  int ret;
  char *env = NULL;
  uname_t real_uname = (uname_t) get_libc_func("uname");

  ret = real_uname((struct utsname *) buf);
  strncpy(buf->release, ((env = getenv("UTS_RELEASE")) == NULL) ? UTS_RELEASE : env, 65);
  return ret;
}
EOF

  grml-chroot "$TARGET" gcc -shared -fPIC -ldl /tmp/uname.c -o /tmp/fake-uname.so || die 'Failed to build fake-uname.so'

  # avoid "ERROR: ld.so: object '/tmp/fake-uname.so' from LD_PRELOAD cannot be preloaded: ignored."
  # messages caused by the host system when running grml-chroot process
  cp "$TARGET"/tmp/fake-uname.so /tmp/fake-uname.so
}

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
    SIPWISE_HOME="/var/sipwise"

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

  # required for fake_uname and VBoxLinuxAdditions.run
  grml-chroot $TARGET apt-get -y install libc6-dev gcc
  fake_uname

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
  UTS_RELEASE=$KERNELVERSION LD_PRELOAD=/tmp/fake-uname.so grml-chroot "$TARGET" /media/cdrom/VBoxLinuxAdditions.run --nox11
  tail -10 "${TARGET}/var/log/VBoxGuestAdditions.log"
  umount "${TARGET}/media/cdrom/"

  # work around regression in virtualbox-guest-additions-iso 4.3.10
  if [ -d ${TARGET}/opt/VBoxGuestAdditions-4.3.10 ] ; then
    echo "Installing VBoxGuestAddition symlink to work around vbox 4.3.10 issue"
    ln -s /opt/VBoxGuestAdditions-4.3.10/lib/VBoxGuestAdditions ${TARGET}/usr/lib/VBoxGuestAdditions
  fi

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
      read a
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
      read a
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
  mkdir -m 0700 -p "${TARGET}/etc/puppetlabs/code/hieradata/"
  cp -a "${PUPPET_RESCUE_PATH}"/hieradata/* "${TARGET}/etc/puppetlabs/code/hieradata/"
  mkdir -p ~/.ssh
  cp "${PUPPET_RESCUE_PATH}"/hieradata/defaults.d/id_rsa_r10k ~/.ssh/
  chmod 600 ~/.ssh/id_rsa_r10k
  umount -f "${PUPPET_RESCUE_PATH}"
  rmdir "${PUPPET_RESCUE_PATH}"

  echo "Cloning Puppet git repository from '${PUPPET_GIT_REPO}' to '${PUPPET_LOCAL_GIT}' (branch '${PUPPET_GIT_BRANCH}')"
  install_package_git
  echo 'ssh -i ~/.ssh/id_rsa_r10k -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $*' > ssh
  chmod +x ssh
  if ! GIT_SSH="${PWD}/ssh" git clone --depth 1 -b "${PUPPET_GIT_BRANCH}" "${PUPPET_GIT_REPO}" "${PUPPET_LOCAL_GIT}" ; then
    die "ERROR: Cannot clone git repository, see the error above, cannot continue!"
  fi
  rm "${PWD}/ssh"

  local PUPPET_CODE_PATH
  PUPPET_CODE_PATH="/etc/puppetlabs/code/environments/${PUPPET}"

  echo "Creating empty Puppet environment ${TARGET}/${PUPPET_CODE_PATH}"
  mkdir -m 0755 -p "${TARGET}/${PUPPET_CODE_PATH}"

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
}

  set_deploy_status "puppet"

  echo "Rebuilding /etc/hosts"
  cat > $TARGET/etc/hosts << EOF
# Generated via deployment.sh
127.0.0.1 localhost

# The following lines are desirable for IPv6 capable hosts
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters

EOF

  echo "Setting hostname to $TARGET_HOSTNAME"
  echo "$TARGET_HOSTNAME" > ${TARGET}/etc/hostname
  grml-chroot $TARGET hostname -F /etc/hostname

  chroot $TARGET apt-get -y install resolvconf libnss-myhostname

  if [ "$DEBIAN_RELEASE" = "stretch" ] && [ ! -x "${TARGET}/usr/bin/dirmngr" ] ; then
    echo  "Installing dirmngr on Debian Stretch otherwise 'apt-key adv --recv-keys' is failing to fetch GPG key"
    chroot $TARGET apt-get -y install dirmngr
  fi

  echo "Installing 'puppet-agent' with dependencies"
  cat >> ${TARGET}/etc/apt/sources.list.d/puppetlabs.list << EOF
deb ${DEBIAN_REPO_TRANSPORT}://${DEBIAN_REPO_HOST}/puppetlabs/ ${DEBIAN_RELEASE} main puppet dependencies
EOF

  PUPPET_GPG_KEY="6F6B15509CF8E59E6E469F327F438280EF8D349F"

  TRY=60
  while ! chroot ${TARGET} apt-key adv --recv-keys --keyserver "${GPG_KEY_SERVER}" "${PUPPET_GPG_KEY}" ; do
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

  if [ "$DEBIAN_RELEASE" = "stretch" ]; then
    chroot ${TARGET} ln -s /proc/self/mounts /etc/mtab || true
  fi

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

# don't leave any mountpoints
sync
umount ${TARGET}/proc       2>/dev/null || true
umount ${TARGET}/sys        2>/dev/null || true
umount ${TARGET}/dev/pts    2>/dev/null || true
umount ${TARGET}/dev        2>/dev/null || true
sync

# unmount chroot - what else?
umount $TARGET || umount -l $TARGET # fall back if a process is still being active

if "$LVM" ; then
  # make sure no device mapper handles are open, otherwise
  # rereading partition table won't work
  dmsetup remove_all || true
fi

# make sure /etc/fstab is up2date
if ! blockdev --rereadpt "/dev/${DISK}" ; then
  echo "Something on disk /dev/${DISK} (mountpoint $TARGET) seems to be still active, debugging output follows:"
  ps auxwww || true
fi

# party time! who brings the whiskey?
echo "Installation finished. \o/"
echo
echo

[ -n "$start_seconds" ] && SECONDS="$(( $(cut -d . -f 1 /proc/uptime) - start_seconds))" || SECONDS="unknown"
logit "Successfully finished deployment process [$(date) - running ${SECONDS} seconds]"
echo "Successfully finished deployment process [$(date) - running ${SECONDS} seconds]"

if [ "$(get_deploy_status)" != "error" ] ; then
  set_deploy_status "finished"
fi

if [[ -n "$STATUS_WAIT" && "$STATUS_WAIT" != 0 ]]; then
  # if ngcpstatus boot option is used wait for a specific so a
  # remote host has a chance to check for deploy status "finished",
  # defaults to 0 seconds otherwise
  echo "Sleeping for $STATUS_WAIT seconds (as requested via boot option 'ngcpstatus')"
  sleep "$STATUS_WAIT"
fi

if "$INTERACTIVE" ; then
  exit 0
fi

# do not prompt when running in automated mode
if "$REBOOT" ; then
  echo "Rebooting system as requested via ngcpreboot"
  for key in s u b ; do
    echo $key > /proc/sysrq-trigger
    sleep 2
  done
fi

if "$HALT" ; then
  echo "Halting system as requested via ngcphalt"

  for key in s u o ; do
    echo $key > /proc/sysrq-trigger
    sleep 2
  done
fi

echo "Do you want to [r]eboot or [h]alt the system now? (Press any other key to cancel.)"
unset a
read a
case "$a" in
  r)
    echo "Rebooting system as requested."
    # reboot is for losers
    for key in s u b ; do
      echo $key > /proc/sysrq-trigger
      sleep 2
    done
  ;;
  h)
    echo "Halting system as requested."
    # halt(8) is for losers
    for key in s u o ; do
      echo $key > /proc/sysrq-trigger
      sleep 2
    done
  ;;
  *)
    echo "Not halting system as requested. Please do not forget to reboot."
    ;;
esac

## END OF FILE #################################################################1
