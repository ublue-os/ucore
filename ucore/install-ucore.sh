#!/bin/sh

set -ouex pipefail

ARCH="$(rpm -E %_arch)"
RELEASE="$(rpm -E %fedora)"

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
    sanoid \
    smartctl \
    snapraid \
    tiwilink-firmware \
    usbutils \
    xdg-dbus-proxy \
    xdg-user-dirs

# install packages direct from github
if [[ "${RELEASE}" -ge "43" ]]; then
  /ctx/github-release-install.sh trapexit/mergerfs "fc${RELEASE}.${ARCH}"
elif [[ "${ARCH}" == "x86_64" ]]; then
  # before F43, mergerfs only available for x86_64
  /ctx/github-release-install.sh trapexit/mergerfs "fc${RELEASE}.x86_64"
fi

# cockpit plugin for ZFS management
curl --fail --retry 15 --retry-all-errors -sSL -o /tmp/cockpit-zfs-manager-api.json \
    "https://api.github.com/repos/45Drives/cockpit-zfs-manager/releases/latest"
CZM_TGZ_URL=$(jq -r .tarball_url /tmp/cockpit-zfs-manager-api.json)
curl --fail --retry 15 --retry-all-errors -sSL -o /tmp/cockpit-zfs-manager.tar.gz "${CZM_TGZ_URL}"

mkdir -p /tmp/cockpit-zfs-manager
tar -zxvf /tmp/cockpit-zfs-manager.tar.gz -C /tmp/cockpit-zfs-manager --strip-components=1
mv /tmp/cockpit-zfs-manager/polkit-1/actions/* /usr/share/polkit-1/actions/
mv /tmp/cockpit-zfs-manager/polkit-1/rules.d/* /usr/share/polkit-1/rules.d/
mv /tmp/cockpit-zfs-manager/zfs /usr/share/cockpit

curl --fail --retry 15 --retry-all-errors -sSL -o /tmp/cockpit-zfs-manager-font-fix.sh \
    https://raw.githubusercontent.com/45Drives/scripts/refs/heads/main/cockpit_font_fix/fix-cockpit.sh
chmod +x /tmp/cockpit-zfs-manager-font-fix.sh
/tmp/cockpit-zfs-manager-font-fix.sh

rm -rf /tmp/cockpit-zfs-manager*

# tweak os-release
sed -i '/^PRETTY_NAME/s/(uCore.*$/(uCore)"/' /usr/lib/os-release
