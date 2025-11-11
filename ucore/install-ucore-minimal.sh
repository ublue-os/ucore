#!/bin/sh

set -ouex pipefail

ARCH="$(rpm -E %{_arch})"
RELEASE="$(rpm -E %fedora)"

pushd /tmp/rpms/kernel
KERNEL_VERSION=$(find kernel-*.rpm | grep -P "kernel-(\d+\.\d+\.\d+)-.*\.fc${RELEASE}\.${ARCH}" | sed -E 's/kernel-//' | sed -E 's/\.rpm//')
popd

#### PREPARE
# enable testing repos if not enabled on testing stream
if [[ "testing" == "${COREOS_VERSION}" ]]; then
for REPO in $(ls /etc/yum.repos.d/fedora-updates-testing.repo); do
  if [[ "$(grep enabled=1 ${REPO} > /dev/null; echo $?)" == "1" ]]; then
    echo "enabling $REPO" &&
    sed -i '0,/enabled=0/{s/enabled=0/enabled=1/}' ${REPO}
  fi
done
fi

# enable ublue-os repos
dnf -y install dnf5-plugins
dnf -y copr enable ublue-os/packages
dnf -y copr enable ublue-os/ucore

# always disable cisco-open264 repo
sed -i 's@enabled=1@enabled=0@g' /etc/yum.repos.d/fedora-cisco-openh264.repo

#### INSTALL
# inspect to see what RPMS we copied in
find /tmp/rpms/

dnf -y install /tmp/rpms/akmods-common/ublue-os-ucore-addons*.rpm
dnf -y install ublue-os-signing

# Put the policy file in the correct place and cleanup /usr/etc
cp /usr/etc/containers/policy.json /etc/containers/policy.json
rm -rf /usr/etc

# Replace Existing Kernel with packages from akmods cached kernel
for pkg in kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra; do
    if rpm -q $pkg >/dev/null 2>&1; then
        rpm --erase $pkg --nodeps
    fi
done
echo "Install kernel version ${KERNEL_VERSION} from kernel-cache."
dnf -y install \
    /tmp/rpms/kernel/kernel-[0-9]*.rpm \
    /tmp/rpms/kernel/kernel-core-*.rpm \
    /tmp/rpms/kernel/kernel-modules-*.rpm

# Ensure kernel packages can't be updated by other dnf operations
dnf versionlock add kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra

# Regenerate initramfs, for new kernel; not including NVIDIA or ZFS kmods
QUALIFIED_KERNEL="$(rpm -qa | grep -P 'kernel-(\d+\.\d+\.\d+)' | sed -E 's/kernel-//')"
/usr/bin/dracut --no-hostonly --kver "$QUALIFIED_KERNEL" --reproducible -v --add ostree -f "/lib/modules/$QUALIFIED_KERNEL/initramfs.img"
chmod 0600 "/lib/modules/$QUALIFIED_KERNEL/initramfs.img"

## ALWAYS: install ZFS (and sanoid deps)
# uCore does not support ZFS as rootfs, thus does not provide it in the initramfs
dnf -y install /tmp/rpms/akmods-zfs/kmods/zfs/*.rpm /tmp/rpms/akmods-zfs/kmods/zfs/other/zfs-dracut-*.rpm
# for some reason depmod ran automatically with zfs 2.1 but not with 2.2
echo "Update modules.dep, etc..."
depmod -a "${KERNEL_VERSION}"

## CONDITIONAL: install NVIDIA
if [[ "-nvidia" == "${NVIDIA_TAG}" ]]; then
    # uCore expects NVIDIA drivers are able to hot load/unload, thus does not provide it in the initramfs
    # repo for nvidia rpms
    curl --fail --retry 15 --retry-all-errors -sSL https://negativo17.org/repos/fedora-nvidia.repo -o /etc/yum.repos.d/fedora-nvidia.repo

    dnf -y install /tmp/rpms/akmods-nvidia/ucore/ublue-os-ucore-nvidia*.rpm
    sed -i '0,/enabled=0/{s/enabled=0/enabled=1/}' /etc/yum.repos.d/nvidia-container-toolkit.repo

    dnf -y install \
        /tmp/rpms/akmods-nvidia/kmods/kmod-nvidia*.rpm \
        nvidia-driver-cuda \
        nvidia-container-toolkit
fi

## CONDITIONAL: install packages specific to x86_64
if [[ "x86_64" == "${ARCH}" ]]; then
    dnf -y install intel-compute-runtime
fi

## ALWAYS: install regular packages

# add tailscale repo
curl --fail --retry 15 --retry-all-errors -sSL https://pkgs.tailscale.com/stable/fedora/tailscale.repo -o /etc/yum.repos.d/tailscale.repo

# install packages.json stuffs
export IMAGE_NAME=ucore-minimal
/ctx/packages.sh

# tweak os-release
sed -i '/^PRETTY_NAME/s/"$/ (uCore minimal)"/' /usr/lib/os-release
sed -i 's|^VARIANT_ID=.*|VARIANT_ID=ucore|' /usr/lib/os-release
sed -i 's|^VARIANT=.*|VARIANT="uCore"|' /usr/lib/os-release
