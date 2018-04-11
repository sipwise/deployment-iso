#!/bin/bash

set -e

apt-get update 1>/dev/null
apt-get install --assume-yes \
  isomd5sum
