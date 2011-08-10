How to build the local mirror
-----------------------------

apt-get clean
apt-get -y --print-uris --reinstall --download-only install $(dpkg --get-selections | awk '{print $1}') | grep "^\'" | cut -d\' -f2 > install.txt
wget -c --input-file install.txt

Place downloaded .deb files in /srv/mirror/debs/ inside
the ISO, then execute ./make_reprepro.sh inside /srv/mirror.

./make_reprepro.sh looks like:

  echo "Setting up configuration for reprepro."
  mkdir -p debian/conf/
  cat > debian/conf/distributions << EOF
  Origin: Debian
  Label: Debian
  Suite: stable
  Version: 6.0
  Codename: squeeze
  Architectures: amd64 source
  Components: main contrib non-free
  Description: Debian Mirror including Sipwise stuff
  Log: logfile
  EOF
  
  echo "Building local Debian mirror based on packages found in debs."
  for f in debs/*deb ; do
    reprepro --silent -b debian includedeb squeeze "$f"
  done

You can remove the debs from /srv/mirror/debs/ then to
save space on the resulting ISO.
