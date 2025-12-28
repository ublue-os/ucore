#!/bin/sh

set -ouex pipefail

# install packages.json stuffs
export IMAGE_NAME=ucore-hci
dnf -y install \
    cockpit-machines \
    libvirt-client \
    libvirt-daemon-kvm \
    ublue-os-libvirt-workarounds \
    virt-install

# tweak os-release
sed -i '/^PRETTY_NAME/s/(uCore.*$/(uCore HCI)"/' /usr/lib/os-release
