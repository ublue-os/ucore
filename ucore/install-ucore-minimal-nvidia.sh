#!/usr/bin/env bash

set -ouex pipefail

# uCore expects NVIDIA drivers are able to hot load/unload, thus does not provide it in the initramfs
echo "installing $NVIDIA_FLAVOR"

# mitigate upstream packaging bug: https://bugzilla.redhat.com/show_bug.cgi?id=2332429
# swap the incorrectly installed OpenCL-ICD-Loader for ocl-icd, the expected package
dnf5 -y swap --repo='fedora' \
    OpenCL-ICD-Loader ocl-icd

dnf -y install \
    /tmp/rpms/akmods-nvidia/ublue-os/ublue-os-nvidia-addons*.rpm
# enable repos provided by ublue-os-nvidia-addons based on which is being installed
NVREPO=fedora-nvidia
if [[ "$NVIDIA_FLAVOR" =~ lts ]]; then
    NVREPO=fedora-nvidia-lts
fi
dnf5 config-manager setopt "$NVREPO".enabled=1 nvidia-container-toolkit.enabled=1

dnf -y install --setopt=install_weak_deps=False \
    /tmp/rpms/akmods-nvidia/kmods/kmod-nvidia*.rpm

# hack required until nvidia-container-toolkit and dnf6 (fedora43) are playing nice
# per: https://github.com/NVIDIA/nvidia-container-toolkit/issues/1307#issuecomment-3486656389
echo "%_pkgverify_level none" >/etc/rpm/macros.verify
dnf -y install --setopt=install_weak_deps=False \
    nvidia-container-toolkit
rm /etc/rpm/macros.verify
dnf -y install --setopt=install_weak_deps=False \
    nvidia-driver-cuda

# disable repos provided by ublue-os-nvidia-addons
dnf5 config-manager setopt "$NVREPO".enabled=0 nvidia-container-toolkit.enabled=0

semodule --verbose --install /usr/share/selinux/packages/nvidia-container.pp

systemctl enable ublue-nvctk-cdi.service