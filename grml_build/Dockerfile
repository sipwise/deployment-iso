# DOCKER_NAME=grml-build-buster
FROM docker.mgm.sipwise.com/sipwise-buster:latest

# Important! Update this no-op ENV variable when this Dockerfile
# is updated with the current date. It will force refresh of all
# of the base images and things like `apt-get update` won't be using
# old cached versions when the Dockerfile is built.
ENV REFRESHED_AT 2019-10-30

# tools for building
RUN apt-get update && apt-get install --assume-yes \
  bc \
  bzip2 \
  dosfstools \
  fai-client \
  fai-server \
  git \
  grml2usb \
  isolinux \
  isomd5sum \
  kmod \
  memtest86+ \
  mksh \
  moreutils \
  mtools \
  pciutils \
  rsync \
  squashfs-tools \
  sudo \
  syslinux \
  wget \
  xorriso

# tools for testing
RUN apt-get install --assume-yes --no-install-recommends \
  imagemagick \
  qemu-system-x86 \
  socat

RUN echo "SECURE_BOOT=disable ./grml-live -s buster -a amd64 -c GRMLBASE,SIPWISE,AMD64 -t /code/grml-live/templates/ -o /grml/ -r grml-sipwise -v 0.42" >/root/.bash_history
RUN echo "export LIVE_CONF=/code/grml-live/etc/grml/grml-live.conf" >>/root/.bash_history
RUN echo "export SCRIPTS_DIRECTORY=/code/grml-live/scripts"         >>/root/.bash_history
RUN echo "export GRML_FAI_CONFIG=/code/grml-live/etc/grml/fai"      >>/root/.bash_history
RUN echo "cp /deployment-iso/grml_build/package_config/SIPWISE /code/grml-live/etc/grml/fai/config/package_config/SIPWISE" >>/root/.bash_history

WORKDIR /code/

# base build tools
RUN git clone -b 'v0.34.3' --single-branch --depth 1 https://github.com/grml/grml-live
RUN mkdir -p /code/grml-live/templates/boot/addons/

# addons
RUN wget https://debian.sipwise.com/debian/pool/main/m/memtest86+/memtest86+_5.01-3_amd64.deb && \
  dpkg -x memtest86+_5.01-3_amd64.deb /tmp/memtest86 && \
  cp /tmp/memtest86/boot/memtest86+.bin /code/grml-live/templates/boot/addons/memtest && \
  rm -rf /tmp/memtest86

RUN wget -O /code/grml-live/templates/boot/addons/netboot.xyz.efi  https://boot.netboot.xyz/ipxe/netboot.xyz.efi
RUN wget -O /code/grml-live/templates/boot/addons/netboot.xyz.lkrn https://boot.netboot.xyz/ipxe/netboot.xyz.lkrn

RUN wget http://ftp.de.debian.org/debian/pool/main/i/ipxe/ipxe_1.0.0+git-20190125.36a4c85-1_all.deb && \
  dpkg -x ipxe_1.0.0+git-20190125.36a4c85-1_all.deb /tmp/ipxe && \
  cp /tmp/ipxe/boot/ipxe.efi /code/grml-live/templates/boot/addons/ipxe.efi && \
  cp /tmp/ipxe/boot/ipxe.lkrn /code/grml-live/templates/boot/addons/ipxe.lkrn && \
  rm -rf /tmp/ipxe

WORKDIR /code/grml-live

RUN mkdir -p /code/grml-live/etc/grml/fai/config/files/etc/apt/sources.list.d/sipwise.list/ \
  /code/grml-live/etc/grml/fai/config/files/etc/apt/trusted.gpg.d/sipwise-keyring.gpg/ \
  /code/grml-live/etc/grml/fai/config/files/etc/apt/trusted.gpg.d/sipwise-keyring-bootstrap.gpg/ \
  /code/grml-live/etc/grml/fai/config/files/root/puppet.gpg/ \
  /code/grml-live/etc/grml/fai/config/scripts/PUPPETLABS/

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
# ./grml-live -s buster -a amd64 -c GRMLBASE,SIPWISE,AMD64 -t $(pwd)/templates/ -o /grml/ -r grml-sipwise -v 0.42
#
## A successfull run results in ISO file in /grml/grml_isos/ (inside container),
## available via volume folder also outside of docker container ($pwd/grml/grml_isos/).
#
####################################################################################################
