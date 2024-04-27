# uCore

[![stable](https://github.com/ublue-os/ucore/actions/workflows/build-stable.yml/badge.svg)](https://github.com/ublue-os/ucore/actions/workflows/build-stable.yml)
[![testing](https://github.com/ublue-os/ucore/actions/workflows/build-testing.yml/badge.svg)](https://github.com/ublue-os/ucore/actions/workflows/build-testing.yml)

## What is this?

You should be familiar with [Fedora CoreOS](https://getfedora.org/coreos/), as this is an OCI image of CoreOS with "batteries included". More specifically, it's an opinionated, custom CoreOS image, built daily with some commonly used tools added in. The idea is to make a lightweight server image including most used services or the building blocks to host them.

Please take a look at the included modifications and help us test uCore if the project interests you.

## Images & Features

The uCore project builds four images, each with different tags for different features.

The image names are:

- [`fedora-coreos`](#fedora-coreos)
- [`ucore-minimal`](#ucore-minimal)
- [`ucore`](#ucore)
- [`ucore-hci`](#ucore-hci)

The [tag matrix](#tag-matrix) includes combinations of the following:

- `stable` - for an image based on the Fedora CoreOS stable stream
- `testing` - for an image based on the Fedora CoreOS testing stream
- `nvidia` - for an image which includes nvidia driver and container runtime
- `zfs` - for an image which includes zfs driver and tools


### `fedora-coreos`

*NOTE: formerly named `fedora-coreos-zfs`, the previous version of the image did not offer the nvidia option. If on the previous image name, please update with `rpm-ostree rebase`.*

A generic [Fedora CoreOS image](https://quay.io/repository/fedora/fedora-coreos?tab=tags) image with choice of add-on kernel modules:

- [nvidia versions](#tag-matrix) add:
  - [nvidia driver](https://github.com/ublue-os/ucore-kmods) - latest driver (currently version 535) built from negativo17's akmod package
  - [nvidia-container-toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/sample-workload.html) - latest toolkit which supports both root and rootless podman containers and CDI
  - [nvidia container selinux policy](https://github.com/NVIDIA/dgx-selinux/tree/master/src/nvidia-container-selinux) - allows using `--security-opt label=type:nvidia_container_t` for some jobs (some will still need `--security-opt label=disable` as suggested by nvidia)
- [ZFS versions](#tag-matrix) add:
  - [ZFS driver](https://github.com/ublue-os/ucore-kmods) - latest driver (currently pinned to 2.2.x series)

*NOTE: currently, zincati fails to start on systems with OCI based deployments (like uCore). Upstream efforts are active to correct this.*

### `ucore-minimal`

Suitable for running containerized workloads on either bare metal or virtual machines, this image tries to stay lightweight but functional.

- Starts with a [Fedora CoreOS image](https://quay.io/repository/fedora/fedora-coreos?tab=tags)
- Adds the following:
  - [bootc](https://github.com/containers/bootc) (new way to update container native systems)
  - [cockpit](https://cockpit-project.org) (podman container and system management)
  - [firewalld](https://firewalld.org/)
  - guest VM agents (`qemu-guest-agent` and `open-vm-tools`))
  - [docker-buildx](https://github.com/docker/buildx) and [docker-compose](https://github.com/docker/compose) (versions matched to moby release) *docker(moby-engine) is pre-installed in CoreOS*
  - [podman-compose](https://github.com/containers/podman-compose) *podman is pre-installed in CoreOS*
  - [tailscale](https://tailscale.com) and [wireguard-tools](https://www.wireguard.com)
  - [tmux](https://github.com/tmux/tmux/wiki/Getting-Started)
  - udev rules enabling full functionality on some [Realtek 2.5Gbit USB Ethernet](https://github.com/wget/realtek-r8152-linux/) devices
- Optional [nvidia versions](#tag-matrix) add:
  - [nvidia driver](https://github.com/ublue-os/ucore-kmods) - latest driver (currently version 535) built from negativo17's akmod package
  - [nvidia-container-toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/sample-workload.html) - latest toolkit which supports both root and rootless podman containers and CDI
  - [nvidia container selinux policy](https://github.com/NVIDIA/dgx-selinux/tree/master/src/nvidia-container-selinux) - allows using `--security-opt label=type:nvidia_container_t` for some jobs (some will still need `--security-opt label=disable` as suggested by nvidia)
- Optional [ZFS versions](#tag-matrix) add:
  - [ZFS driver](https://github.com/ublue-os/ucore-kmods) - latest driver (currently pinned to 2.2.x series)
  - [sanoid/syncoid dependencies](https://github.com/jimsalterjrs/sanoid) - [see below](#zfs) for details
    - note: on `ucore-minimal` images, only `pv` is installed
- Disables Zincati auto upgrade/reboot service
- Enables staging of automatic system updates via rpm-ostreed
- Enables password based SSH auth (required for locally running cockpit web interface)
- Provides public key allowing [SecureBoot](#secureboot) (for ucore signed `nvidia` or `zfs` drivers)

Note: per [cockpit instructions](https://cockpit-project.org/running.html#coreos) the cockpit-ws RPM is **not** installed, rather it is provided as a pre-defined systemd service which runs a podman container.

### `ucore`

This image builds on `ucore-minimal` but adds drivers, storage tools and utilities making it more useful on bare metal or as a storage server (NAS).

- Starts with a [`ucore-minimal`](#ucore-minimal) image providing everything above, plus:
- Adds the following:
  - [cockpit-storaged](https://cockpit-project.org) (udisks2 based storage management)
  - [distrobox](https://github.com/89luca89/distrobox) - a [toolbox](https://containertoolbx.org/) alternative
  - [duperemove](https://github.com/markfasheh/duperemove)
  - all wireless (wifi) card firmwares (CoreOS does not include them) - hardware enablement FTW
  - [mergerfs](https://github.com/trapexit/mergerfs)
  - nfs-utils - nfs utils including daemon for kernel NFS server
  - [pcp](https://pcp.io) Performance Co-pilot monitoring
  - [rclone](https://www.rclone.org/) - file synchronization and mounting of cloud storage
  - [samba](https://www.samba.org/) and samba-usershares to provide SMB sevices
  - [snapraid](https://www.snapraid.it/)
  - usbutils(and pciutils) - technically pciutils is pulled in by open-vm-tools in ucore-minimal

### `ucore-hci`

Hyper-Coverged Infrastructure(HCI) refers to storage and hypervisor in one place... This image primarily adds libvirt tools for virtualization.

- Starts with a [`ucore`](#ucore) image providing everything above, plus:
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

### SELinux Troubleshooting

SELinux is an integral part of the Fedora Atomic system design. Due to a few interelated issues, if SELinux is disabled, it's difficult to re-enable.

**We STRONGLY recommend: DO NOT DISABLE SELinux!**

Should you suspect that SELinux is causing a problem, it is easy to enable permissive mode at runtime, which will keep SELinux functioning, provide reporting of problems, but not enforce restrictions.

```bash
# setenforce 0
$ getenforce
Permissive
```

After the problem is resolved, don't forget to re-enable:

```bash
# setenforce 1
$ getenforce
Enforcing
```

Fedora provides useful docs on [SELinux troubleshooting](https://docs.fedoraproject.org/en-US/quick-docs/selinux-troubleshooting/).

### Docker/Moby and Podman

NOTE: CoreOS [cautions against](https://docs.fedoraproject.org/en-US/fedora-coreos/faq/#_can_i_run_containers_via_docker_and_podman_at_the_same_time) running podman and docker containers at the same time.  Thus, `docker.socket` is disabled by default to prevent accidental activation of the docker daemon, given podman is the default.

### Podman and FirewallD

Podman and firewalld [can sometimes conflict](https://github.com/ublue-os/ucore/issues/90) such that a `firewall-cmd --reload` removes firewall rules generated by podman.

As of [netavark v1.9.0](https://blog.podman.io/2023/11/new-netavark-firewalld-reload-service/) a service is provided to handle re-adding netavark (Podman) firewall rules after a firewalld reload occurs.  If needed, enable like so: `systemctl enable netavark-firewalld-reload.service`


### Distrobox

Users may use [distrobox](https://github.com/89luca89/distrobox) to run images of mutable distributions where applications can be installed with traditional package managers. This may be useful for installing interactive utilities such has `htop`, `nmap`, etc. As stated above, however, *services* should run as containers.

### CoreOS and ostree Docs

It's a good idea to become familar with the [Fedora CoreOS Documentation](https://docs.fedoraproject.org/en-US/fedora-coreos/) as well as the [CoreOS rpm-ostree docs](https://coreos.github.io/rpm-ostree/). Note especially, this image is only possible due to [ostree native containers](https://coreos.github.io/rpm-ostree/container/).

### NAS - Storage

`ucore` includes a few packages geared towards a storage server which will require individual research for configuration:
  - [duperemove](https://github.com/markfasheh/duperemove)
  - [mergerfs](https://github.com/trapexit/mergerfs)
  - [snapraid](https://www.snapraid.it/)

But two others are included, which though common, warrant some explanation:
  - nfs-utils - replaces a "light" version typically in CoreOS to provide kernel NFS server
  - samba and samba-usershares - to provide SMB sevices

#### NFS

It's suggested to read Fedora's [NFS Server docs](https://docs.fedoraproject.org/en-US/fedora-server/services/filesharing-nfs-installation/) plus other documentation to understand how to setup this service. But here's a few quick tips...

##### Firewall

Unless you've disabled `firewalld`, you'll need to do this:

```bash
sudo firewall-cmd --permanent --zone=FedoraServer --add-service=nfs
sudo firewall-cmd --reload
```

##### SELinux

By default, nfs-server is blocked from sharing directories unless the context is set. So, generically to enable NFS sharing in SELinux run:

For read-only NFS shares:
```bash
sudo semanage fcontext --add --type "public_content_t" "/path/to/share/ro(/.*)?
sudo restorecon -R /path/to/share/ro
```

For read-write NFS shares:
```bash
sudo semanage fcontext --add --type "public_content_rw_t" "/path/to/share/rw(/.*)?
sudo restorecon -R /path/to/share/rw
```

Say you wanted to share all home directories:
```bash
sudo semanage fcontext --add --type "public_content_rw_t" "/var/home(/.*)?
sudo restorecon -R /var/home
```

The least secure but simplest way to let NFS share anything configured, is...

For read-only:
```bash
sudo setsebool -P nfs_export_all_ro 1
```

For read-write:
```bash
sudo setsebool -P nfs_export_all_rw 1
```

There is [more to read](https://linux.die.net/man/8/nfs_selinux) on this topic.

##### Shares

NFS shares are configured in `/etc/exports` or `/etc/exports.d/*` (see docs).

##### Run It

Like all services, NFS needs to be enabled and started:

```bash
sudo systemctl enable --now nfs-server.service
sudo systemctl status nfs-server.service
```

#### Samba

It's suggested to read Fedora's [Samba docs](https://docs.fedoraproject.org/en-US/quick-docs/samba/) plus other documentation to understand how to setup this service. But here's a few quick tips...

##### Firewall

Unless you've disabled `firewalld`, you'll need to do this:

```bash
sudo firewall-cmd --permanent --zone=FedoraServer --add-service=samba
sudo firewall-cmd --reload
```

##### SELinux

By default, samba is blocked from sharing directories unless the context is set. So, generically to enable samba sharing in SELinux run:

```bash
sudo semanage fcontext --add --type "samba_share_t" "/path/to/share(/.*)?
sudo restorecon -R /path/to/share
```

Say you wanted to share all home directories:
```bash
sudo semanage fcontext --add --type "samba_share_t" "/var/home(/.*)?
sudo restorecon -R /var/home
```

The least secure but simplest way to let samba share anything configured, is this:
```bash
sudo setsebool -P samba_export_all_rw 1
```

There is [much to read](https://linux.die.net/man/8/samba_selinux) on this topic.

##### Shares

Samba shares can be manually configured in `/etc/samba/smb.conf` (see docs), but user shares are also a good option.

An example follows, but you'll probably want to read some docs on this, too:
```bash
net usershare add sharename /path/to/share [comment] [user:{R|D|F}] [guest_ok={y|n}]
```

##### Run It

Like all services, Samba needs to be enabled and started:

```bash
sudo systemctl enable --now smb.service
sudo systemctl status smb.service
```

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

```bash
echo zfs > /etc/modules-load.d/zfs.conf
```

#### ZFS and immutable root filesystem

The default mountpoint for any newly created zpool `tank` is `/tank`. This is a problem in CoreOS as the root filesystem (`/`) is immutable, which means a directory cannot be created as a mountpoint for the zpool. An example of the problem looks like this:

```bash
# zpool create tank /dev/sdb
cannot mount '/tank': failed to create mountpoint: Operation not permitted
```

To avoid this problem, always create new zpools with a specified mountpoint:

```bash
# zpool create -m /var/tank tank /dev/sdb
```

If you do forget to specify the mountpoint, or you need to change the mountpoint on an existing zpool:

```bash
# zfs set mountpoint=/var/tank tank
```

### Sanoid/Syncoid

sanoid/syncoid is a great tool for manual and automated snapshot/transfer of ZFS datasets. However, there is not a current stable RPM, rather they provide [instructions on installing via git](https://github.com/jimsalterjrs/sanoid/blob/master/INSTALL.md#centos).

`ucore` has pre-install all the (lightweight) required dependencies (perl-Config-IniFiles perl-Data-Dumper perl-Capture-Tiny perl-Getopt-Long lzop mbuffer mhash pv), such that a user wishing to use sanoid/syncoid only need install the "sbin" files and create configuration/systemd units for it.

### SecureBoot

For those wishing to use `nvidia` or `zfs` images with pre-built kmods AND run SecureBoot, the kernel will not load those kmods until the public signing key has been imported as a MOK (Machine-Owner Key).

Do so like this:
```bash
sudo mokutil --import /etc/pki/akmods/certs/akmods-ublue.der
```

The utility will prompt for a password. The password will be used to verify this key is the one you meant to import, after rebooting and entering the UEFI MOK import utility.


## How to Install

### Prerequisites

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
| [`ucore-minimal`](#ucore-minimal) - *stable* | `stable`, `stable-nvidia`, `stable-zfs`,`stable-nvidia-zfs` |
| [`ucore-mimimal`](#ucore-minimal) - *testing* | `testing`, `testing-nvidia`, `testing-zfs`, `testing-nvidia-zfs` |
| [`ucore`](#ucore) - *stable* | `stable`, `stable-nvidia`, `stable-zfs`,`stable-nvidia-zfs` |
| [`ucore`](#ucore) - *testing* | `testing`, `testing-nvidia`, `testing-zfs`, `testing-nvidia-zfs` |
| [`ucore-hci`](#ucore-hci) - *stable* | `stable`, `stable-nvidia`, `stable-zfs`,`stable-nvidia-zfs` |
| [`ucore-hci`](#ucore-hci) - *testing* | `testing`, `testing-nvidia`, `testing-zfs`, `testing-nvidia-zfs` |


#### Verified Image Updates

This image now includes container policies to support image verification for improved trust of upgrades. Once running one of the `ucore*` images (not included in `fedora-coreos`), the following command will rebase to the verified image reference:

```bash
sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/ublue-os/IMAGE:TAG
```


### Install with Auto-Rebase

Your path to a running uCore can be shortened by using [examples/ucore-autorebase.butane](examples/ucore-autorebase.butane) as the starting point for your CoreOS ignition file.

1. As usual, you'll need to [follow the docs to setup a password](https://coreos.github.io/butane/examples/#using-password-authentication). Substitute your password hash for `YOUR_GOOD_PASSWORD_HASH_HERE` in the `ucore-autorebase.butane` file, and add your ssh pub key while you are at it.
1. Generate an ignition file from your new `ucore-autorebase.butane` [using the butane utility](https://coreos.github.io/butane/getting-started/).
1. Now install CoreOS for [hypervisor, cloud provider or bare-metal](https://docs.fedoraproject.org/en-US/fedora-coreos/bare-metal/). Your ignition file should work for any platform, auto-rebasing to the `ucore:stable` (or other `IMAGE:TAG` combo), rebooting and leaving your install ready to use.

## Verification

These images are signed with sigstore's [cosign](https://docs.sigstore.dev/cosign/overview/). You can verify the signature by downloading the `cosign.pub` key from this repo and running the following command:

```bash
cosign verify --key cosign.pub ghcr.io/ublue-os/ucore
```

## Metrics

![Alt](https://repobeats.axiom.co/api/embed/07d1ed133f5ed1a1048ea6a76bfe3a23227eedd5.svg "Repobeats analytics image")
