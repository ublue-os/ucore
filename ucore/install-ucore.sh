#!/bin/sh

set -ouex pipefail

## CONDITIONAL: install sanoid if ZFS
if [[ "-zfs" == "${ZFS_TAG}" ]]; then
    rpm-ostree install sanoid
fi

# install packages.json stuffs
export IMAGE_NAME=ucore
/tmp/packages.sh

# install packages direct from github
/tmp/github-release-install.sh trapexit/mergerfs fc.x86_64
