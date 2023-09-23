# uCore

[![build-ucore](https://github.com/ublue-os/ucore/actions/workflows/build.yml/badge.svg)](https://github.com/ublue-os/ucore/actions/workflows/build.yml)

## What is this?

You should be familiar with [Fedora CoreOS](https://getfedora.org/coreos/), as this is an OCI image of CoreOS with "batteries included". More specifically, it's an opinionated, custom CoreOS image, built daily with some commonly used tools added in. The idea is to make a lightweight server image including most used services or the building blocks to host them.

WARNING: This image has **not** been heavily tested, though the underlying components have. Please take a look at the included modifications and help test if this project interests you.

## Images & Features

### `ucore`

Suitable for running containerized workloads on either baremetal or virtual machines, this image tries to stay lightweight with not too many additions.

- Starts with a [Fedora CoreOS image](https://quay.io/repository/fedora/fedora-coreos?tab=tags)
- Adds the following:
  - [cockpit](https://cockpit-project.org)
  - [distrobox](https://github.com/89luca89/distrobox)
  - guest VM agents (`qemu-guest-agent` and `open-vm-tools`)
  - moby-engine(docker), docker-compose and podman-compose
  - [tailscale](https://tailscale.com) and [wireguard-tools](https://www.wireguard.com)
  - [tmux](https://github.com/tmux/tmux/wiki/Getting-Started)
- Optional ZFS versions also add:
  - sanoid/syncoid dependencies - see below for details
  - [ZFS](https://openzfs.github.io/openzfs-docs/Getting%20Started/Fedora/index.html)
- Enables staging of automatic system updates via rpm-ostreed
- Enables password based SSH auth (required for locally running cockpit web interface)
- Disables Zincati auto upgrade/reboot service
  - *NOTE: currently, zincati fails to start on systems with OCI based deployments (like uCore). Upstream efforts are active to correct this.*

Note: per [cockpit instructions](https://cockpit-project.org/running.html#coreos) the cockpit-ws RPM is **not** installed, rather it is provided as a pre-defined systemd service which runs a podman container.

### `ucore-hci`

Hyper-Coverged Infrastructure(HCI) refers to storage and virtualization in one place... So this image is suitable for use as a hypervisor, storage server(NAS), as well as running containerized workloads). Accordingingly, it will be a bit larger due to extra hardware support, storage and virtualization packages.


- Starts with `ucore` to give you everything above, plus:
- Adds the following:
  - [cockpit-machines](https://github.com/cockpit-project/cockpit-machines): Cockpit GUI for managing virtual machines
  - [duperemove](https://github.com/markfasheh/duperemove)
  - intel wifi firmware - CoreOS omits this despite including atheros wifi firmware... hardware enablement FTW
  - [libvirt-client](https://libvirt.org/): `virsh` command-line utility for managing virtual machines
  - [libvirt-daemon-kvm](https://libvirt.org/): libvirt KVM hypervisor management
  - [mergerfs](https://github.com/trapexit/mergerfs)
  - [snapraid](https://www.snapraid.it/)
  - udev rules enabling full functionality on some [Realtek 2.5Gbit USB Ethernet](https://github.com/wget/realtek-r8152-linux/) devices
  - virt-install: command-line utility for installing virtual machines

Note: Fedora now uses `DefaultTimeoutStop=45s` for systemd services which could cause `libvirtd` to quit before shutting down slow VMs. Consider adding `TimeoutStopSec=120s` as an override for `libvirtd.service` if needed.

### `fedora-coreos-zfs`

- A generic [Fedora CoreOS image](https://quay.io/repository/fedora/fedora-coreos?tab=tags) image
- Adds [ZFS](https://openzfs.github.io/openzfs-docs/Getting%20Started/Fedora/index.html) from the [ucore-kmods image](https://github.com/ublue-os/ucore-kmods)
- Does NOT add sanoid/syncoid dependencies as mentioned above in `ucore` features list

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

### Distrobox

Users may use [distrobox](https://github.com/89luca89/distrobox) to run images of mutable distributions where applications can be installed with traditional package managers. This may be useful for installing interactive utilities such has `htop`, `nmap`, etc. As stated above, however, *services* should run as containers.

### CoreOS and ostree Docs

It's a good idea to become familar with the [Fedora CoreOS Documentation](https://docs.fedoraproject.org/en-US/fedora-coreos/) as well as the [CoreOS rpm-ostree docs](https://coreos.github.io/rpm-ostree/). Note especially, this image is only possible due to [ostree native containers](https://coreos.github.io/rpm-ostree/container/).

### Sanoid/Syncoid

sanoid/syncoid is a great tool for manual and automated snapshot/transfer of ZFS datasets. However, there is not a current stable RPM, rather they provide [instructions on installing via git](https://github.com/jimsalterjrs/sanoid/blob/master/INSTALL.md#centos).

`ucore` has pre-install all the (lightweight) required dependencies (perl-Config-IniFiles perl-Data-Dumper perl-Capture-Tiny perl-Getopt-Long lzop mbuffer mhash pv), such that a user wishing to use sanoid/syncoid only need install the "sbin" files and create configuration/systemd units for it.

### ZFS

The ZFS kernel module and tools are pre-installed, but like other services, ZFS is not pre-configured to load on default.

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

| IMAGE | TAG |
|-|-|
| [`ucore`](#ucore) | `stable`, `testing`, `stable-zfs`, `testing-zfs` |
| [`ucore-hci`](#ucore-hci) | `stable`, `testing`, `stable-zfs`, `testing-zfs` |
| [`fedora-coreos-zfs`](#fedora-coreos-zfs) | `stable`, `testing` |



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
