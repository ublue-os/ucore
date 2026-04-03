#!/bin/sh

set -ouex pipefail

# install packages
dnf -y swap nfs-utils-coreos nfs-utils
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

# tweak os-release
sed -i '/^PRETTY_NAME/s/(uCore.*$/(uCore)"/' /usr/lib/os-release
