#!/bin/sh

set -ouex pipefail

ARCH="$(rpm -E %{_arch})"
RELEASE="$(rpm -E %fedora)"
pushd /tmp/rpms/kernel
KERNEL_VERSION=$(find kernel-*.rpm | grep -P "kernel-(\d+\.\d+\.\d+)-.*\.fc${RELEASE}\.${ARCH}" | sed -E 's/kernel-//' | sed -E 's/\.rpm//')
popd
QUALIFIED_KERNEL="$(rpm -qa | grep -P 'kernel-(\d+\.\d+\.\d+)' | sed -E 's/kernel-//')"

#### PREPARE
# enable testing repos if not enabled on testing stream
if [[ "testing" == "${COREOS_VERSION}" ]]; then
for REPO in $(ls /etc/yum.repos.d/fedora-updates-testing{,-modular}.repo); do
  if [[ "$(grep enabled=1 ${REPO} > /dev/null; echo $?)" == "1" ]]; then
    echo "enabling $REPO" &&
    sed -i '0,/enabled=0/{s/enabled=0/enabled=1/}' ${REPO}
  fi
done
fi

# add the ucore copr repo
curl -L https://copr.fedorainfracloud.org/coprs/ublue-os/ucore/repo/fedora/ublue-os-ucore-fedora.repo -o /etc/yum.repos.d/ublue-os-ucore-fedora.repo

# always disable cisco-open264 repo
sed -i 's@enabled=1@enabled=0@g' /etc/yum.repos.d/fedora-cisco-openh264.repo

#### INSTALL
# inspect to see what RPMS we copied in
find /tmp/rpms/

rpm-ostree install \
    /tmp/rpms/akmods-common/ublue-os-ucore-addons*.rpm \
    /tmp/rpms/config/ublue-os-signing*.rpm

# Handle Kernel Skew with override replace
rpm-ostree cliwrap install-to-root /
if [[ "${KERNEL_VERSION}" == "${QUALIFIED_KERNEL}" ]]; then
    echo "Installing signed kernel from kernel-cache."
    cd /tmp
    rpm2cpio /tmp/rpms/kernel/kernel-core-*.rpm | cpio -idmv
    cp ./lib/modules/*/vmlinuz /usr/lib/modules/*/vmlinuz
    cd /
else
    echo "Install kernel version ${KERNEL_VERSION} from kernel-cache."
    rpm-ostree override replace \
        --experimental \
        --install=zstd \
        /tmp/rpms/kernel/kernel-[0-9]*.rpm \
        /tmp/rpms/kernel/kernel-core-*.rpm \
        /tmp/rpms/kernel/kernel-modules-*.rpm
fi

## CONDITIONAL: install ZFS (and sanoid deps)
if [[ "-zfs" == "${ZFS_TAG}" ]]; then
    rpm-ostree install pv /tmp/rpms/akmods-zfs/kmods/zfs/*.rpm /tmp/rpms/akmods-zfs/kmods/zfs/other/zfs-dracut-*.rpm
    # for some reason depmod ran automatically with zfs 2.1 but not with 2.2
    depmod -a -v ${KERNEL_VERSION}

    curl -L https://github.com/45Drives/cockpit-zfs-manager/archive/refs/tags/v1.3.1.tar.gz | tar xz -C /tmp
    mv /tmp/cockpit-zfs-manager-1.3.1/zfs /usr/share/cockpit
fi

## CONDITIONAL: install NVIDIA
if [[ "-nvidia" == "${NVIDIA_TAG}" ]]; then
    # repo for nvidia rpms
    curl -L https://negativo17.org/repos/fedora-nvidia.repo -o /etc/yum.repos.d/fedora-nvidia.repo

    rpm-ostree install /tmp/rpms/akmods-nvidia/ucore/ublue-os-ucore-nvidia*.rpm
    sed -i '0,/enabled=0/{s/enabled=0/enabled=1/}' /etc/yum.repos.d/nvidia-container-toolkit.repo

    rpm-ostree install \
        /tmp/rpms/akmods-nvidia/kmods/kmod-nvidia*.rpm \
        nvidia-driver-cuda \
        nvidia-container-toolkit
fi

## ALWAYS: install regular packages

# add tailscale repo
curl -L https://pkgs.tailscale.com/stable/fedora/tailscale.repo -o /etc/yum.repos.d/tailscale.repo

# install packages.json stuffs
export IMAGE_NAME=ucore-minimal
/ctx/packages.sh

# tweak os-release
sed -i '/^PRETTY_NAME/s/"$/ (uCore minimal)"/' /usr/lib/os-release
