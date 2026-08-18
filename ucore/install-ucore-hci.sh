#!/bin/sh

set -ouex pipefail

# Verify the parent image before the HCI package transaction.
rpmdb --verifydb

# Keep the libvirt workaround and HCI packages in one RPM database transaction.
dnf -y --enable-repo='copr:copr.fedorainfracloud.org:ublue-os:packages' download \
    --arch noarch \
    --destdir /tmp \
    ublue-os-libvirt-workarounds
dnf -y install \
    /tmp/ublue-os-libvirt-workarounds-*.noarch.rpm \
    cockpit-machines \
    libvirt-client \
    libvirt-daemon-kvm \
    virt-install

rpmdb --verifydb
rpm -q ublue-os-libvirt-workarounds
systemctl is-enabled ublue-os-libvirt-workarounds.service
rm -f /tmp/ublue-os-libvirt-workarounds-*.rpm

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
