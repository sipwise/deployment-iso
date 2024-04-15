#!/bin/bash
# Purpose: automatically install Debian + Sipwise C5 platform
################################################################################

set -e
set -E

# Functions

usage() {
  echo "$0 - automatically deploy Debian ${DEBIAN_RELEASE} and (optionally) ngcp ce/pro.

Control installation parameters:

  debugmode                - enable additional debug information
  help|-h|--help           - show this message
  ngcphalt                 - poweroff the server in the end of deployment
  ngcpnw.dhcp              - use DHCP as network configuration in installed system
  ngcpreboot               - reboot the server in the end of deployment
  ngcpstatus=...           - sleep for number of seconds befor deployment.sh is finished
  nocolorlogo              - print the logo in the top of he screen
  noinstall                - do not install neither Debian nor NGCP
  nongcp                   - do not install NGCP but install plain Debian only

Control target system:

  arch=...                 - use specified architecture of debian packages
  debianrelease=...        - install specified Debian release
  debianrepo=...           - hostname of Debian APT repository mirror
  debianrepotransport=...  - use specified transport for Debian repository
  enablevmservices         - add some tricks for installation to VM
  fallbackfssize=...       - size of ngcp-fallback partition. Equal to ngncp-root size if not specified
  ip=...                   - standard Linux kernel ip= boot option
  lowperformance           - add some tuning for low performance systems
  ngcpce                   - install CE Edition
  ngcpcrole=...            - server role (Carrier)
  ngcpeaddr=...            - cluster IP address
  ngcpextnetmask=...       - use the following netmask for external interface
  ngcphostname=...         - hostname of installed system (defaults to ngcp/sp[1,2])
  ngcpinst                 - force usage of NGCP installer
  ngcpip1=...              - IP address of first node (Pro Edition only)
  ngcpip2=...              - IP address of second node (Pro Edition only)
  ngcpipshared=...         - HA shared IP address
  ngcpmgmt=...             - name of management node
  ngcpnetmask=...          - netmask of ha_int interface
  ngcpnodename=...         - name of the node in terms of spN
  ngcpnomysqlrepl          - skip MySQL sp1<->sp2 replication configuration/check
  ngcpppa                  - use NGCP PPA Debian repository
  ngcppro                  - install Pro Edition
  ngcppxeinstall           - shows that system is deployed via iPXE
  ngcpupload               - run ngcp-prepare-translations in the end of configuration
  ngcpvers=...             - install specific SP/CE version
  ngcpvlanbootint=...      - currently, not used
  ngcpvlanhaint=...        - the ID of the vlan that is used for ha_int interface type
  ngcpvlanrtpext=...       - the ID of the vlan that is used for rtp_ext interface type
  ngcpvlansipext=...       - the ID of the vlan that is used for sip_ext interface type
  ngcpvlansipint=...       - the ID of the vlan that is used for sip_int interface type
  ngcpvlansshext=...       - the ID of the vlan that is used for ssh_ext interface type
  ngcpvlanwebext=...       - the ID of the vlan that is used for web_ext interface type
  noeatmydata              - use noeatmydata program to speed up packages installation
  nopuppetrepeat           - do not repeat puppet deployment in case of errors
  puppetenv=...            - use specified puppet environment
  puppetgitbranch=...      - use specified git branch to get puppet configuration
  puppetgitrepo=...        - clone puppet configuration from specified git repo
  puppetserver=...         - install puppet configuration from specified puppet server
  rootfssize=...           - size of ngcp-root partition
  sipwiserepo=...          - hostname of Sipwise APT repository mirror
  sipwiserepotransport=... - use specified transport for Sipwise repository
  swapfilesize=...         - size of swap file in megabytes
  swraiddestroy            - destroy the currently configured RAID and create a new one
  swraiddisk1=...          - the 1st device which will be used for software RAID
  swraiddisk2=...          - the 2nd device which will be used for software RAID
  targetdisk=...           - use specified disk to place the system
  vagrant                  - add some tricks for creation of vagrant image


The command line options correspond with the available bootoptions.
Command line overrides any present bootoption.

Usage examples:

  # ngcp-deployment ngcpce ngcpnw.dhcp

  # netcardconfig # configure eth0 with static configuration
  # ngcp-deployment ngcppro ngcpnodename=sp1

  # netcardconfig # configure eth0 with static configuration
  # ngcp-deployment ngcppro ngcpnodename=sp2
"
}

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

  cat > /etc/systemd/system/deployment-status.service << EOF
[Unit]
Description=Deployment Status Server
After=network.target

[Service]
Type=simple
Restart=always
ExecStart=/usr/bin/python3 -m http.server 4242 --directory=/srv/deployment/

[Install]
WantedBy=sysinit.target
EOF
  systemctl daemon-reload
  systemctl restart deployment-status.service
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
target_file=sipwise-keyring-bootstrap.gpg
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
  TMPDIR=$(mktemp -d -t ngcp-deployment-recent-tmp.XXXXXXXXXX)
  mkdir -p "${TMPDIR}/statedir/lists/partial" "${TMPDIR}/cachedir/archives/partial"
  local debsrcfile
  debsrcfile=$(mktemp -t ngcp-deployment-recent-debsrc.XXXXXXXXXX)
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
  declare -a packages=("$@")

  if [[ "${#packages[@]}" -eq 0 ]]; then
    packages=("${ADDITIONAL_PACKAGES[@]}")
  fi

  if [[ "${#packages[@]}" -eq 0 ]]; then
   return 0
  fi

  local install_packages
  install_packages=()
  echo "Ensuring packages installed: ${packages[*]}"
  for pkg in "${packages[@]}"; do
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
  TMPDIR=$(mktemp -d -t ngcp-deployment-ensure-tmp.XXXXXXXXXX)
  mkdir -p "${TMPDIR}/etc/preferences.d" "${TMPDIR}/statedir/lists/partial" \
    "${TMPDIR}/cachedir/archives/partial"
  chown _apt -R "${TMPDIR}"

  local deb_release
  case "${DEBIAN_RELEASE}" in
    buster|bullseye|bookworm)
      deb_release="${DEBIAN_RELEASE}"
      echo "Using ${deb_release} as Debian repository for ${FUNCNAME[0]}"
      ;;
    *)
      deb_release='bookworm'
      echo "Enabling fallback to Debian ${deb_release} repository for ${FUNCNAME[0]}"
      ;;
  esac

  echo "deb ${DEBIAN_URL}/debian/ ${deb_release} main contrib non-free" > \
    "${TMPDIR}/etc/sources.list"

  mkdir -p "${TMPDIR}"/etc/apt/apt.conf.d/
  cat > "${TMPDIR}"/etc/apt/apt.conf.d/73_acquire_retries << EOF
# NGCP_MANAGED_FILE -- deployment.sh
Acquire::Retries "3";
EOF

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
  if lsmod | grep -q efivarfs ; then
    echo "EFI support detected."
    return 0
  fi

  if modprobe efivarfs &>/dev/null ; then
    echo "EFI support enabled now."
    return 0
  fi

  return 1
}

