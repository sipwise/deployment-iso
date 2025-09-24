#!/bin/bash

set -eu -o pipefail

# sanity checks
if [ -z "${osversion:-}" ];  then
  echo "Error: osversion is unset, please set to supported Debian/release (like 'trixie' or 'auto')" >&2
  exit 1
fi

if [ -z "${release:-}" ];  then
  echo "Error: release is unset, please set to supported Sipwise release (like 'mr13.5.1' or 'trunk')" >&2
  exit 1
fi

if ! [ -d grml_build ] ; then
  echo "Error: grml_build doesn't exist, executing outside deployment-iso directory?" >&2
  exit 1
fi

# ensure that we're running it manually inside deployment-iso,
# or we're running it from within Jenkins
if [ "$(basename "$(pwd)")" = "deployment-iso" ] ; then
  echo "*** Looks we're running locally inside deployment-iso directory ***"
elif [ -n "${WORKSPACE:-}" ] && [ "$(basename "$(pwd)")" = "source" ] ; then
  echo "*** Looks we're running inside Jenkins ***"
else
  echo "Error: you need to run this inside the deployment-iso directory or from within Jenkins" >&2
  exit 1
fi

# derive Debian release from grml_build/Dockerfile if osversion is set to "auto"
if [[ "${osversion}" == 'auto' ]]; then
  osversion="$( sed -rn 's|^FROM docker.mgm.sipwise.com/sipwise-([A-Za-z0-9]+):.+$|\1|p' grml_build/Dockerfile )"
fi

if [ -z "${WORKSPACE:-}" ] ; then
  docker_image="grml-sipwise"
  echo "*** Assuming local build with docker image '${docker_image}' ***"
else
  echo "*** Looks like we are running inside Jenkins environment ***"
  docker_repo=${docker_repo:-docker.mgm.sipwise.com}
  docker_repo_port=${docker_repo_port:-5000}
  docker_name="grml-build-${osversion}"
  docker_tag="${dockertag:-latest}"  # support custom build param via grml-build-iso Jenkins job
  docker_image="${docker_repo}:${docker_repo_port}/${docker_name}:${docker_tag}"
  echo "*** Pulling ${docker_image} docker image ***"
  docker pull "${docker_image}"
fi

if [ -z "${osversion:-}" ]; then
  echo "Can not detect osversion, exiting" >&2
  exit 1
fi

declare build_time
build_time="$(date +%Y%m%d_%H%M%S)"

# misc variables
fai_config='/code/grml-live/config/'
outside_fai_config="${PWD}/grml_build/config/"
debian_bootstrap_url="https://debian.sipwise.com/debian/"
iso_image_name="grml-sipwise-${osversion}-${build_time}.iso"
if [[ -n "${repo_date:-}" ]]; then
  iso_image_name="grml-sipwise-${osversion}-${repo_date}_${build_time}.iso"
fi

# write apt sources
source_list_path='etc/apt/sources.list.d/sipwise.list'
repo_addr="deb https://deb.sipwise.com/autobuild release-trunk-${osversion} main"
if [[ "${release}" != 'trunk' ]]; then
  repo_addr="deb https://deb.sipwise.com/spce/${release} ${osversion} main"
fi
echo "${repo_addr}" > "${outside_fai_config}files/SIPWISE/${source_list_path}"

# get the puppet public key, so no need to download it in deployment.sh
puppet_key='puppet.gpg'
wget -O "${outside_fai_config}/files/PUPPETLABS/root/${puppet_key}" https://deb.sipwise.com/files/puppetlabs-pubkey-2025.gpg

use_wayback="false"
if [[ -n "${repo_date:-}" ]]; then
  use_wayback="true"
  echo "enabling wayback option, as repo_date parameter is set to '${repo_date}'"
fi

build_command=''
build_command+=" cp -rv /grml/config/ /code/grml-live/"
build_command+=" && ulimit -n 1048576"  # workaround to fix apt/apt-mark performance issue
build_command+=" && GRML_NAME=grml64-small"
build_command+=" CHROOT_OUTPUT=/root/grml_chroot"
build_command+=" BOOTSTRAP_MIRROR='${debian_bootstrap_url}'"
build_command+=" LIVE_CONF=/code/grml-live/etc/grml/grml-live.conf"
build_command+=" GRML_FAI_CONFIG=${fai_config}"
build_command+=" ./grml-live"
build_command+=" -s '${osversion}'"
build_command+=" -a amd64"
build_command+=" -i '${iso_image_name}'"
build_command+=" -c SIPWISE,PUPPETLABS"
build_command+=" -o /grml/"
build_command+=" -r 'grml-sipwise-${osversion}'"
build_command+=" -v '${release}'"
build_command+=" -R"
build_command+=" -F"
if "${use_wayback}"; then
  build_command+=" -w '${repo_date}'"
fi
build_command+=" && cd /grml/grml_isos/"
build_command+=" && sha1sum '${iso_image_name}' > '${iso_image_name}.sha1'"
build_command+=" && md5sum  '${iso_image_name}' > '${iso_image_name}.md5'"

echo "System information:"
uname -a
lsb_release -a
docker --version
dpkg -l | grep docker

echo "Build command is:"
echo "${build_command}"

docker run --rm \
  -v "$(pwd)":/deployment-iso/ \
  -v "$(pwd)/grml_build/":/grml/ \
  "${docker_image}" \
  /bin/bash -c "${build_command}"
