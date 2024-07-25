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

# install packages direct from github
/ctx/github-release-install.sh trapexit/mergerfs fc${RELEASE}.x86_64

# tweak os-release
sed -i '/^PRETTY_NAME/s/(uCore.*$/(uCore)"/' /usr/lib/os-release
