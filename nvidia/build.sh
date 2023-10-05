#!/bin/sh

set -ouex pipefail

# repo for nvidia builds
curl -sL --output-dir /etc/yum.repos.d --remote-name \
    https://negativo17.org/repos/fedora-nvidia.repo

find /tmp/rpms

rpm-ostree install /tmp/rpms/ublue-os-ucore-nvidia-*.rpm
sed -i '0,/enabled=0/{s/enabled=0/enabled=1/}' /etc/yum.repos.d/nvidia-container-runtime.repo

cat /tmp/rpms/nvidia-vars

rpm-ostree install \
    /tmp/rpms/kmod-nvidia-*.rpm \
    nvidia-driver-cuda \
    nvidia-container-toolkit
