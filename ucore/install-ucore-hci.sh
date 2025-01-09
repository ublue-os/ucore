#!/bin/sh

set -ouex pipefail

# install packages.json stuffs
export IMAGE_NAME=ucore-hci
/ctx/packages.sh

# tweak os-release
sed -i '/^PRETTY_NAME/s/(uCore.*$/(uCore HCI)"/' /usr/lib/os-release
