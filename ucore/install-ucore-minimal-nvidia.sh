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

# Install the driver snapshot that was used to build the kmod. Mixing it with
# mutable NVIDIA repositories can otherwise pull an incompatible akmod.
# nvidia-driver-selinux is only published by the regular NVIDIA repository,
# including for LTS builds. All version-coupled packages remain local below.
dnf5 config-manager setopt fedora-nvidia.enabled=1
dnf -y install --setopt=install_weak_deps=False nvidia-driver-selinux
dnf5 config-manager setopt fedora-nvidia.enabled=0

ARCH="$(rpm -E '%{_arch}')"
shopt -s nullglob
CUDA_RPMS=(
    /tmp/rpms/akmods-nvidia/nvidia/nvidia-driver-cuda-[0-9]*."${ARCH}".rpm
    /tmp/rpms/akmods-nvidia/nvidia/nvidia-driver-cuda-libs-[0-9]*."${ARCH}".rpm
    /tmp/rpms/akmods-nvidia/nvidia/nvidia-kmod-common-[0-9]*.noarch.rpm
    /tmp/rpms/akmods-nvidia/nvidia/nvidia-modprobe-[0-9]*."${ARCH}".rpm
    /tmp/rpms/akmods-nvidia/nvidia/nvidia-persistenced-[0-9]*."${ARCH}".rpm
)
KMOD_RPMS=(
    /tmp/rpms/akmods-nvidia/kmods/kmod-nvidia*.rpm
)
COMMON_RPMS=(
    /tmp/rpms/akmods-nvidia/nvidia/nvidia-driver-common-[0-9]*."${ARCH}".rpm
)
if [[ ${#COMMON_RPMS[@]} -gt 0 ]]; then
    CUDA_RPMS+=("${COMMON_RPMS[@]}")
    EXPECTED_CUDA_RPMS=6
else
    SPLIT_COMMON_RPMS=(
        /tmp/rpms/akmods-nvidia/nvidia/libnvidia-cfg-[0-9]*."${ARCH}".rpm
        /tmp/rpms/akmods-nvidia/nvidia/libnvidia-gpucomp-[0-9]*."${ARCH}".rpm
        /tmp/rpms/akmods-nvidia/nvidia/libnvidia-ml-[0-9]*."${ARCH}".rpm
    )
    CUDA_RPMS+=("${SPLIT_COMMON_RPMS[@]}")
    EXPECTED_CUDA_RPMS=8
fi
if [[ ${#CUDA_RPMS[@]} -ne ${EXPECTED_CUDA_RPMS} || ${#KMOD_RPMS[@]} -eq 0 ]]; then
    echo "Missing NVIDIA CUDA runtime or kmod RPMs for ${ARCH}" >&2
    exit 1
fi
dnf -y install --setopt=install_weak_deps=False \
    "${CUDA_RPMS[@]}" "${KMOD_RPMS[@]}"

# hack required until nvidia-container-toolkit and dnf6 (fedora43) are playing nice
# per: https://github.com/NVIDIA/nvidia-container-toolkit/issues/1307#issuecomment-3486656389
dnf5 config-manager setopt nvidia-container-toolkit.enabled=1
echo "%_pkgverify_level none" >/etc/rpm/macros.verify
dnf -y install --setopt=install_weak_deps=False \
    nvidia-container-toolkit
rm /etc/rpm/macros.verify

dnf5 config-manager setopt nvidia-container-toolkit.enabled=0

if [[ "$(rpm -q --qf '%{VERSION}' kmod-nvidia)" != "$(rpm -q --qf '%{VERSION}' nvidia-driver-cuda)" ]]; then
    echo "Installed NVIDIA kmod and CUDA driver versions do not match" >&2
    exit 1
fi
if rpm -q akmod-nvidia >/dev/null; then
    echo "akmod-nvidia must not be installed in the image" >&2
    exit 1
fi

# work around intermittent aarch64 overlayfs EXDEV/ENOTEMPTY failures in the
# semodule policy-store transaction (mainly nvidia-lts:aarch64) by forcing
# /etc/selinux/targeted fully into this layer first, so the transaction's
# directory renames stay within a single layer.
cp -a /etc/selinux/targeted /etc/selinux/targeted.rebuilt
rm -rf /etc/selinux/targeted
mv /etc/selinux/targeted.rebuilt /etc/selinux/targeted

semodule --verbose --noreload --install /usr/share/selinux/packages/nvidia-container.pp

systemctl enable nvidia-cdi-refresh.service nvidia-cdi-refresh.path nvidia-persistenced.service
