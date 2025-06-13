Instructions how to build the Grml-Sipwise Deployment ISO
=========================================================

Make sure you have grml2usb >=0.11.6 installed (providing grml2iso).

Execute:

  % make all

  % ./build_iso.sh compat <grml.iso> <mr version> <Debian dist>

This will generate ISO file, providing the custom bootsplash
with Sipwise specific boot menu entries.

To generate the underlying base ISO, you can use the wrapper script:

  % osversion=auto release=trunk ./wrapper.sh

To not use release-trunk, use something like:

  % osversion=auto release=mr13.3.1 ./wrapper.sh
