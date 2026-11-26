#!/bin/sh

set -ouex pipefail

# Apply systemd presets to all units
systemctl preset-all

# Mask unnecessary CoreOS migration MOTD services
systemctl mask coreos-container-signing-migration-motd.service
systemctl mask coreos-oci-migration-motd.service

# Enable automatic updates via rpm-ostree
sed -i 's/#AutomaticUpdatePolicy.*/AutomaticUpdatePolicy=stage/' /etc/rpm-ostreed.conf

# workaround until distrobox patch for this makes it into repos
ln -s  ../usr/share/zoneinfo/UTC /etc/localtime

# switch to server profile to allow cockpit by default
cp -a /etc/firewalld/firewalld-server.conf /etc/firewalld/firewalld.conf
