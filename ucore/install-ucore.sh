#!/bin/sh

set -ouex pipefail

RELEASE="$(rpm -E %fedora)"

## CONDITIONAL: install sanoid if ZFS
if [[ "-zfs" == "${ZFS_TAG}" ]]; then
    rpm-ostree install sanoid
fi

# install packages.json stuffs
export IMAGE_NAME=ucore
/ctx/packages.sh

## CONDITIONAL: ZFS support
if [[ "-zfs" == "${ZFS_TAG}" ]]; then
    # cockpit plugin for ZFS management
    curl --fail --retry 5 --retry-delay 5 --retry-all-errors -sSL -o /tmp/cockpit-zfs-manager-api.json \
        "https://api.github.com/repos/45Drives/cockpit-zfs-manager/releases/latest"
    CZM_TGZ_URL=$(jq -r .tarball_url /tmp/cockpit-zfs-manager-api.json)
    curl -sSL -o /tmp/cockpit-zfs-manager.tar.gz "${CZM_TGZ_URL}"

    mkdir -p /tmp/cockpit-zfs-manager
    tar -zxvf /tmp/cockpit-zfs-manager.tar.gz -C /tmp/cockpit-zfs-manager --strip-components=1
    mv /tmp/cockpit-zfs-manager/polkit-1/actions/* /usr/share/polkit-1/actions/
    mv /tmp/cockpit-zfs-manager/polkit-1/rules.d/* /usr/share/polkit-1/rules.d/
    mv /tmp/cockpit-zfs-manager/zfs /usr/share/cockpit

    curl -sSL -o /tmp/cockpit-zfs-manager-font-fix.sh \
        https://raw.githubusercontent.com/45Drives/scripts/refs/heads/main/cockpit_font_fix/fix-cockpit.sh
    chmod +x /tmp/cockpit-zfs-manager-font-fix.sh
    /tmp/cockpit-zfs-manager-font-fix.sh

    rm -rf /tmp/cockpit-zfs-manager*
fi

# install packages direct from github
/ctx/github-release-install.sh trapexit/mergerfs "fc${RELEASE}.x86_64"

# tweak os-release
sed -i '/^PRETTY_NAME/s/(uCore.*$/(uCore)"/' /usr/lib/os-release
