# Expectations

uCore is a volunteer-run project. The images are built on Fedora CoreOS and add
packages from Fedora, a few other repositories, and a small number of upstream
GitHub releases. uCore does not patch or version-bump those packages itself.
Images build daily, so an update published upstream reaches uCore in the next
build after it lands.

The kernel and the ZFS and NVIDIA kernel modules are the exception. They come
from [ublue-os/akmods](https://github.com/ublue-os/akmods), which caches the
kernel and builds the modules against it. The kernel is version-locked to that
cache, so kernel updates follow akmods rather than the Fedora CoreOS release.

# Vulnerability Scanner Findings

Container scanner reports (Grype, Trivy, Syft, and similar) about packaged
software are **not actionable in this repository**. In particular:

- Go binaries embed their dependencies (for example `golang.org/x/crypto`).
  Only a rebuild of the package by its maintainer can update them.
- Distro-built Go binaries often report pseudo-versions that do not match the
  packaged version, which produces false positives.

Before opening an issue:

1. Check the installed package version on a current image:

   ```bash
   podman run --rm ghcr.io/ublue-os/ucore:stable rpm -q <package>
   ```

2. Check whether Fedora already has an update pending in
   [Bodhi](https://bodhi.fedoraproject.org/).
3. If the package is still affected, report it to where it comes from:
   - Fedora packages: [Fedora Bugzilla](https://bugzilla.redhat.com/)
   - Kernel, ZFS, or NVIDIA modules: [ublue-os/akmods](https://github.com/ublue-os/akmods/issues)
   - Other third-party packages: the upstream project that publishes them

Issues containing only scanner output will be closed with a link to this
document.

# What uCore Is Responsible For

Report security issues in things uCore owns:

- Build scripts, Containerfiles, and CI workflows in this repository
- Configuration files and systemd units that uCore adds to the image
- Image signing and publishing
- The choice and version pinning of packages uCore installs from outside Fedora

# Security Response

To disclose an issue in uCore confidentially, use
[GitHub private vulnerability reporting](https://github.com/ublue-os/ucore/security/advisories/new).

For issues in Fedora CoreOS or Fedora packages, follow the
[CoreOS security policy](https://github.com/coreos/.github/blob/master/SECURITY.md)
and contact [Red Hat Product Security](https://access.redhat.com/security/team/contact).

# License

Most repositories are licensed under the Apache License, Version 2.0. Some
components may be licensed differently; consult individual repositories for
details.
