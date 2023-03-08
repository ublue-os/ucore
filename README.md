# ucore-main

[![build-ucore](https://github.com/bsherman/ucore-main/actions/workflows/build.yml/badge.svg)](https://github.com/bsherman/ucore-main/actions/workflows/build.yml)

A WIP common main image for all other Ucore images.

## What is this?

This is an OCI base image of [Fedora CoreOS](https://getfedora.org/coreos/) with quality of life improvments.


## Features

- Start with Fedora CoreOS image
- add some packages:
  - cockpit
  - distrobox
  - docker-compose & podman-compose
  - duperemove
  - tailscale and wireguard-tools
- remove some packages:
  - tookbox
  - zincati
- Sets automatic staging of updates for system
- 60 second service stop timeout for reasonably fast shutdowns


## Usage

To rebase an Fedora CoreOS machine to the latest release (stable):

    sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/bsherman/ucore-main:stable

  
## Verification

These images are signed with sisgstore's [cosign](https://docs.sigstore.dev/cosign/overview/). You can verify the signature by downloading the `cosign.pub` key from this repo and running the following command:

    cosign verify --key cosign.pub ghcr.io/bsherman/ucore-main