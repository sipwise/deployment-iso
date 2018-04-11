#!/bin/bash

set -e

echo "Updating list of packages..."
apt-get update 1>/dev/null
echo "Installing required packages..."
apt-get install --assume-yes \
  isomd5sum
