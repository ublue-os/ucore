#!/bin/sh

set -ouex pipefail

sed -i 's@enabled=1@enabled=0@g' /etc/yum.repos.d/nvidia-container-toolkit.repo

semodule --verbose --install /usr/share/selinux/packages/nvidia-container.pp