# Debian kernels >=5.10 don't provide efivars support, ensure to either:
# 1) have grml-debootstrap v0.99 or newer available (which provides according
# efivarfs workaround), or otherwise:
# 2) apply local workaround using post script within grml-debootstrap
# (to avoid having to update the grml-debootstrap package, because that's not
# available within environments relying on our approx Debian mirror, which
# doesn't provide the Grml repository)
efivars_workaround() {
  if lsmod | grep -q 'efivars' ; then
    echo "We do have efivars support, no need to apply workarounds"
    return 0
  fi

  echo "Running with kernel without efivars support"
  if check_package_version grml-debootstrap 0.99~ ; then
    echo "grml-debootstrap >=0.99 available, no need to apply pre/post script workaround"
    return 0
  fi

  echo "Present grml-debootstrap version is not recent enough, falling back to workarounds using local script"

  # pre script, relevant for grml-debootstrap versions <=0.96 with EFI environments
  mkdir -p /etc/debootstrap/pre-scripts/
  cat > /etc/debootstrap/pre-scripts/efivarfs << "EOL"
#!/bin/bash
set -eu -p pipefail

echo "Executing $0"

if ! ls "${MNTPOINT}"/sys/firmware/efi/efivars/* &>/dev/null ; then
  # we need to have /sys available to be able to mount /sys/firmware/efi/efivars
  if ! chroot "${MNTPOINT}" test -d /sys/kernel ; then
    echo "Mointing /sys"
    chroot "${MNTPOINT}" mount -t sysfs none /sys
  fi

  echo "Mounting efivarfs on /sys/firmware/efi/efivars"
  chroot "${MNTPOINT}" mount -t efivarfs efivarfs /sys/firmware/efi/efivars
fi
echo "Finished execution of $0"
EOL

  chmod 775 /etc/debootstrap/pre-scripts/efivarfs
  PRE_SCRIPTS_OPTION="--pre-scripts /etc/debootstrap/pre-scripts/"

  # post script
  mkdir -p /etc/debootstrap/post-scripts/
  cat > /etc/debootstrap/post-scripts/efivarfs << "EOL"
#!/bin/bash
set -eu -p pipefail

echo "Executing $0"

if ! [ -e "${MNTPOINT}"/dev/mapper/ngcp-root ] ; then
  echo "Mounting /dev (via bind mount)"
  mount --bind /dev "${MNTPOINT}"/dev/
fi

if ! [ -e "${MNTPOINT}"/proc/cmdline ] ; then
  echo "Mounting /proc"
  chroot "${MNTPOINT}" mount -t proc none /proc
fi

if ! ls "${MNTPOINT}"/sys/firmware/efi/efivars/* &>/dev/null ; then
  # we need to have /sys available to be able to mount /sys/firmware/efi/efivars
  if ! chroot "${MNTPOINT}" test -d /sys/kernel ; then
    echo "Mointing /sys"
    chroot "${MNTPOINT}" mount -t sysfs none /sys
  fi

  echo "Mounting efivarfs on /sys/firmware/efi/efivars"
  chroot "${MNTPOINT}" mount -t efivarfs efivarfs /sys/firmware/efi/efivars
fi

if ! [ -d "${MNTPOINT}"/boot/efi/EFI ] ; then
  echo "Mounting /boot/efi"
  chroot "${MNTPOINT}" mount /boot/efi
fi

echo "Invoking grub-install with proper EFI environment"
chroot "${MNTPOINT}" grub-install

for f in /boot/efi /sys/firmware/efi/efivars /sys /proc /dev ; do
  if mountpoint "${MNTPOINT}/$f" &>/dev/null ; then
    echo "Unmounting $f"
    umount "${MNTPOINT}/$f"
  fi
done

echo "Finished execution of $0"
EOL

  chmod 775 /etc/debootstrap/post-scripts/efivarfs
  POST_SCRIPTS_OPTION="--post-scripts /etc/debootstrap/post-scripts/"
}

cdr2mask() {
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

clear_partition_table() {
  local blockdevice="$1"

  if [[ ! -b "${blockdevice}" ]] ; then
    die "Error: ${blockdevice} doesn't look like a valid block device." >&2
  fi

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

  # ensure we remove signatures from partitions like /dev/nvme1n1p3 first,
  # and only then get rid of signaturs from main blockdevice /dev/nvme1n1
  for partition in $(lsblk --noheadings --output KNAME "${blockdevice}" | grep -v "^${blockdevice#\/dev\/}$" || true) ; do
    [ -b "${partition}" ] || continue
    echo "Wiping disk signatures from partition ${partition}"
    wipefs -a "${partition}"
  done

  echo "Wiping disk signatures from ${blockdevice}"
  wipefs -a "${blockdevice}"

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
  local orig_swraid_device raidev1 raidev2 raid_device raid_disks

  # make sure we don't overlook unassembled SW-RAIDs:
  mdadm --assemble --scan --config /dev/null || true # fails if there's nothing to assemble

  # "local" arrays get assembled as /dev/md0 and upwards,
  # whereas "foreign" arrays start ad md127 downwards;
  # since we need to also handle those, identify them:
  raid_device=$(lsblk --list --noheadings --output TYPE,NAME | awk '/^raid/ {print $2}' | head -1)

  # only consider changing SWRAID_DEVICE if we actually identified an RAID array:
  if [[ -n "${raid_device:-}" ]] ; then
    if ! [[ -b /dev/"${raid_device}" ]] ; then
      die "Error: identified SW-RAID device '/dev/${raid_device}' not a valid block device."
    fi

    # identify which disks are part of the RAID array:
    raid_disks=$(lsblk -l -n -s /dev/"${raid_device}" | grep -vw "^${raid_device}" | awk '{print $1}')
    for d in ${raid_disks} ; do
      # compare against expected SW-RAID disks to avoid unexpected behavior:
      if ! printf "%s\n" "$d" | grep -qE "(${SWRAID_DISK1}|${SWRAID_DISK2})" ; then
        die "Error: unexpected disk in RAID array /dev/${raid_device}: $d [expected SW-RAID disks: $SWRAID_DISK1 + $SWRAID_DISK2]"
      fi
    done

    # remember the original setting, so we can use it after mdadm cleanup:
    orig_swraid_device="${SWRAID_DEVICE}"

    echo "NOTE: default SWRAID_DEVICE set to ${SWRAID_DEVICE} though we identified active ${raid_device}"
    SWRAID_DEVICE="/dev/${raid_device}"
    echo "NOTE: will continue with '${SWRAID_DEVICE}' as SWRAID_DEVICE for mdadm cleanup"
  fi

  if [[ -b "${SWRAID_DEVICE}" ]] ; then
    if [[ "${SWRAID_DESTROY}" = "true" ]] ; then
      echo "Wiping signatures from ${SWRAID_DEVICE}"
      wipefs -a "${SWRAID_DEVICE}"

      echo "Removing mdadm device ${SWRAID_DEVICE}"
      mdadm --remove "${SWRAID_DEVICE}"

      echo "Stopping mdadm device ${SWRAID_DEVICE}"
      mdadm --stop "${SWRAID_DEVICE}"

      echo "Zero-ing superblock from /dev/${SWRAID_DISK1}"
      mdadm --zero-superblock "/dev/${SWRAID_DISK1}"

      echo "Zero-ing superblock from /dev/${SWRAID_DISK2}"
      mdadm --zero-superblock "/dev/${SWRAID_DISK2}"
    else
      echo "NOTE: if you are sure you don't need it SW-RAID device any longer, execute:"
      echo "      mdadm --remove ${SWRAID_DEVICE} ; mdadm --stop ${SWRAID_DEVICE}; mdadm --zero-superblock /dev/sd..."
      echo "      (also you can use boot option 'swraiddestroy' to destroy SW-RAID automatically)"
      die "Error: SW-RAID device ${SWRAID_DEVICE} exists already."
    fi
  fi

  if [[ -n "${orig_swraid_device:-}" ]] ; then
    echo "NOTE: modified RAID array detected, setting SWRAID_DEVICE back to original setting '${orig_swraid_device}'"
    SWRAID_DEVICE="${orig_swraid_device}"
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
  local root_size="${ROOTFS_SIZE:-8G}"
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

enable_ntp() {
  echo "Displaying original timedatectl status:"
  timedatectl status

  if systemctl cat chrony &>/dev/null ; then
    echo "Ensuring chrony service is running"
    systemctl start chrony

    echo "Enabling NTP synchronization"
    timedatectl set-ntp true || true
  elif systemctl cat ntpsec &>/dev/null ; then
    echo "Ensuring ntpsec service is running"
    systemctl start ntpsec

    echo "Enabling NTP synchronization"
    timedatectl set-ntp true || true
  else
    echo "No ntp service identified, skipping NTP synchronization"
  fi

  echo "Disabling RTC for local time"
  timedatectl set-local-rtc false

  echo "Displaying new timedatectl status:"
  timedatectl status
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

retrieve_deployment_scripts_fake_uname() {
  local target_path="$1"
  case "${SP_VERSION}" in
    trunk)
      local repos_base_path="${SIPWISE_URL}/autobuild/dists/release-trunk-${DEBIAN_RELEASE}/main/binary-amd64/"
      local deployment_path="${SIPWISE_URL}/autobuild/pool/main/n/ngcp-deployment-iso"
      ;;
    trunk-weekly)
      local repos_base_path="${SIPWISE_URL}/autobuild/release/release-${SP_VERSION}/dists/release-${SP_VERSION}/main/binary-amd64/"
      local deployment_path="${SIPWISE_URL}/autobuild/release/release-${SP_VERSION}/pool/main/n/ngcp-deployment-iso/"
      ;;
    *)
      echo "NOTE: SP_VERSION is unset, assuming we're installing a non-NGCP system"
      echo "NOTE: using fake-uname.so of ngcp-deployment-scripts from release-trunk-${DEBIAN_RELEASE}"
      local repos_base_path="${SIPWISE_URL}/autobuild/dists/release-trunk-${DEBIAN_RELEASE}/main/binary-amd64/"
      local deployment_path="${SIPWISE_URL}/autobuild/pool/main/n/ngcp-deployment-iso"
      ;;
  esac

  wget --timeout=30 -O Packages.gz "${repos_base_path}Packages.gz"
  # sed: display paragraphs matching the "Package: ..." string, then grab string "^Version: " and display the actual version via awk
  # sort -u to avoid duplicates in repositories
  local version
  version=$(zcat Packages.gz | sed "/./{H;\$!d;};x;/Package: ngcp-deployment-scripts/b;d" | awk '/^Version: / {print $2}' | sort -u)

  [ -n "$version" ] || die "Error: ngcp-deployment-scripts version for release-trunk-${DEBIAN_RELEASE} could not be detected."

  # retrieve Debian package
  local deb_package="ngcp-deployment-scripts_${version}_amd64.deb"
  local deployment_scripts_package="${deployment_path}/${deb_package}"
  wget --timeout=30 -O "/root/${deb_package}" "${deployment_scripts_package}"

  # extract Debian package
  dpkg -x "/root/${deb_package}" /root/ngcp-deployment-scripts/

  # finally install extracted fake-uname.so towards target
  if [ -r /root/ngcp-deployment-scripts/usr/lib/ngcp-deployment-scripts/fake-uname.so ] ; then
    echo "Installing fake-uname.so from ${deb_package} to ${target_path}"
    cp /root/ngcp-deployment-scripts/usr/lib/ngcp-deployment-scripts/fake-uname.so "${target_path}" || die "Failed to install fake_uname.so in ${target_path}"
  else
    die "Error: can not access fake-uname.so from /root/${deb_package}"
  fi
}

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
  if "${PRO_EDITION}" || "${CARRIER_EDITION}" ; then
    local installer_package='ngcp-installer-pro'
    local repos_base_path="${SIPWISE_URL}/sppro/${SP_VERSION}/dists/${DEBIAN_RELEASE}/main/binary-amd64/"
    INSTALLER_PATH="${SIPWISE_URL}/sppro/${SP_VERSION}/pool/main/n/ngcp-installer/"
  else
    local installer_package='ngcp-installer-ce'
    local repos_base_path="${SIPWISE_URL}/spce/${SP_VERSION}/dists/${DEBIAN_RELEASE}/main/binary-amd64/"
    INSTALLER_PATH="${SIPWISE_URL}/spce/${SP_VERSION}/pool/main/n/ngcp-installer/"
  fi

  # use a separate repos for trunk releases
  if $TRUNK_VERSION ; then
    case "${SP_VERSION}" in
      trunk)
        local repos_base_path="${SIPWISE_URL}/autobuild/dists/release-trunk-${DEBIAN_RELEASE}/main/binary-amd64/"
        INSTALLER_PATH="${SIPWISE_URL}/autobuild/pool/main/n/ngcp-installer/"
        ;;
      trunk-weekly)
        local repos_base_path="${SIPWISE_URL}/autobuild/release/release-${SP_VERSION}/dists/release-${SP_VERSION}/main/binary-amd64/"
        INSTALLER_PATH="${SIPWISE_URL}/autobuild/release/release-${SP_VERSION}/pool/main/n/ngcp-installer/"
        ;;
      *) die "Error: unknown TRUNK_VERSION ${SP_VERSION}" ;;
    esac
  fi

  if [ -n "${NGCP_PPA}" ] ; then
    local ppa_tmp_packages
    ppa_tmp_packages=$(mktemp -t ngcp-deployment-installer-path.XXXXXXXXXX)

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

  if "${PRO_EDITION}" || "${CARRIER_EDITION}" ; then
    INSTALLER="ngcp-installer-pro_${version}_all.deb"
  else
    INSTALLER="ngcp-installer-ce_${version}_all.deb"
  fi
}

set_repos() {
  cat > "${TARGET}/etc/apt/sources.list" << EOF
# Please visit /etc/apt/sources.list.d/ instead.
EOF

  cat > "${TARGET}/etc/apt/sources.list.d/debian.list" << EOF
## custom sources.list, deployed via deployment.sh

# Debian repositories
deb ${MIRROR} ${DEBIAN_RELEASE} main contrib non-free
deb ${SEC_MIRROR} ${DEBIAN_RELEASE}-security main contrib non-free
deb ${MIRROR} ${DEBIAN_RELEASE}-updates main contrib non-free
deb ${DBG_MIRROR} ${DEBIAN_RELEASE}-debug main contrib non-free
EOF

  mkdir -p "${TARGET}"/etc/apt/apt.conf.d/
  cat > "${TARGET}"/etc/apt/apt.conf.d/73_acquire_retries << EOF
# NGCP_MANAGED_FILE -- deployment.sh
Acquire::Retries "3";
EOF
}

gen_installer_config() {
  local conf_file
  conf_file="${TARGET}/etc/ngcp-installer/config_deploy.inc"
  truncate -s 0 "${conf_file}"

  if "${CARRIER_EDITION}" ; then
    cat >> "${conf_file}" << EOF
CARRIER=true
PRO=false
CE=false
EOF
  elif "${PRO_EDITION}" ; then
    cat >> "${conf_file}" << EOF
CARRIER=false
PRO=true
CE=false
EOF
  elif "${CE_EDITION}" ; then
    cat >> "${conf_file}" << EOF
CARRIER=false
PRO=false
CE=true
EOF
  fi

  if "${CARRIER_EDITION}" ; then
    cat >> "${conf_file}" << EOF
CROLE="${CROLE}"
VLAN_BOOT_INT="${VLAN_BOOT_INT}"
VLAN_HA_INT="${VLAN_HA_INT}"
VLAN_RTP_EXT="${VLAN_RTP_EXT}"
VLAN_SIP_EXT="${VLAN_SIP_EXT}"
VLAN_SIP_INT="${VLAN_SIP_INT}"
VLAN_SSH_EXT="${VLAN_SSH_EXT}"
VLAN_WEB_EXT="${VLAN_WEB_EXT}"
EOF
  fi
  if "${PRO_EDITION}" ; then
    cat >> "${conf_file}" << EOF
DPL_MYSQL_REPLICATION="${DPL_MYSQL_REPLICATION}"
FILL_APPROX_CACHE="${FILL_APPROX_CACHE}"
HNAME="${NODE_NAME}"
INTERNAL_DEV="${INTERNAL_DEV}"
INTERNAL_NETMASK="${INTERNAL_NETMASK}"
IP1="${IP1}"
IP2="${IP2}"
IP_HA_SHARED="${IP_HA_SHARED}"
MANAGEMENT_IP="${MANAGEMENT_IP}"
NETWORK_DEVICES="${NETWORK_DEVICES}"
NGCP_PXE_INSTALL="${NGCP_PXE_INSTALL}"
TARGET_HOSTNAME="${TARGET_HOSTNAME}"
EOF
  fi

  cat >> "${conf_file}" << EOF
ADJUST_FOR_LOW_PERFORMANCE="${ADJUST_FOR_LOW_PERFORMANCE}"
DEBUG_MODE="${DEBUG_MODE}"
DEPLOYMENT_SH=true
DHCP="${DHCP}"
EADDR="${EADDR}"
ENABLE_VM_SERVICES="${ENABLE_VM_SERVICES}"
export NGCP_INSTALLER=true
EXTERNAL_DEV="${EXTERNAL_DEV}"
EXTERNAL_NETMASK="${EXTERNAL_NETMASK}"
FALLBACKFS_SIZE="${FALLBACKFS_SIZE}"
FORCE=no
GW="${GW}"
NAMESERVER="$(awk '/^nameserver/ {print $2}' /etc/resolv.conf)"
NGCP_PPA="${NGCP_PPA}"
ORIGIN_INSTALL_DEV="${ORIGIN_INSTALL_DEV}"
ROOTFS_SIZE="${ROOTFS_SIZE}"
SIPWISE_REPO_HOST="${SIPWISE_REPO_HOST}"
SIPWISE_URL="${SIPWISE_URL}"
STATUS_WAIT_SECONDS=${STATUS_WAIT}
SWAPFILE_SIZE_MB="${SWAPFILE_SIZE_MB}"
EOF

  if "${TRUNK_VERSION}" && "${NGCP_UPLOAD}"; then
    echo "NGCPUPLOAD=true" >> "${TARGET}/etc/ngcp-installer/config_deploy.inc"
  else
    echo "NGCPUPLOAD=false" >> "${TARGET}/etc/ngcp-installer/config_deploy.inc"
  fi
}

vagrant_configuration() {
  # bzip2, linux-headers-amd64 and make are required for VirtualBox Guest Additions installer
  # less + sudo are required for Vagrant itself
  echo "Installing software for VirtualBox Guest Additions installer"
  if ! grml-chroot "${TARGET}" apt-get -y install bzip2 less libxmu6 linux-headers-amd64 make sudo ; then
    die "Error: failed to install 'bzip2 less libxmu6 linux-headers-amd64 make sudo' packages."
  fi

  vagrant_ssh_pub_key='/var/tmp/id_rsa_sipwise.pub'
  echo "Fetching Sipwise vagrant public key from builder.mgm.sipwise.com"
  if ! wget -O "${vagrant_ssh_pub_key}" http://builder.mgm.sipwise.com/vagrant-ngcp/id_rsa_sipwise.pub ; then
    die "Error: failed to wget public Sipwise SSH key for Vagrant boxes"
  fi

  ensure_packages_installed 'virtualbox-guest-additions-iso'

  if "$NGCP_INSTALLER" ; then
    local SIPWISE_HOME="/nonexistent"
    # it's necessary to use chroot instead of grml-chroot in variable=$() calls
    # as grml-chroot also prints "Writing /etc/debian_chroot ..." line
    # which breaks output
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
    grml-chroot "${TARGET}" chown sipwise:sipwise "${SIPWISE_HOME}/.ssh" "${SIPWISE_HOME}/.ssh/sipwise_vagrant_key"
    grml-chroot "${TARGET}" chmod 0600 "${SIPWISE_HOME}/.ssh/sipwise_vagrant_key"
  fi

  echo "Adjusting ssh configuration for user root"
  mkdir -p "${TARGET}/root/.ssh/"
  cat "${vagrant_ssh_pub_key}" >> "${TARGET}/root/.ssh/sipwise_vagrant_key"
  grml-chroot "${TARGET}" chmod 0600 /root/.ssh/sipwise_vagrant_key
  sed -i 's|^[#\s]*\(AuthorizedKeysFile.*\)$|\1 %h/.ssh/sipwise_vagrant_key|g' "${TARGET}/etc/ssh/sshd_config"

  # see https://github.com/mitchellh/vagrant/issues/1673
  # and https://bugs.launchpad.net/ubuntu/+source/xen-3.1/+bug/1167281
  if ! grep -q 'adjusted for Vagrant' "${TARGET}/root/.profile" ; then
    echo "Adding workaround for annoying bug 'stdin: is not a tty' Vagrant message"
    sed -ri -e "s/mesg\s+n/# adjusted for Vagrant\ntty -s \&\& mesg n/" "${TARGET}/root/.profile"
  fi

  # shellcheck disable=SC2010
  KERNELHEADERS=$(basename "$(ls -d "${TARGET}"/usr/src/linux-headers*amd64 | grep -v -- -rt-amd64 | sort -u -r -V | head -1)")
  if [ -z "$KERNELHEADERS" ] ; then
    die "Error: no kernel headers found for building the VirtualBox Guest Additions kernel module."
  fi
  KERNELVERSION=${KERNELHEADERS##linux-headers-}
  if [ -z "$KERNELVERSION" ] ; then
    die "Error: no kernel version could be identified."
  fi

  local VIRTUALBOX_DIR="/usr/share/virtualbox"
  local VIRTUALBOX_ISO="VBoxGuestAdditions.iso"
  local vbox_isofile="${VIRTUALBOX_DIR}/${VIRTUALBOX_ISO}"

  if [ ! -r "$vbox_isofile" ] ; then
    die "Error: could not find $vbox_isofile"
  fi

  mkdir -p "${TARGET}/media/cdrom"
  mountpoint "${TARGET}/media/cdrom" >/dev/null && umount "${TARGET}/media/cdrom"
  mount -t iso9660 "${vbox_isofile}" "${TARGET}/media/cdrom/"
  # avoid "ERROR: ld.so: object '/usr/lib/ngcp-deployment-scripts/fake-uname.so' from LD_PRELOAD cannot be preloaded: ignored."
  # messages caused by the host system when running grml-chroot process
  mkdir -p /usr/lib/ngcp-deployment-scripts/
  if [ -r /mnt/usr/lib/ngcp-deployment-scripts/fake-uname.so ] ; then
    cp /mnt/usr/lib/ngcp-deployment-scripts/fake-uname.so /usr/lib/ngcp-deployment-scripts/
    FAKE_UNAME='/usr/lib/ngcp-deployment-scripts/fake-uname.so'
  else
    echo "File /mnt/usr/lib/ngcp-deployment-scripts/fake-uname.so does not exist (building base image without ngcp?)"
    echo "Trying to retrieve fake-uname.so from ngcp-deployment-scripts of release-trunk..."
    retrieve_deployment_scripts_fake_uname /tmp/
    # we don't have /usr/lib/ngcp-deployment-scripts/, so use it
    # via /tmp as that's automatically cleaned during reboot
    cp /tmp/fake-uname.so /mnt/tmp/
    FAKE_UNAME='/tmp/fake-uname.so'
  fi

  local vbox_systemd_workaround=false
  if ! [ -d "${TARGET}/run/systemd/system" ] ; then
    echo "Creating /run/systemd/system for systemd detection within VBoxLinuxAdditions"
    mkdir -p "${TARGET}/run/systemd/system"
    vbox_systemd_workaround=true
  fi

  grml-chroot "${TARGET}" env \
    UTS_RELEASE="${KERNELVERSION}" LD_PRELOAD="${FAKE_UNAME}" \
    /media/cdrom/VBoxLinuxAdditions.run --nox11 || true
  tail -10 "${TARGET}/var/log/vboxadd-install.log"
  umount "${TARGET}/media/cdrom/"

  if "${vbox_systemd_workaround}" ; then
    echo "Removing /run/systemd/system workaround for VBoxLinuxAdditions again"
    rmdir "${TARGET}/run/systemd/system" || true
  fi

  # VBoxLinuxAdditions.run chooses /usr/lib64 as soon as this directory exists, which
  # is the case for our PRO systems shipping the heartbeat-2 package; then the
  # symlink /sbin/mount.vboxsf points to the non-existing /usr/lib64/VBoxGuestAdditions/mount.vboxsf
  # file instead of pointing to /usr/lib/x86_64-linux-gnu/VBoxGuestAdditions/mount.vboxsf
  if ! grml-chroot "${TARGET}" readlink -f /sbin/mount.vboxsf ; then
    echo "Installing mount.vboxsf symlink to work around /usr/lib64 issue"
    ln -sf /usr/lib/x86_64-linux-gnu/VBoxGuestAdditions/mount.vboxsf "${TARGET}/sbin/mount.vboxsf"
  fi

  if [ -d "${TARGET}/etc/.git" ]; then
    echo "Commit /etc/* changes using etckeeper"
    grml-chroot "${TARGET}" etckeeper commit "Vagrant/VirtualBox changes on /etc/*"
  fi

  # disable vbox services so they are not run after reboot
  # remove manually as we are in chroot now so can not use systemctl calls
  # can be changed with systemd-nspawn
  rm -f "${TARGET}/etc/systemd/system/multi-user.target.wants/vboxadd-service.service"
  rm -f "${TARGET}/etc/systemd/system/multi-user.target.wants/vboxadd.service"
}

check_puppet_rc() {
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

  if ! "${NO_PUPPET_REPEAT}" && [ "$(get_deploy_status)" = "error" ] ; then
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
    elif "${NO_PUPPET_REPEAT}"; then
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

puppet_install_from_git() {
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
  echo 'ssh -i ~/.ssh/id_rsa_r10k -o PubkeyAcceptedKeyTypes=+ssh-rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $*' > ssh
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
    grml-chroot "${TARGET}" puppet apply --test --modulepath="${PUPPET_CODE_PATH}/modules" \
          -e "include puppet::hiera" 2>&1 | tee -a /tmp/puppet.log
    check_puppet_rc "${PIPESTATUS[0]}" "2"
    check_puppet_rerun && repeat=true
  done

  repeat=true
  while $repeat ; do
    repeat=false
    echo "Running Puppet core deployment..."
    grml-chroot "${TARGET}" puppet apply --test --modulepath="${PUPPET_CODE_PATH}/modules" --tags core,apt \
          "${PUPPET_CODE_PATH}/manifests/site.pp" 2>&1 | tee -a /tmp/puppet.log
    check_puppet_rc "${PIPESTATUS[0]}" "2"
    check_puppet_rerun && repeat=true
  done

  repeat=true
  while $repeat ; do
    repeat=false
    echo "Running Puppet main deployment..."
    grml-chroot "${TARGET}" puppet apply --test --modulepath="${PUPPET_CODE_PATH}/modules" \
          "${PUPPET_CODE_PATH}/manifests/site.pp" 2>&1 | tee -a /tmp/puppet.log
    check_puppet_rc "${PIPESTATUS[0]}" "2"
    check_puppet_rerun && repeat=true
  done

  return 0
}

puppet_install_from_puppet() {
  local repeat

  check_puppetserver_time

  repeat=true
  while $repeat ; do
    repeat=false
    echo "Running Puppet core deployment..."
    grml-chroot "${TARGET}" puppet agent --test --tags core,apt 2>&1 | tee -a /tmp/puppet.log
    check_puppet_rc "${PIPESTATUS[0]}" "2"
    check_puppet_rerun && repeat=true
  done

  repeat=true
  while $repeat ; do
    repeat=false
    echo "Running Puppet main deployment..."
    grml-chroot "${TARGET}" puppet agent --test 2>&1 | tee -a /tmp/puppet.log
    check_puppet_rc "${PIPESTATUS[0]}" "2"
    check_puppet_rerun && repeat=true
  done

  return 0
}

set_custom_grub_boot_options() {
  echo "Adjusting default GRUB boot options (enabling net.ifnames=0)"
  sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 net.ifnames=0"/' "${TARGET}/etc/default/grub"

  echo "Invoking update-grub"
  grml-chroot "${TARGET}" update-grub

  if [ -d "${TARGET}/etc/.git" ]; then
    echo "Commit /etc/default/grub changes using etckeeper"
    grml-chroot "${TARGET}" etckeeper commit "/etc/default/grub changes"
  fi
}

get_ping_host() {
  local route

  route="$(route -n | awk '/^0\.0\.0\.0/{print $2}')"

  if [ -n "${route:-}" ] ; then
    ping_host="${route}"
    echo "Default route identified, using host ${ping_host}"
  else
    ping_host="${SIPWISE_REPO_HOST:-deb.sipwise.com}"
    echo "Default route identified, using host ${ping_host} instead"
  fi
}

wait_for_network_online() {
  local tries="${1:-30}"

  echo "Trying reach host ${ping_host} via ICMP/ping to check connectivity"
  while ! ping -O -D -c 1 -i 1 -W 1 "${ping_host}" ; do
    if [ "${tries}" -gt 0 ] ; then
      tries=$((tries-1))
      echo "Retrying ping to ${ping_host} again ($tries tries left)..."
      sleep 1
    else
      echo "WARN: couldn't reach host ${ping_host} via ICMP/ping, continuing anyway"
      break
    fi
  done
}

# Main script

INSTALL_LOG='/tmp/deployment-installer-debug.log'
exec  > >(tee -a $INSTALL_LOG    )
exec 2> >(tee -a $INSTALL_LOG >&2)

# ensure we can interact with stdin
grml_autoconfig_active=false
case "$(systemctl is-active grml-autoconfig)" in
  active|activating)
    grml_autoconfig_active=true
    ;;
esac

if "${grml_autoconfig_active}" ; then
  if systemctl cat grml-autoconfig.service | grep -q StandardInput=null ; then
    echo "Looks like we're running under systemd with /dev/null for stdin."
    echo "Re-executing with usage of /dev/tty1 for stdin"
    exec < /dev/tty1
  fi
fi

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
ADDITIONAL_PACKAGES=(git augeas-tools gdisk)
ADJUST_FOR_LOW_PERFORMANCE=false
ARCH=$(dpkg --print-architecture)
CARRIER_EDITION=false
CE_EDITION=false
CROLE=''
DEBIAN_RELEASE='bullseye'
DEBIAN_REPO_HOST="debian.sipwise.com"
DEBIAN_REPO_TRANSPORT="https"
DEBUG_MODE=false
DHCP=false
DPL_MYSQL_REPLICATION=true
EADDR=''
EATMYDATA=true
ENABLE_VM_SERVICES=false
EXTERNAL_NETMASK=''
FALLBACKFS_SIZE=''
FILESYSTEM="ext4"
FILL_APPROX_CACHE=true
HALT=false
INTERACTIVE=true
INTERNAL_DEV='eth1'
INTERNAL_NETMASK='255.255.255.248'
IP1='192.168.255.251'
IP2='192.168.255.252'
IP_HA_SHARED='192.168.255.250'
IP_LINE=''
LOGO=true
NGCP_INSTALLER=false
NGCP_PXE_INSTALL=false
NGCP_UPLOAD=false
NODE_NAME=''
NO_PUPPET_REPEAT=false
PRO_EDITION=false
PUPPET=''
PUPPET_GIT_BRANCH=master
PUPPET_GIT_REPO=''
PUPPET_LOCAL_GIT="${TARGET}/tmp/puppet.git"
PUPPET_RESCUE_LABEL="SIPWRESCUE*"
PUPPET_RESCUE_PATH="/mnt/rescue_drive"
PUPPET_SERVER='puppet.mgm.sipwise.com'
REBOOT=false
RETRIEVE_MGMT_CONFIG=false
ROOTFS_SIZE="10G"
SIPWISE_APT_KEY_PATH="/etc/apt/trusted.gpg.d/sipwise-keyring-bootstrap.gpg"
SIPWISE_REPO_HOST="deb.sipwise.com"
SIPWISE_REPO_TRANSPORT="https"
STATUS_DIRECTORY='/srv/deployment/'
STATUS_WAIT=0
SWAPFILE_SIZE_MB=""
SWAPFILE_SIZE_MB_MAX="16384"
SWAPFILE_SIZE_MB_MIN="4096"
SWRAID_DESTROY=false
SWRAID_DEVICE="/dev/md0"
SWRAID=false
TARGET='/mnt'
TRUNK_VERSION=false
VAGRANT=false
VLAN_BOOT_INT=2
VLAN_HA_INT=1721
VLAN_RTP_EXT=1722
VLAN_SIP_EXT=1719
VLAN_SIP_INT=1720
VLAN_SSH_EXT=300
VLAN_WEB_EXT=1718

# trap signals: 1 SIGHUP, 2 SIGINT, 3 SIGQUIT, 6 SIGABRT, 15 SIGTERM
trap 'wait_exit;' 1 2 3 6 15 ERR EXIT

echo "Host IP: $(ip-screen)"
echo "Deployment version: $SCRIPT_VERSION"

enable_deploy_status_server

set_deploy_status "checkBootParam"

declare -a PARAMS=()
CMD_LINE=$(cat /proc/cmdline)
PARAMS+=(${CMD_LINE})
PARAMS+=("$@")

for param in "${PARAMS[@]}" ; do
  case "${param}" in
    arch=*)
      ARCH="${param//arch=/}"
    ;;
    debianrelease=*)
      DEBIAN_RELEASE="${param//debianrelease=/}"
    ;;
    debianrepo=*)
      DEBIAN_REPO_HOST="${param//debianrepo=/}"
    ;;
    debianrepotransport=*)
      DEBIAN_REPO_TRANSPORT="${param//debianrepotransport=/}"
    ;;
    debugmode)
      DEBUG_MODE=true
      enable_trace
      echo "CMD_LINE: ${CMD_LINE}"
    ;;
    enablevmservices)
      ENABLE_VM_SERVICES=true
    ;;
    help|-help)
      usage
      exit 0
    ;;
    lowperformance)
      ADJUST_FOR_LOW_PERFORMANCE=true
    ;;
    ngcpce)
      CE_EDITION=true
      TARGET_HOSTNAME='spce'
      NGCP_INSTALLER=true
      NODE_NAME='spce'
    ;;
    ngcpcrole=*)
      CARRIER_EDITION=true
      CROLE="${param//ngcpcrole=/}"
    ;;
    ngcpeaddr=*)
      EADDR="${param//ngcpeaddr=/}"
    ;;
    ngcpextnetmask=*)
      EXTERNAL_NETMASK="${param//ngcpextnetmask=/}"
    ;;
    ngcphalt)
      HALT=true
    ;;
    ngcphostname=*)
      TARGET_HOSTNAME="${param//ngcphostname=/}"
    ;;
    ngcpinst)
      NGCP_INSTALLER=true
    ;;
    ngcpip1=*)
      IP1="${param//ngcpip1=/}"
    ;;
    ngcpip2=*)
      IP2="${param//ngcpip2=/}"
    ;;
    ngcpipshared=*)
      IP_HA_SHARED="${param//ngcpipshared=/}"
    ;;
    *ngcpnetmask=*)
      INTERNAL_NETMASK="${param//ngcpnetmask=/}"
    ;;
    ngcpnw.dhcp)
      DHCP=true
    ;;
    ngcpppa=*)
      NGCP_PPA="${param//ngcpppa=/}"
    ;;
    ngcppro)
      PRO_EDITION=true
      NGCP_INSTALLER=true
    ;;
    ngcpreboot)
      REBOOT=true
    ;;
    ngcpnodename=*)
      NODE_NAME="${param//ngcpnodename=/}"
    ;;
    ngcpstatus=*)
      STATUS_WAIT="${param//ngcpstatus=/}"
    ;;
    ngcpvers=*)
      SP_VERSION="${param//ngcpvers=/}"
    ;;
    ngcpvlanbootint=*)
      VLAN_BOOT_INT="${param//ngcpvlanbootint=/}"
    ;;
    ngcpvlanhaint=*)
      VLAN_HA_INT="${param//ngcpvlanhaint=/}"
    ;;
    ngcpvlanrtpext=*)
      VLAN_RTP_EXT="${param//ngcpvlanrtpext=/}"
    ;;
    ngcpvlansipext=*)
      VLAN_SIP_EXT="${param//ngcpvlansipext=/}"
    ;;
    ngcpvlansipint=*)
      VLAN_SIP_INT="${param//ngcpvlansipint=/}"
    ;;
    ngcpvlansshext=*)
      VLAN_SSH_EXT="${param//ngcpvlansshext=/}"
    ;;
    ngcpvlanwebext=*)
      VLAN_WEB_EXT="${param//ngcpvlanwebext=/}"
    ;;
    nocolorlogo)
      LOGO=false
    ;;
    noeatmydata)
      EATMYDATA=false
    ;;
    noinstall)
      echo "Exiting as requested via bootoption noinstall."
      exit 0
    ;;
    nongcp)
      NGCP_INSTALLER=false
    ;;
    targetdisk=*)
      TARGET_DISK="${param//targetdisk=/}"
    ;;
    swraiddestroy)
      SWRAID_DESTROY=true
    ;;
    swraiddisk1=*)
      SWRAID_DISK1="${param//swraiddisk1=/}"
      SWRAID_DISK1="${SWRAID_DISK1#/dev/}"
    ;;
    swraiddisk2=*)
      SWRAID_DISK2="${param//swraiddisk2=/}"
      SWRAID_DISK2="${SWRAID_DISK2#/dev/}"
    ;;
    swapfilesize=*)
      SWAPFILE_SIZE_MB="${param//swapfilesize=/}"
    ;;
    vagrant)
      VAGRANT=true
    ;;
    ngcpmgmt=*)
      MANAGEMENT_IP="${param//ngcpmgmt=/}"
      RETRIEVE_MGMT_CONFIG=true
    ;;
    puppetenv=*)
      # we expected to get the environment for puppet
      PUPPET="${param//puppetenv=/}"
    ;;
    puppetserver=*)
      PUPPET_SERVER="${param//puppetserver=/}"
    ;;
    puppetgitrepo=*)
      PUPPET_GIT_REPO="${param//puppetgitrepo=/}"
    ;;
    puppetgitbranch=*)
      PUPPET_GIT_BRANCH="${param//puppetgitbranch=/}"
    ;;
    rootfssize=*)
      ROOTFS_SIZE="${param//rootfssize=/}"
    ;;
    fallbackfssize=*)
      FALLBACKFS_SIZE="${param//fallbackfssize=/}"
    ;;
    sipwiserepo=*)
      SIPWISE_REPO_HOST="${param//sipwiserepo=/}"
    ;;
    ngcpnomysqlrepl)
      DPL_MYSQL_REPLICATION=false
    ;;
    sipwiserepotransport=*)
      SIPWISE_REPO_TRANSPORT="${param//sipwiserepotransport=/}"
    ;;
    ngcppxeinstall)
      NGCP_PXE_INSTALL=true
    ;;
    ip=*)
      IP_LINE="${param//ip=/}"
    ;;
    ngcpupload)
      NGCP_UPLOAD=true
    ;;
    nopuppetrepeat)
      NO_PUPPET_REPEAT=true
    ;;
    *)
      echo "Parameter ${param} not defined in script, skipping"
    ;;
  esac
done


disable_systemd_tmpfiles_clean

# configure static network in installed system?
if pgrep dhclient &>/dev/null ; then
  DHCP=true
fi

if [[ ${SP_VERSION} =~ ^trunk ]]; then
  TRUNK_VERSION=true
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
if [[ "${SWRAID}" = "true" ]] ; then
  DISK_INFO="Software-RAID with $SWRAID_DISK1 $SWRAID_DISK2"
else
  DISK_INFO="/dev/$DISK"
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

if "${CE_EDITION}"; then
  NGCP_INSTALLER_EDITION_STR="Sipwise C5:        CE"
elif "${CARRIER_EDITION}"; then
  NGCP_INSTALLER_EDITION_STR="Sipwise C5:        CARRIER"
elif "${PRO_EDITION}"; then
  NGCP_INSTALLER_EDITION_STR="Sipwise C5:        PRO"
elif ! "${NGCP_INSTALLER}"; then
  # installing plain debian without NGCP
  NGCP_INSTALLER_EDITION_STR=""
elif "${PUPPET}" ; then
  NGCP_INSTALLER_EDITION_STR="PUPPET"
else
  echo "Error: Could not determine 'edition' (spce, sppro, carrier)."
  exit 1
fi

DEBIAN_URL="${DEBIAN_REPO_TRANSPORT}://${DEBIAN_REPO_HOST}"
SIPWISE_URL="${SIPWISE_REPO_TRANSPORT}://${SIPWISE_REPO_HOST}"

FALLBACKFS_SIZE="${FALLBACKFS_SIZE:-${ROOTFS_SIZE}}"

## }}}

if [ -n "$NETSCRIPT" ] ; then
  echo "Automatic deployment via bootoption netscript detected."
  INTERACTIVE=false
fi

ensure_packages_installed

# this is important for "buster", do not update the string for "bullseye" or
# future releases
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
  unset NODE_NAME
fi

set_deploy_status "getconfig"

# when using ip=....:$HOSTNAME:eth0:off file /etc/hosts doesn't contain the
# hostname by default, avoid warning/error messages in the host system
# and use it for IP address check in pro edition
if [ -z "$TARGET_HOSTNAME" ] ; then
  if "$PRO_EDITION" ; then
    TARGET_HOSTNAME="${NODE_NAME}"
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
if [[ -n "${IP_LINE}" ]]; then
  declare -A IP_ARR
  if loadNfsIpArray IP_ARR "${IP_LINE}" ; then
    INSTALL_DEV=${IP_ARR[device]}
    EXT_GW=${IP_ARR[gw-ip]}
    [[ "${IP_ARR[autoconf]}" == 'dhcp' ]] && DHCP=true
  fi
fi

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
EXTERNAL_DEV="${INSTALL_DEV}"
EXTERNAL_DEV="n${EXTERNAL_DEV}" # rename eth*->neth*
EXTERNAL_IP="${INSTALL_IP}"
EADDR="${EXTERNAL_IP:-${EADDR}}"
MANAGEMENT_IP="${MANAGEMENT_IP:-${IP_HA_SHARED}}"
INTERNAL_DEV="n${INTERNAL_DEV}" # rename eth*->neth*
ORIGIN_INSTALL_DEV="n${INSTALL_DEV}" # rename eth*->neth*
if [[ -n "${EXT_GW}" ]]; then
  GW="${EXT_GW}"
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
  Use 'eatmydata':   $EATMYDATA

  Installing in chassis? $CHASSIS

" | tee -a /tmp/installer-settings.txt

if "$PRO_EDITION" ; then
  echo "
  Node name:         $NODE_NAME
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
  INSTALLER_TYPE="Install CE: ${CE_EDITION} PRO: ${PRO_EDITION} [${NODE_NAME}] Carrier: ${CARRIER_EDITION} [${NODE_NAME}] [${CROLE}]"
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

127.0.0.1 ${NODE_NAME} ${HOSTNAME}
${INSTALL_IP} ${NODE_NAME} ${HOSTNAME}
EOF
fi

# remote login ftw
service ssh start >/dev/null &
echo "root:sipwise" | chpasswd

# date/time settings, so live system has proper date set
enable_ntp

## partition disk
set_deploy_status "disksetup"

if "$NGCP_INSTALLER" ; then
  VG_NAME="ngcp"
else
  VG_NAME="vg0"
fi

lvm_setup

# otherwise e2fsck fails with "need terminal for interactive repairs"
echo FSCK=no >>/etc/debootstrap/config

echo "Clean the default /etc/debootstrap/packages"
echo > /etc/debootstrap/packages

cat >> /etc/debootstrap/packages << EOF
# we want to have LVM support everywhere
lvm2
EOF

if ! "$NGCP_INSTALLER" ; then

  echo "Install some packages to be able to login on the Debian plain system"
  cat >> /etc/debootstrap/packages << EOF
# to be able to login on the Debian plain system via SSH
openssh-server
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

KEYRING="${SIPWISE_APT_KEY_PATH}"

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

if [[ ! -x "$(which mmdebstrap)" ]]; then
  die "Can't find mmdebstrap"
fi

ADDITIONAL_PACKAGES+=(mmdebstrap)
ensure_packages_installed
export DEBOOTSTRAP=mmdebstrap  # for usage with grml-debootstrap

# install only "Essential:yes" packages plus apt (explicitly included in minbase variant),
# systemd + network related packages
pkg_eatmydata=""
if "${EATMYDATA}"; then
  pkg_eatmydata=",eatmydata"
fi

DEBOPT_OPTIONS=()
pkg_usrmerge=""
case "${DEBIAN_RELEASE}" in
  stretch|buster|bullseye)
    # don't install usrmerge before Debian/bookworm AKA v12; instead invoke with
    # --no-merged-usr, which is a no-op in mmdebstrap (at least until v1.2.1),
    # but force its usage to not be surprised if that default should ever change
    DEBOPT_OPTIONS+=("--no-merged-usr")
    ;;
  *)
    # to use a merged-/usr (expected for Debian/bookworm and newer), we need to
    # tell mmdebstrap to include the usrmerge package
    pkg_usrmerge=",usrmerge"
    ;;
esac

DEBOPT_OPTIONS+=("--variant=minbase --include=systemd,systemd-sysv,init,zstd,isc-dhcp-client,ifupdown,ca-certificates${pkg_eatmydata}${pkg_usrmerge}")
# TT#61152 Add configuration Acquire::Retries=3, for apt to retry downloads
DEBOPT_OPTIONS+=("--aptopt='Acquire::Retries=3'")

if [[ -n "${EFI_PARTITION}" ]] ; then
  if efi_support ; then
    echo "EFI support present, enabling EFI support within grml-debootstrap"
    EFI_OPTION="--efi ${EFI_PARTITION}"

    # ensure we force creation of a proper FAT filesystem
    echo "Creating FAT filesystem on EFI partition ${EFI_PARTITION}"
    mkfs.fat -F32 -n "EFI" "${EFI_PARTITION}"

    # this can be dropped once we have grml-debootstrap >=v0.99 available in our squashfs
    efivars_workaround
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
  $PRE_SCRIPTS_OPTION \
  $POST_SCRIPTS_OPTION \
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

# MT#57643: dpkg >=1.20.0 (as present on Debian/bookworm and newer) no
# longer creates /var/lib/dpkg/available (see #647911). mmdebstrap relies
# on and uses dpkg of the host system. But on Debian releases until and
# including buster, dpkg fails to operate with e.g. `dpkg
# --set-selections`, if /var/lib/dpkg/available doesn't exist, so let's
# ensure /var/lib/dpkg/available exists on Debian releases <=buster.
case "${DEBIAN_RELEASE}" in
  stretch|buster)
    echo "Generating /var/lib/dpkg/available to work around dpkg >=1.20.0 issue for Debian release '${DEBIAN_RELEASE}'"
    chroot "${TARGET}" /usr/lib/dpkg/methods/apt/update /var/lib/dpkg
    ;;
esac

# MT#7805
if "$NGCP_INSTALLER" ; then
  cat << EOT | augtool --root="$TARGET"
insert opt after /files/etc/fstab/*[file="/"]/opt[last()]
set /files/etc/fstab/*[file="/"]/opt[last()] noatime
save
EOT
fi

# TT#41500: Make sure the timezone setup is coherent
grml-chroot "${TARGET}" dpkg-reconfigure --frontend=noninteractive tzdata

# TT#122950 Avoid time consuming "building database of manual pages"
echo 'man-db man-db/auto-update boolean false' | grml-chroot "${TARGET}" debconf-set-selections

# provide usable /ngcp-data partition
if [ -n "${DATA_PARTITION}" ] ; then
  echo "Enabling ngcp-data partition ${DATA_PARTITION} via /etc/fstab"
  cat >> "${TARGET}/etc/fstab" << EOF
${DATA_PARTITION} /ngcp-data               auto           noatime               0  0
EOF

  # Make sure /ngcp-data is mounted inside chroot
  # (some package might need to create folders structure on .postinst)
  grml-chroot "${TARGET}" mount /ngcp-data
fi

# provide usable /ngcp-fallback read-only partition
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
grml-chroot "${TARGET}" apt-get --purge -y autoremove

# purge removed packages
# it's necessary to use chroot instead of grml-chroot in variable=$() calls
# as grml-chroot also prints "Writing /etc/debian_chroot ..." line
# which breaks output
removed_packages=( $(chroot "${TARGET}" dpkg --list | awk '/^rc/ {print $2}') )
if [ ${#removed_packages[@]} -ne 0 ]; then
  grml-chroot "${TARGET}" dpkg --purge "${removed_packages[@]}"
fi

# make sure `hostname` and `hostname --fqdn` return data from chroot
grml-chroot "${TARGET}" hostname -F /etc/hostname

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

if ! "$NGCP_INSTALLER" ; then
  set_custom_grub_boot_options
fi

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

echo -n "Running ngcp-installer via grml-chroot, starting at: "
date +'%F %T %Z'
ngcp_installer_start=$(date +'%s')

ngcp_installer_cmd="ngcp-installer"
if command -v eatmydata &>/dev/null; then
  echo "Running ngcp-installer with 'eatmydata'"
  ngcp_installer_cmd="eatmydata ${ngcp_installer_cmd}"
else
  echo "Running ngcp-installer without 'eatmydata'"
fi
${ngcp_installer_cmd} 2>&1
RC=$?

echo -n "Finishing ngcp-installer at: "
date +'%F %T %Z'
ngcp_installer_end=$(date +'%s')

echo "ngcp-installer total run: $((ngcp_installer_end - ngcp_installer_start)) seconds"

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

    echo "Trying to identify ping_host"
    get_ping_host

    # Check the current method of external interface
    # If it is manual - we need to reconfigure /e/n/i to get working network configuration after the reboot
    method=$( sed -rn "s/^iface ${INSTALL_DEV} inet ([A-Za-z]+)/\1/p" < /etc/network/interfaces )
    netcardconf="/usr/sbin/netcardconfig"
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
    # renaming eth*->neth* done below, to also do it for non-ngcp installations
    unset method netcardconf
  else
    die "Error during installation of ngcp. Find details at: ${TARGET}/var/log/ngcp-installer.log"
  fi

  echo "Checking for network connectivity (workaround for e.g. ice network drive issue)"
  wait_for_network_online 15

  echo "Generating udev persistent net rules ..."
  grml-chroot "${TARGET}" /usr/sbin/ngcp-initialize-udev-rules-net

  echo "Temporary files cleanup ..."
  find "${TARGET}/var/log" -type f -size +0 -not -name \*.ini -not -name ngcp-installer.log -exec sh -c ":> \${1}" sh {} \;
  :>$TARGET/run/utmp
  :>$TARGET/run/wtmp

  echo "Backup grml-debootstrap.log for later investigation ..."
  if [ -r /tmp/grml-debootstrap.log ] ; then
    cp /tmp/grml-debootstrap.log "${TARGET}"/var/log/
  fi

  # network interfaces need to be renamed eth*->neth* with mr9.5 / Debian
  # bullseye, and not left with grml-bootstrap defaults
  echo "Renaming eth*->neth* in /etc/network/interfaces ..."
  sed -i '/eth[0-9]/ s|eth|neth|g' "${TARGET}/etc/network/interfaces"
  echo "Content of resulting /etc/network/interfaces:"
  tail -v -n +0 "${TARGET}/etc/network/interfaces"
  echo "========"
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

if "$VAGRANT" ; then
  echo "Bootoption vagrant present, executing vagrant_configuration."
  vagrant_configuration
fi

if [ -n "$PUPPET" ] ; then
  set_deploy_status "puppet"

  echo "Setting hostname to ${IP_ARR[hostname]}"
  echo "${IP_ARR[hostname]}" > "${TARGET}/etc/hostname"
  grml-chroot "${TARGET}" hostname -F /etc/hostname

  grml-chroot "${TARGET}" apt-get -y install resolvconf libnss-myhostname

  if [ ! -x "${TARGET}/usr/bin/dirmngr" ] ; then
    echo  "Installing dirmngr on Debian ${DEBIAN_RELEASE}, otherwise the first puppet run fails: 'Could not find a suitable provider for apt_key'"
    grml-chroot "${TARGET}" apt-get -y install dirmngr
  fi

  # puppetlabs doesn't provide packages for Debian/bookworm yet, so use
  # the AIO packages from the bullseye repos for now,
  puppet_deb_release="${DEBIAN_RELEASE}"
  case "${DEBIAN_RELEASE}" in
    bookworm)
      puppet_deb_release="bullseye"
      echo "WARN: enabling ${puppet_deb_release} puppetlabs repository for ${DEBIAN_RELEASE} (see PA-4995)"
      ;;
  esac

  echo "Installing 'puppet-agent' with dependencies"
  cat >> ${TARGET}/etc/apt/sources.list.d/puppetlabs.list << EOF
deb ${DEBIAN_URL}/puppetlabs/ ${puppet_deb_release} main puppet dependencies
EOF

  puppet_gpg='/root/puppet.gpg'
  if [[ ! -f "${puppet_gpg}" ]]; then
    die "Can't find ${puppet_gpg} file"
  fi
  cp "${puppet_gpg}" "${TARGET}/etc/apt/trusted.gpg.d/"

  grml-chroot "${TARGET}" apt-get update
  grml-chroot "${TARGET}" apt-get -y install puppet-agent openssh-server lsb-release ntpdate

  # Fix Facter error while running in chroot, facter fails if /etc/mtab is absent:
  grml-chroot "${TARGET}" ln -s /proc/self/mounts /etc/mtab || true

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


if [[ "${SWRAID}" = "true" ]] ; then
  if efi_support ; then
    set_deploy_status "swraidinstallefigrub"
    grml-chroot "${TARGET}" mount /boot/efi

    # if efivarfs kernel module is loaded, but efivars isn't,
    # then we need to mount efivarfs for efibootmgr usage
    if ! ls /sys/firmware/efi/efivars/* &>/dev/null ; then
      echo "Mounting efivarfs on /sys/firmware/efi/efivars"
      grml-chroot "${TARGET}" mount -t efivarfs efivarfs /sys/firmware/efi/efivars
    fi

    if efibootmgr | grep -q 'NGCP Fallback' ; then
      echo "Deleting existing NGCP Fallback entry from EFI boot manager"
      efi_entry=$(efibootmgr | awk '/ NGCP Fallback$/ {print $1; exit}' | sed 's/^Boot//; s/\*$//')
      efibootmgr -b "$efi_entry" -B
    fi

    echo "Adding NGCP Fallback entry to EFI boot manager"
    efibootmgr --create --disk "/dev/${SWRAID_DISK2}" -p 2 -w --label 'NGCP Fallback' --load '\EFI\debian\grubx64.efi'
  fi

  set_deploy_status "swraidinstallgrub"
  for disk in "${SWRAID_DISK1}" "${SWRAID_DISK2}" ; do
    grml-chroot "${TARGET}" grub-install "/dev/$disk"
  done

  grml-chroot "${TARGET}" update-grub
fi

if [ -r "${INSTALL_LOG}" ] && [ -d "${TARGET}"/var/log/ ] ; then
  set_deploy_status "copylogfiles"
  cp "${INSTALL_LOG}" "${TARGET}"/var/log/
  sync
fi

# unmount /ngcp-data partition inside chroot (if available)
if [ -n "${DATA_PARTITION}" ] ; then
  grml-chroot "${TARGET}" umount /ngcp-data
fi

# don't leave any mountpoints
sync

umount ${TARGET}/sys/firmware/efi/efivars || true
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

declare efidev1 efidev2
if [[ "${SWRAID}" = "true" ]] ; then
  if efi_support ; then
    set_deploy_status "swraidclonegrub"
    partlabel="EFI System"
    max_tries=60
    get_pvdevice_by_label_with_retries "/dev/${SWRAID_DISK1}" "${partlabel}" "${max_tries}" efidev1
    get_pvdevice_by_label_with_retries "/dev/${SWRAID_DISK2}" "${partlabel}" "${max_tries}" efidev2

    echo "Cloning EFI partition from ${efidev1} to ${efidev2}"
    dd if="${efidev1}" of="${efidev2}" bs=10M
  fi

  echo "Ensuring ${SWRAID_DEVICE} is stopped"
  mdadm --stop "${SWRAID_DEVICE}" || true
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

if "$INTERACTIVE" ; then
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
fi

## END OF FILE #################################################################1
