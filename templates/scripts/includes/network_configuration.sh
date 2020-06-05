#!/bin/bash

set -e

while ! "${working_dir}/check-for-network" ; do
  /usr/sbin/netcardconfig
done
