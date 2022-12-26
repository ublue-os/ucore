# Serverblue

[![build-serverblue](https://github.com/kylegospo/serverblue/actions/workflows/build.yml/badge.svg)](https://github.com/kylegospo/serverblue/actions/workflows/build.yml)

Serverblue is an OCI based off of [Fedora CoreOS](https://getfedora.org/coreos/) that is tuned for use as a home & small server operating system.

### The maintainers of the Serverblue project are not liable for any damage that may occur during use of the operating system.

## Usage

Warning: This is an experimental feature and should not be used in production, try it in a VM for a while, you have been warned!

    sudo rpm-ostree rebase --experimental --bypass-driver ostree-unverified-registry:ghcr.io/kylegospo/serverblue:latest
    
We build date tags as well, so if you want to rebase to a particular day's release:
  
    sudo rpm-ostree rebase --experimental --bypass-driver ostree-unverified-registry:ghcr.io/kylegospo/serverblue:20221217 

The `latest` tag will automatically point to the latest build. 
  
## Verification

These images are signed with sisgstore's [cosign](https://docs.sigstore.dev/cosign/overview/). You can verify the signature by downloading the `cosign.pub` key from this repo and running the following command:

    cosign verify --key cosign.pub ghcr.io/kylegospo/serverblue