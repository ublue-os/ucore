#!/bin/sh

set -ouex pipefail

# install packages
dnf -y install nfs-utils nfs-client-utils --allowerasing
dnf -y install \
    NetworkManager-wifi \
    atheros-firmware \
    brcmfmac-firmware \
    cockpit-storaged \
    distrobox \
    duperemove \
    hdparm \
    iwlegacy-firmware \
    iwlwifi-dvm-firmware \
    iwlwifi-mvm-firmware \
    lm_sensors \
    man-db \
    mt7xxx-firmware \
    nxpwireless-firmware \
    pciutils \
    pcp-zeroconf \
    rclone \
    realtek-firmware \
    samba \
    samba-usershares \
    smartctl \
    snapraid \
    tiwilink-firmware \
    usbutils \
    xdg-dbus-proxy \
    xdg-user-dirs

# sanoid currently comes from ublue-os staging COPR
dnf -y --enable-repo='copr:copr.fedorainfracloud.org:ublue-os:staging' install sanoid

# install packages direct from github
MERGERFS_RPM="$(/ctx/github-pkgs.sh download mergerfs)"
dnf -y install "${MERGERFS_RPM}"

# cockpit plugin for ZFS management
CZM_TGZ="$(/ctx/github-pkgs.sh download cockpit-zfs-manager)"

mkdir -p /tmp/cockpit-zfs-manager
tar -xf "${CZM_TGZ}" -C /tmp/cockpit-zfs-manager --strip-components=1
mv /tmp/cockpit-zfs-manager/polkit-1/actions/* /usr/share/polkit-1/actions/
mv /tmp/cockpit-zfs-manager/polkit-1/rules.d/* /usr/share/polkit-1/rules.d/
mv /tmp/cockpit-zfs-manager/zfs /usr/share/cockpit

FONT_FIX_SCRIPT="$(/ctx/github-pkgs.sh download cockpit-font-fix)"
chmod +x "${FONT_FIX_SCRIPT}"
"${FONT_FIX_SCRIPT}"

rm -rf /tmp/cockpit-zfs-manager
rm -f "${MERGERFS_RPM}" "${CZM_TGZ}" "${FONT_FIX_SCRIPT}"

# pcp-selinux's %post ignores failed semodule transactions during overlay-backed
# image builds. Install its modules explicitly in the image policy store.
test -f /usr/share/selinux/packages/targeted/pcp.pp.bz2
test -f /usr/share/selinux/packages/targeted/pcp-import.pp.bz2
cp -a /etc/selinux/targeted /etc/selinux/targeted.rebuilt
rm -rf /etc/selinux/targeted
mv /etc/selinux/targeted.rebuilt /etc/selinux/targeted
semodule --verbose --noreload --priority 200 --install \
    /usr/share/selinux/packages/targeted/pcp.pp.bz2 \
    /usr/share/selinux/packages/targeted/pcp-import.pp.bz2

# tweak os-release
sed -i '/^PRETTY_NAME/s/(uCore.*$/(uCore)"/' /usr/lib/os-release
