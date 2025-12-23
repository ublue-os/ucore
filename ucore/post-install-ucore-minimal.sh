#!/bin/sh

set -ouex pipefail

## ALWAYS: regular post-install
systemctl mask coreos-container-signing-migration-motd.service
systemctl mask coreos-oci-migration-motd.service
systemctl disable docker.socket
systemctl disable tuned.service
systemctl disable zincati.service

systemctl enable gssproxy-workaround.service
systemctl enable swtpm-workaround.service


systemctl enable ucore-paths-provision.service
systemctl enable rpm-ostreed-automatic.timer

sed -i 's/#AutomaticUpdatePolicy.*/AutomaticUpdatePolicy=stage/' /etc/rpm-ostreed.conf

# workaround until distrobox patch for this makes it into repos
ln -s  ../usr/share/zoneinfo/UTC /etc/localtime

# switch to server profile to allow cockpit by default
cp -a /etc/firewalld/firewalld-server.conf /etc/firewalld/firewalld.conf