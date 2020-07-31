#!/bin/bash

set -e

working_dir="$(dirname "$0")"

while ! "${working_dir}/check-for-network" ; do
  /usr/sbin/netcardconfig
done
