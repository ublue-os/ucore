#!/bin/sh

set -ouex pipefail

# install packages.json stuffs
export IMAGE_NAME=ucore-hci
/tmp/packages.sh
