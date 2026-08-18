#!/bin/sh

set -ouex pipefail

# Enable the vendored libvirt relabel workaround without its corrupting COPR RPM.
systemctl preset ublue-os-libvirt-workarounds.service

# install packages
dnf -y install \
    cockpit-machines \
    libvirt-client \
    libvirt-daemon-kvm \
    virt-install

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
