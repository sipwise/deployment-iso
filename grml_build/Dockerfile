# DOCKER_NAME=grml-build-trixie
FROM docker.mgm.sipwise.com/sipwise-trixie:latest
#FROM --platform=linux/amd64 debian:trixie-slim

# Important! Update this no-op ENV variable when this Dockerfile
# is updated with the current date. It will force refresh of all
# of the base images and things like `apt-get update` won't be using
# old cached versions when the Dockerfile is built.
ENV REFRESHED_AT=2026-01-30

# tools for building and testing
RUN apt-get update && apt-get install --assume-yes --no-install-recommends \
  bc \
  bzip2 \
  ca-certificates \
  dosfstools \
  git \
  grml2usb \
  imagemagick \
  isomd5sum \
  jo \
  kmod \
  mmdebstrap \
  moreutils \
  mtools \
  pciutils \
  procps \
  qemu-system-x86 \
  rsync \
  socat \
  squashfs-tools \
  sudo \
  wget \
  xorriso

# base build tools
WORKDIR /code/

RUN git clone -b 'v0.55.1' --single-branch --depth 1 https://github.com/grml/grml-live

WORKDIR /code/grml-live

### Usage instructions #############################################################################
## Build docker image:
#
# docker build --tag="grml-sipwise" -f grml_build/Dockerfile .
#
## Build Grml image:
#
# osversion=auto release=trunk ./wrapper.sh
#
## A successful run results in an ISO file in grml_build/grml_isos/
####################################################################################################
