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

    systemctl enable ublue-nvctk-cdi.service
fi


## ALWAYS: regular post-install
ln -s /usr/libexec/docker/cli-plugins/docker-compose /usr/bin/docker-compose

systemctl disable docker.socket
systemctl disable zincati.service

systemctl enable gssproxy-workaround.service
systemctl enable swtpm-workaround.service


systemctl enable ucore-paths-provision.service
systemctl enable rpm-ostreed-automatic.timer

sed -i 's/#AutomaticUpdatePolicy.*/AutomaticUpdatePolicy=stage/' /etc/rpm-ostreed.conf

# workaround to enable cockpit web logins
rm /etc/ssh/sshd_config.d/40-disable-passwords.conf

# workaround until distrobox patch for this makes it into repos
ln -s  ../usr/share/zoneinfo/UTC /etc/localtime

# switch to server profile to allow cockpit by default
cp -a /etc/firewalld/firewalld-server.conf /etc/firewalld/firewalld.conf