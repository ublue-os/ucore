# uCore

[![lts](https://github.com/ublue-os/ucore/actions/workflows/build-lts.yml/badge.svg)](https://github.com/ublue-os/ucore/actions/workflows/build-lts.yml)
[![stable](https://github.com/ublue-os/ucore/actions/workflows/build-stable.yml/badge.svg)](https://github.com/ublue-os/ucore/actions/workflows/build-stable.yml)
[![testing](https://github.com/ublue-os/ucore/actions/workflows/build-testing.yml/badge.svg)](https://github.com/ublue-os/ucore/actions/workflows/build-testing.yml)

uCore is a set of Fedora CoreOS-based server images for container hosting, storage, and virtualization.

**Visit [projectucore.org](https://projectucore.org/) for image selection, installation instructions, operating guides, and announcements.**

## Get started

- [Choose an image and tag](https://projectucore.org/docs/images/)
- [Install uCore](https://projectucore.org/docs/first-install/)
- [Switch an existing system to uCore](https://projectucore.org/docs/rebasing/)
- [Browse the documentation](https://projectucore.org/docs/)
- [Read project announcements](https://projectucore.org/announcements/)

## Builds and releases

Images are published to `ghcr.io/ublue-os`. See [GitHub Releases](https://github.com/ublue-os/ucore/releases) for generated stream changelogs and [Verification and build transparency](https://projectucore.org/docs/verification/) for image signatures, package provenance, and SBOMs.

- [Build workflows](.github/workflows/)
- [Image build recipes](ucore/Containerfile.in) and [package installation scripts](ucore/)
- [Build commands and checks](ucore/Justfile)

## Contributing

Run the repository checks from `ucore/` with `just check`. Report bugs and request features in [GitHub Issues](https://github.com/ublue-os/ucore/issues). See the [roadmap](ROADMAP.md), [security policy](SECURITY.md), and [license](LICENSE).
