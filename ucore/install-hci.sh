#!/bin/sh

set -ouex pipefail

RELEASE="$(rpm -E %fedora)"

# ucore copr needed for some packages
curl -L https://copr.fedorainfracloud.org/coprs/ublue-os/ucore/repo/fedora-${RELEASE}/ublue-os-ucore-fedora-${RELEASE}.repo \
    -o /etc/yum.repos.d/_copr_ublue-os-ucore.repo

# install packages.json stuffs
/tmp/packages.sh
