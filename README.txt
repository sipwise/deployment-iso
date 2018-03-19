Instructions how to build the Grml-Sipwise Deployment ISO
=========================================================

Make sure you have grml2usb >=0.11.6 installed (providing grml2iso).

Execute:

  % make all

  % ./build_iso.sh <pubic|private> <grml.iso> <mr version> <Debian dist>

This will generate ISO file, providing the custom bootsplash
with Sipwise specific boot menu entries.
