#!/bin/sh

set -ouex pipefail

# install packages
dnf -y --enable-repo='copr:copr.fedorainfracloud.org:ublue-os:packages' install ublue-os-libvirt-workarounds
dnf -y install \
    cockpit-machines \
    libvirt-client \
    libvirt-daemon-kvm \
    virt-install

# tweak os-release
sed -i '/^PRETTY_NAME/s/(uCore.*$/(uCore HCI)"/' /usr/lib/os-release
