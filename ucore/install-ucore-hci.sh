#!/bin/sh

set -ouex pipefail

# Verify the parent image before isolating the HCI package transaction.
rpmdb --verifydb

# The payload from ublue-os/packages@f242674 avoids its RPM transaction.
systemd-sysusers /usr/lib/sysusers.d/ublue-os-libvirt-workarounds.conf
getent group libvirt
getent passwd libvirtdbus
systemctl preset ublue-os-libvirt-workarounds.service
systemctl is-enabled ublue-os-libvirt-workarounds.service

# install packages
dnf -y install \
    cockpit-machines \
    libvirt-client \
    libvirt-daemon-kvm \
    virt-install

rpmdb --verifydb

# swtpm-selinux ignores failed semodule transactions during overlay-backed
# image builds. Install its modules explicitly in the image policy store.
test -f /usr/share/selinux/packages/swtpm.pp
test -f /usr/share/selinux/packages/swtpm_svirt.pp
test -f /usr/share/selinux/packages/swtpm_libvirt.pp
cp -a /etc/selinux/targeted /etc/selinux/targeted.rebuilt
rm -rf /etc/selinux/targeted
mv /etc/selinux/targeted.rebuilt /etc/selinux/targeted
semodule --verbose --noreload --priority 200 --install \
    /usr/share/selinux/packages/swtpm.pp \
    /usr/share/selinux/packages/swtpm_svirt.pp \
    /usr/share/selinux/packages/swtpm_libvirt.pp

# tweak os-release
sed -i '/^PRETTY_NAME/s/(uCore.*$/(uCore HCI)"/' /usr/lib/os-release
