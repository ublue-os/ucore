#!/bin/sh

set -ouex pipefail

## CONDITIONAL: post-install ZFS
if [[ "-zfs" == "${ZFS_TAG}" ]]; then
    echo "no post-install tasks for ZFS"
fi

## CONDITIONAL: post-install NVIDIA
if [[ "-nvidia" == "${NVIDIA_TAG}" ]]; then
    sed -i 's@enabled=1@enabled=0@g' /etc/yum.repos.d/nvidia-container-toolkit.repo

    semodule --verbose --install /usr/share/selinux/packages/nvidia-container.pp
fi