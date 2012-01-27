Instructions how to build the Grml-Sipwise Deployment ISO
=========================================================

Make sure you have grml2usb >=0.11.6 installed (providing grml2iso).
Grab a 64bit Grml ISO (like grml64_2011.12.iso) from http://grml.org/download/

Execute:

  % sudo grml2iso -c ngcp/deployment/trunk/grml-live/templates -o grml-sipwise_$(date +%Y.%m.%d).iso grml64_2011.12.iso

This will generate grml-sipwise_...iso, providing the custom bootsplash
with Sipwise specific boot menu entries.
