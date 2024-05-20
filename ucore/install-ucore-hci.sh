#!/bin/sh

set -ouex pipefail

# add the coreos pool repo for package versions which can't be found elswehere
curl -L https://raw.githubusercontent.com/coreos/fedora-coreos-config/testing-devel/fedora-coreos-pool.repo -o /etc/yum.repos.d/fedora-coreos-pool.repo

# install packages.json stuffs
export IMAGE_NAME=ucore-hci
/tmp/packages.sh

# remove coreos pool repo
rm -f /etc/yum.repos.d/fedora-coreos-pool.repo

# tweak os-release
sed -i '/^PRETTY_NAME/s/(uCore.*$/(uCore HCI)"/' /usr/lib/os-release
