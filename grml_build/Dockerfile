# DOCKER_NAME=grml-build-bookworm
FROM docker.mgm.sipwise.com/sipwise-bookworm:latest

# Important! Update this no-op ENV variable when this Dockerfile
# is updated with the current date. It will force refresh of all
# of the base images and things like `apt-get update` won't be using
# old cached versions when the Dockerfile is built.
ENV REFRESHED_AT 2023-02-03

# tools for building and testing
RUN apt-get update && apt-get install --assume-yes --no-install-recommends \
  bc \
  bzip2 \
  dosfstools \
  fai-client \
  fai-server \
  git \
  grml2usb \
  imagemagick \
  isolinux \
  isomd5sum \
  jo \
  kmod \
  memtest86+ \
  mksh \
  moreutils \
  mtools \
  pciutils \
  procps \
  qemu-system-x86 \
  rsync \
  socat \
  squashfs-tools \
  sudo \
  syslinux \
  wget \
  xorriso

RUN echo "SECURE_BOOT=disable ./grml-live -s bookworm -a amd64 -c GRMLBASE,SIPWISE,AMD64 -t /code/grml-live/templates/ -o /grml/ -r grml-sipwise -v 0.42" >/root/.bash_history && \
  echo "export LIVE_CONF=/code/grml-live/etc/grml/grml-live.conf" >>/root/.bash_history && \
  echo "export SCRIPTS_DIRECTORY=/code/grml-live/scripts"         >>/root/.bash_history && \
  echo "export GRML_FAI_CONFIG=/code/grml-live/etc/grml/fai"      >>/root/.bash_history && \
  echo "cp /deployment-iso/grml_build/package_config/SIPWISE /code/grml-live/etc/grml/fai/config/package_config/SIPWISE" >>/root/.bash_history

# base build tools
WORKDIR /code/
RUN git clone -b 'v0.43.0' --single-branch --depth 1 https://github.com/grml/grml-live
RUN mkdir -p /code/grml-live/templates/boot/addons/ \
  /code/grml-live/etc/grml/fai/config/files/etc/apt/sources.list.d/sipwise.list/ \
  /code/grml-live/etc/grml/fai/config/files/etc/apt/trusted.gpg.d/sipwise-keyring.gpg/ \
  /code/grml-live/etc/grml/fai/config/files/etc/apt/trusted.gpg.d/sipwise-keyring-bootstrap.gpg/ \
  /code/grml-live/etc/grml/fai/config/files/root/puppet.gpg/ \
  /code/grml-live/etc/grml/fai/config/scripts/PUPPETLABS/

# addons
RUN wget https://debian.sipwise.com/debian/pool/main/m/memtest86+/memtest86+_6.00-1_amd64.deb && \
  dpkg -x memtest86+_6.00-1_amd64.deb /tmp/memtest86 && \
  cp /tmp/memtest86/boot/memtest86+x64.bin /code/grml-live/templates/boot/addons/memtest86+x64.bin && \
  cp /tmp/memtest86/boot/memtest86+x64.efi /code/grml-live/templates/boot/addons/memtest86+x64.efi && \
  rm -rf /tmp/memtest86

RUN wget -O /code/grml-live/templates/boot/addons/netboot.xyz.efi https://boot.netboot.xyz/ipxe/netboot.xyz.efi && \
  wget -O /code/grml-live/templates/boot/addons/netboot.xyz.lkrn https://boot.netboot.xyz/ipxe/netboot.xyz.lkrn

RUN wget http://ftp.de.debian.org/debian/pool/main/i/ipxe/ipxe_1.0.0+git-20190125.36a4c85-1_all.deb && \
  dpkg -x ipxe_1.0.0+git-20190125.36a4c85-1_all.deb /tmp/ipxe && \
  cp /tmp/ipxe/boot/ipxe.efi /code/grml-live/templates/boot/addons/ipxe.efi && \
  cp /tmp/ipxe/boot/ipxe.lkrn /code/grml-live/templates/boot/addons/ipxe.lkrn && \
  rm -rf /tmp/ipxe

WORKDIR /code/grml-live

### Usage instructions #############################################################################
## Build docker image:
#
# docker build --tag="grml-sipwise" -f grml_build/Dockerfile .
#
## Build Grml image (assuming current working directory is deployment-iso.git):
#
# mkdir -p grml/
# docker run --rm -i -t --privileged -v $(pwd):/deployment-iso/ -v $(pwd)/grml:/grml/ grml-sipwise
#
## inside docker container (also available in shell history):
#
# export GRML_FAI_CONFIG=$(pwd)/etc/grml/fai
# export SCRIPTS_DIRECTORY=$(pwd)/scripts
# export LIVE_CONF=$(pwd)/etc/grml/grml-live.conf
# cp /deployment-iso/grml_build/package_config/SIPWISE /code/grml-live/etc/grml/fai/config/package_config/SIPWISE
# ./grml-live -s bookworm -a amd64 -c GRMLBASE,SIPWISE,AMD64 -t $(pwd)/templates/ -o /grml/ -r grml-sipwise -v 0.42
#
## A successful run results in ISO file in /grml/grml_isos/ (inside container),
## available via volume folder also outside of docker container ($pwd/grml/grml_isos/).
#
####################################################################################################
