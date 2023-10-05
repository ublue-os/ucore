#!/bin/sh

set -ouex pipefail

RELEASE="$(rpm -E %fedora)"

#### PREPARE
# enable testing repos if not enabled on testing stream
if [[ "testing" == "${COREOS_VERSION}" ]]; then
for REPO in $(ls /etc/yum.repos.d/fedora-updates-testing{,-modular}.repo); do
  if [[ "$(grep enabled=1 ${REPO} > /dev/null; echo $?)" == "1" ]]; then
    echo "enabling $REPO" &&
    sed -i '0,/enabled=0/{s/enabled=0/enabled=1/}' ${REPO}
  fi
done
fi

# always disable cisco-open264 repo
sed -i 's@enabled=1@enabled=0@g' /etc/yum.repos.d/fedora-cisco-openh264.repo

#### INSTALL
# inspect to see what RPMS we copied in
find /tmp/rpms/

## CONDITIONAL: install ZFS (and sanoid deps)
if [[ "-zfs" == "${ZFS_TAG}" ]]; then
    rpm-ostree install /tmp/rpms/zfs/*.rpm \
      lzop \
      mbuffer \
      mhash \
      perl-Capture-Tiny \
      perl-Config-IniFiles \
      perl-Getopt-Long \
      pv
fi

## ALWAYS: install regular packages

# add tailscale repo
curl -L https://pkgs.tailscale.com/stable/fedora/tailscale.repo -o /etc/yum.repos.d/tailscale.repo

# install packages.json stuffs
/tmp/packages.sh
