# uCore Roadmap

**Now** is what we're committed to and actively prioritizing. **Later** is
exploration — the general direction we hope to go, not yet a commitment.

## Now

### Goal: CI hardening

Harden the build and release pipeline before it grows more publish paths
(more on that below).

- **Sandbox end-to-end publication testing** ([#414](https://github.com/ublue-os/ucore/issues/414)) —
  a manual, isolated way to rehearse the full publish path (multi-arch
  manifests, signing, SBOM, changelogs) without touching real release
  streams.

## Later

We're also exploring using [systemd-sysext](https://www.freedesktop.org/software/systemd/man/latest/systemd-sysext.html)
to make NVIDIA and libvirt support optional add-ons instead of baked
into every image variant, which would significantly shrink the number of
image tags we publish. This is still in the design/spike stage — follow
along via the linked issues above and future announcements once there's
something concrete to commit to.

## Completed

### August 2026

- **Emergency CoreOS pin** ([#413](https://github.com/ublue-os/ucore/issues/413)) —
  documented in `just stream-info`: when a Fedora CoreOS release is known-bad,
  pin `IMAGE_VERSION` in that recipe so nightlies and PRs stay off it.
- **Verify checksums for CI dependencies** ([#367](https://github.com/ublue-os/ucore/issues/367)) —
  pin and checksum-verify the build tooling and signing keys the pipeline
  fetches at build time, the same way package manifests already are.

### September 2026

- **Launch [projectucore.org](https://projectucore.org/)** — the project now has
  a home for image selection, installation and operating guides, and
  announcements. The site has its own
  visual identity, while generated changelogs, SBOMs, and build provenance
  remain in the repository. GitHub Issues stay focused on actionable bugs and
  feature work; community questions and discussion go to the [Universal Blue
  Discord](https://discord.gg/pPyP5hvJ2) and [Discourse](https://universal-blue.discourse.group/).
