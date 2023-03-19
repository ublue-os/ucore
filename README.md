# uCore

[![build-ucore](https://github.com/ublue-os/ucore/actions/workflows/build.yml/badge.svg)](https://github.com/ublue-os/ucore/actions/workflows/build.yml)

## What is this?

You should be familiar with [Fedora CoreOS](https://getfedora.org/coreos/), as this is an OCI image of CoreOS with "batteries included". More specifically, it's an opinionated, custom CoreOS image, built daily with some commonly used tools added in. The idea is to make a lightweight server image including most used services or the building blocks to host them.

WARNING: This image has **not** been heavily tested, though the underlying components have. Please take a look at the included modifications and help test if this project interests you.

## Features

- Starts with a [Fedora CoreOS image](https://quay.io/repository/fedora/fedora-coreos?tab=tags)
- Removes these stock packages:
  - toolbox
  - zincati
- Adds the following:
  - [cockpit](https://cockpit-project.org)
  - [distrobox](https://github.com/89luca89/distrobox)
  - [duperemove](https://github.com/markfasheh/duperemove)
  - moby-engine, docker-compose and podman-compose
  - [tailscale](https://tailscale.com) and [wireguard-tools](https://www.wireguard.com)
- Sets automatic staging of updates for system
- Sets 60 second service stop timeout for reasonably fast shutdowns
- Enables password based SSH auth (required for locally running cockpit web interface)

One can layer packages directly on a machine running uCore or use this image as a base for further customized OCI builds.

Note: per [cockpit instructions](https://cockpit-project.org/running.html#coreos) the cockpit-ws RPM is **not** installed, rather it is available as a podman container. This image has pre-configured cockpit to run on system boot, but it can be disabled:

```bash
sudo systemctl disable --now cockpit.service
```

This image should be suitable for use on bare metal or on virtual machines where you wish to run containerized workloads.

## Tips and Tricks

These images are immutable, you can't, and really shouldn't, install packages like in a mutable "normal" distribution.

CoreOS expects the user to run services using [podman](https://podman.io). `moby-engine`, the free Docker implementation, is installed for those who desire docker instead of podman.

NOTE: CoreOS [cautions against](https://docs.fedoraproject.org/en-US/fedora-coreos/faq/#_can_i_run_containers_via_docker_and_podman_at_the_same_time) running podman and docker containers at the same time.

Users may use [distrobox](https://github.com/89luca89/distrobox) to run images of mutable distributions where applications can be installed with traditional package managers. This may be useful for installing interactive utilities such has `htop`, `nmap`, etc. As stated above, however, *services* should run as containers.

It's a good idea to become familar with the [Fedora CoreOS Documentation](https://docs.fedoraproject.org/en-US/fedora-coreos/) as well as the [CoreOS rpm-ostree docs](https://coreos.github.io/rpm-ostree/). Note especially, this image is only possible due to [ostree native containers](https://coreos.github.io/rpm-ostree/container/).

## How to Install

### Prerequsites

This image is not currently avaialable for direct install. The user must follow the [CoreOS installation guide](https://docs.fedoraproject.org/en-US/fedora-coreos/bare-metal/). There are varying methods of installation for bare metal, cloud providers, and virtualization platforms.

All CoreOS installation methods require the user to [produce an Ignition file](https://docs.fedoraproject.org/en-US/fedora-coreos/producing-ign/). This Ignition file should, at mimimum, set a password and SSH key for the default user (default username is `core`).

### Install and Rebase

To rebase an Fedora CoreOS machine to the latest uCore (stable):

1. Install CoreOS via [desired installation method](https://docs.fedoraproject.org/en-US/fedora-coreos/bare-metal/)
1. After you reboot you should [pin the working deployment](https://docs.fedoraproject.org/en-US/fedora-silverblue/faq/#_how_can_i_upgrade_my_system_to_the_next_major_version_for_instance_rawhide_or_an_upcoming_fedora_release_branch_while_keeping_my_current_deployment) which allows you to rollback if required.
1. SSH to the freshly installed CoreOS system and rebase the OS, then reboot:

```bash
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/ublue-os/ucore:stable
```

## Verification

These images are signed with sisgstore's [cosign](https://docs.sigstore.dev/cosign/overview/). You can verify the signature by downloading the `cosign.pub` key from this repo and running the following command:

```bash
cosign verify --key cosign.pub ghcr.io/ublue-os/ucore
```
