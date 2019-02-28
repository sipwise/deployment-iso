# DOCKER_NAME=grml-build-stretch
FROM docker.mgm.sipwise.com/sipwise-stretch:latest

# Important! Update this no-op ENV variable when this Dockerfile
# is updated with the current date. It will force refresh of all
# of the base images and things like `apt-get update` won't be using
# old cached versions when the Dockerfile is built.
ENV REFRESHED_AT 2019-02-28

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
  xorriso

RUN echo "SECURE_BOOT=disable ./grml-live -s buster -a amd64 -c GRMLBASE,SIPWISE,AMD64 -t /code/grml-live/templates/ -o /grml/ -r grml-sipwise -v 0.42" >/root/.bash_history
RUN echo "export LIVE_CONF=/code/grml-live/etc/grml/grml-live.conf" >>/root/.bash_history
RUN echo "export SCRIPTS_DIRECTORY=/code/grml-live/scripts"         >>/root/.bash_history
RUN echo "export GRML_FAI_CONFIG=/code/grml-live/etc/grml/fai"      >>/root/.bash_history
RUN echo "cp /deployment-iso/grml_build/package_config/SIPWISE /code/grml-live/etc/grml/fai/config/package_config/SIPWISE" >>/root/.bash_history

WORKDIR /code/
RUN git clone https://github.com/grml/grml-live

WORKDIR /code/grml-live

RUN mkdir -p /code/grml-live/etc/grml/fai/config/files/etc/apt/sources.list.d/sipwise.list/ \
  /code/grml-live/etc/grml/fai/config/files/etc/apt/trusted.gpg.d/sipwise-keyring.gpg/

### Usage instructions #############################################################################
## Build docker image:
#
# docker build --tag="grml-sipwise" -f grml_build/Dockerfile
#
## Build GRML image:
#
# mkdir -p grml/
# docker run --rm -i -t --privileged -v deployment-iso.git:/deployment-iso/ -v $(pwd)/grml:/grml/ grml-sipwise
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
### Usage instructions #############################################################################
