# uCore

[![stable](https://github.com/ublue-os/ucore/actions/workflows/build-stable.yml/badge.svg)](https://github.com/ublue-os/ucore/actions/workflows/build-stable.yml)
[![testing](https://github.com/ublue-os/ucore/actions/workflows/build-testing.yml/badge.svg)](https://github.com/ublue-os/ucore/actions/workflows/build-testing.yml)

## What is this?

You should be familiar with [Fedora CoreOS](https://getfedora.org/coreos/), as this is an OCI image of CoreOS with "batteries included". More specifically, it's an opinionated, custom CoreOS image, built daily with some commonly used tools added in. The idea is to make a lightweight server image including most used services or the building blocks to host them.

WARNING: This image has **not** been heavily tested, though the underlying components have. Please take a look at the included modifications and help test if this project interests you.

## Images & Features

### `fedora-coreos`

**NOTE: formerly named `fedora-coreos-zfs`, that version of the image did not offer the nvidia option. Please update with `rpm-ostree rebase`.**

A generic [Fedora CoreOS image](https://quay.io/repository/fedora/fedora-coreos?tab=tags) image with choice of add-on kernel modules:

- [nvidia versions](#tag-matrix) add:
  - [nvidia driver](https://github.com/ublue-os/ucore-kmods) - latest driver (currently version 535) built from negativo17's akmod package
  - [nvidia-container-toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/sample-workload.html) - latest toolkit which supports both root and rootless podman containers and CDI
  - [nvidia container selinux policy](https://github.com/NVIDIA/dgx-selinux/tree/master/src/nvidia-container-selinux) - allows using `--security-opt label=type:nvidia_container_t` for some jobs (some will still need `--security-opt label=disable` as suggested by nvidia)
- [ZFS versions](#tag-matrix) add:
  - [ZFS driver](https://github.com/ublue-os/ucore-kmods) - latest driver (currently pinned to 2.2.x series)

*NOTE: currently, zincati fails to start on systems with OCI based deployments (like uCore). Upstream efforts are active to correct this.*

### `ucore`

Suitable for running containerized workloads on either baremetal or virtual machines, this image tries to stay lightweight  but functional for multiple use cases, including that of a storage server (NAS).

- Starts with a [Fedora CoreOS image](https://quay.io/repository/fedora/fedora-coreos?tab=tags)
- Adds the following:
  - [cockpit](https://cockpit-project.org)
  - [distrobox](https://github.com/89luca89/distrobox)
  - [duperemove](https://github.com/markfasheh/duperemove)
  - guest VM agents (`qemu-guest-agent` and `open-vm-tools`)
  - intel wifi firmware - CoreOS omits this despite including atheros wifi firmware... hardware enablement FTW
  - [mergerfs](https://github.com/trapexit/mergerfs)
  - moby-engine(docker), docker-compose and podman-compose
  - [snapraid](https://www.snapraid.it/)
  - [tailscale](https://tailscale.com) and [wireguard-tools](https://www.wireguard.com)
  - [tmux](https://github.com/tmux/tmux/wiki/Getting-Started)
  - udev rules enabling full functionality on some [Realtek 2.5Gbit USB Ethernet](https://github.com/wget/realtek-r8152-linux/) devices
- Optional [nvidia versions](#tag-matrix) add:
  - [nvidia driver](https://github.com/ublue-os/ucore-kmods) - latest driver (currently version 535) built from negativo17's akmod package
  - [nvidia-container-toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/sample-workload.html) - latest toolkit which supports both root and rootless podman containers and CDI
  - [nvidia container selinux policy](https://github.com/NVIDIA/dgx-selinux/tree/master/src/nvidia-container-selinux) - allows using `--security-opt label=type:nvidia_container_t` for some jobs (some will still need `--security-opt label=disable` as suggested by nvidia)
- Optional [ZFS versions](#tag-matrix) add:
  - [sanoid/syncoid dependencies](https://github.com/jimsalterjrs/sanoid) - [see below](#zfs) for details
  - [ZFS driver](https://github.com/ublue-os/ucore-kmods) - latest driver (currently pinned to 2.2.x series)
- Enables staging of automatic system updates via rpm-ostreed
- Enables password based SSH auth (required for locally running cockpit web interface)
- Disables Zincati auto upgrade/reboot service

Note: per [cockpit instructions](https://cockpit-project.org/running.html#coreos) the cockpit-ws RPM is **not** installed, rather it is provided as a pre-defined systemd service which runs a podman container.

### `ucore-hci`

Hyper-Coverged Infrastructure(HCI) refers to storage and virtualization in one place... So this image primarily adds the virtualization stack.


- Starts with `ucore` to give you everything above, plus:
- Adds the following:
  - [cockpit-machines](https://github.com/cockpit-project/cockpit-machines): Cockpit GUI for managing virtual machines
  - [libvirt-client](https://libvirt.org/): `virsh` command-line utility for managing virtual machines
  - [libvirt-daemon-kvm](https://libvirt.org/): libvirt KVM hypervisor management
  - virt-install: command-line utility for installing virtual machines

Note: Fedora now uses `DefaultTimeoutStop=45s` for systemd services which could cause `libvirtd` to quit before shutting down slow VMs. Consider adding `TimeoutStopSec=120s` as an override for `libvirtd.service` if needed.

## Tips and Tricks

### Immutability and Podman

These images are immutable and you probably shouldn't install packages like in a mutable "normal" distribution.

Fedora CoreOS expects the user to run services using [podman](https://podman.io). `moby-engine`, the free Docker implementation, is installed for those who desire docker instead of podman.

### Default Services

To maintain this image's suitability as a minimal container host, most add-on services are not auto-enabled.

To activate pre-installed services (`cockpit`, `docker`, `tailscaled`, etc):

```bash
sudo systemctl enable --now SERVICENAME.service
```

Note: `libvirtd` is enabled by default, but only starts when triggerd by it's socket (eg, using `virsh` or other clients).

### Docker/Moby and Podman

NOTE: CoreOS [cautions against](https://docs.fedoraproject.org/en-US/fedora-coreos/faq/#_can_i_run_containers_via_docker_and_podman_at_the_same_time) running podman and docker containers at the same time.  Thus, `docker.socket` is disabled by default to prevent accidental activation of the docker daemon, given podman is the default.

### Podman and FirewallD

Podman and firewalld [can sometimes conflict](https://github.com/ublue-os/ucore/issues/90) such that a `firewall-cmd --reload` removes firewall rules generated by podman.

A service is included to mitigate this by monitoring for firewall reload events on dbus and then reloading podman networks. If needed, enable like so: `systemctl enable --now podman-firewalld-reload.service`


### Distrobox

Users may use [distrobox](https://github.com/89luca89/distrobox) to run images of mutable distributions where applications can be installed with traditional package managers. This may be useful for installing interactive utilities such has `htop`, `nmap`, etc. As stated above, however, *services* should run as containers.

### CoreOS and ostree Docs

It's a good idea to become familar with the [Fedora CoreOS Documentation](https://docs.fedoraproject.org/en-US/fedora-coreos/) as well as the [CoreOS rpm-ostree docs](https://coreos.github.io/rpm-ostree/). Note especially, this image is only possible due to [ostree native containers](https://coreos.github.io/rpm-ostree/container/).


### Sanoid/Syncoid

sanoid/syncoid is a great tool for manual and automated snapshot/transfer of ZFS datasets. However, there is not a current stable RPM, rather they provide [instructions on installing via git](https://github.com/jimsalterjrs/sanoid/blob/master/INSTALL.md#centos).

`ucore` has pre-install all the (lightweight) required dependencies (perl-Config-IniFiles perl-Data-Dumper perl-Capture-Tiny perl-Getopt-Long lzop mbuffer mhash pv), such that a user wishing to use sanoid/syncoid only need install the "sbin" files and create configuration/systemd units for it.

### NVIDIA

If you installed an image with `-nvidia` in the tag, the nvidia kernel module, basic CUDA libraries, and the nvidia-container-toolkit are all are pre-installed.

Note, this does NOT add desktop graphics services to your images, but it DOES enable your compatible nvidia GPU to be used for nvdec, nvenc, CUDA, etc. Since this is CoreOS and it's primarily intended for container workloads the [nvidia container toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/index.html) should be well understood.

Note the included driver is the [latest nvidia driver](https://github.com/negativo17/nvidia-driver/blob/master/nvidia-driver.spec) as bundled by [negativo17](https://negativo17.org/nvidia-driver/). This package was chosen over rpmfusion's due to it's granular packages which allow us to install just the minimal `nvidia-driver-cuda` packages.

#### Other NVIDIA Drivers

If you need an older (or different) driver, consider looking at the [container-toolkit-fcos driver](https://hub.docker.com/r/fifofonix/driver/). It provides pre-bundled container images with nvidia drivers for FCOS, allowing auto-build/loading of the nvidia driver IN podman, at boot, via a systemd service.

If going this path, you likely won't want to use the `ucore` `-nvidia` image, but would use the suggested systemd service. The nvidia container toolkit will still be required but can by layered easily.

### ZFS

If you installed an image with `-zfs` in the tag (or `fedora-coreos-zfs`), the ZFS kernel module and tools are pre-installed, but like other services, ZFS is not pre-configured to load on default.

Load it with the command `modprobe zfs` and use `zfs` and `zpool` commands as desired.

Per the [OpenZFS Fedora documentation](https://openzfs.github.io/openzfs-docs/Getting%20Started/Fedora/index.html):

> By default ZFS kernel modules are loaded upon detecting a pool. To always load the modules at boot:

```
echo zfs > /etc/modules-load.d/zfs.conf
```

#### ZFS and immutable root filesystem

The default mountpoint for any newly created zpool `tank` is `/tank`. This is a problem in CoreOS as the root filesystem (`/`) is immutable, which means a directory cannot be created as a mountpoint for the zpool. An example of the problem looks like this:

```
# zpool create tank /dev/sdb
cannot mount '/tank': failed to create mountpoint: Operation not permitted
```

To avoid this problem, always create new zpools with a specified mountpoint:

```
# zpool create -m /var/tank tank /dev/sdb
```

If you do forget to specify the mountpoint, or you need to change the mountpoint on an existing zpool:

```
# zfs set mountpoint=/var/tank tank
```


### SecureBoot

For those wishing to use `nvidia` or `zfs` images with pre-built kmods AND run SecureBoot, the kernel will not load those kmods until the public signing key has been imported as a MOK (Machine-Owner Key).

Do so like this:
```bash
sudo mokutil --import /etc/pki/akmods/certs/akmods-ublue.der
```

The utility will prompt for a password. The password will be used to verify this key is the one you meant to import, after rebooting and entering the UEFI MOK import utility.


## How to Install

### Prerequsites

This image is not currently available for direct install. The user must follow the [CoreOS installation guide](https://docs.fedoraproject.org/en-US/fedora-coreos/bare-metal/). There are varying methods of installation for bare metal, cloud providers, and virtualization platforms.

All CoreOS installation methods require the user to [produce an Ignition file](https://docs.fedoraproject.org/en-US/fedora-coreos/producing-ign/). This Ignition file should, at mimimum, set a password and SSH key for the default user (default username is `core`).

### Install and Manually Rebase

You can rebase any Fedora CoreOS x86_64 installation to uCore.  Installing CoreOS itself can be done through [a number of provisioning methods](https://docs.fedoraproject.org/en-US/fedora-coreos/bare-metal/).

To rebase an Fedora CoreOS machine to the latest uCore (stable):

1. Execute the `rpm-ostree rebase` command (below) with desired `IMAGE` and `TAG`.
1. Reboot, as instructed.
1. After rebooting, you should [pin the working deployment](https://docs.fedoraproject.org/en-US/fedora-silverblue/faq/#_how_can_i_upgrade_my_system_to_the_next_major_version_for_instance_rawhide_or_an_upcoming_fedora_release_branch_while_keeping_my_current_deployment) which allows you to rollback if required.

```bash
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/ublue-os/IMAGE:TAG
```

#### Tag Matrix
| IMAGE | TAG |
|-|-|
| [`fedora-coreos`](#fedora-coreos) - *stable* | `stable-nvidia`, `stable-zfs`,`stable-nvidia-zfs` |
| [`fedora-coreos`](#fedora-coreos) - *testing* | `testing-nvidia`, `testing-zfs`, `testing-nvidia-zfs` |
| [`ucore`](#ucore) - *stable* | `stable`, `stable-nvidia`, `stable-zfs`,`stable-nvidia-zfs` |
| [`ucore`](#ucore) - *testing* | `testing`, `testing-nvidia`, `testing-zfs`, `testing-nvidia-zfs` |
| [`ucore-hci`](#ucore-hci) - *stable* | `stable`, `stable-nvidia`, `stable-zfs`,`stable-nvidia-zfs` |
| [`ucore-hci`](#ucore-hci) - *testing* | `testing`, `testing-nvidia`, `testing-zfs`, `testing-nvidia-zfs` |



### Install with Auto-Rebase

Your path to a running uCore can be shortend by using [examples/ucore-autorebase.butane](examples/ucore-autorebase.butane) as the starting point for your CoreOS ignition file.

1. As usual, you'll need to [follow the docs to setup a password](https://coreos.github.io/butane/examples/#using-password-authentication). Substitute your password hash for `YOUR_GOOD_PASSWORD_HASH_HERE` in the `ucore-autorebase.butane` file, and add your ssh pub key while you are at it.
1. Generate an ignition file from your new `ucore-autorebase.butane` [using the butane utility](https://coreos.github.io/butane/getting-started/).
1. Now install CoreOS for [hypervisor, cloud provider or bare-metal](https://docs.fedoraproject.org/en-US/fedora-coreos/bare-metal/). Your ignition file should work for any platform, auto-rebasing to the `ucore:stable` (or other `IMAGE:TAG` combo), rebooting and leaving your install ready to use.

## Verification

These images are signed with sigstore's [cosign](https://docs.sigstore.dev/cosign/overview/). You can verify the signature by downloading the `cosign.pub` key from this repo and running the following command:

```bash
cosign verify --key cosign.pub ghcr.io/ublue-os/ucore
```
