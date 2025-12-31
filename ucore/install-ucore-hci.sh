#!/bin/sh

set -ouex pipefail

# install packages
dnf -y install \
    cockpit-machines \
    libvirt-client \
    libvirt-daemon-kvm \
    ublue-os-libvirt-workarounds \
    virt-install

# tweak os-release
sed -i '/^PRETTY_NAME/s/(uCore.*$/(uCore HCI)"/' /usr/lib/os-release
