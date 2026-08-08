# Local VM Testing

`vm-test.sh` verifies that a uCore image can be deployed with `bootc`, boot
successfully, and preserve system state across another reboot. It runs QEMU
directly as the current user and does not require host `root` or `sudo`.

## Requirements

The host must be an x86-64 Linux system with:

- Read and write access to `/dev/kvm`
- Rootless Podman
- QEMU and `qemu-img`
- OVMF from the `edk2` package
- `jq`, `curl`, `xz`, `ssh`, `ssh-keygen`, `flock`, `sha256sum`, and `ss`
- At least 4 GiB of memory and enough storage for the FCOS cache, container
  images, and a sparse 40 GiB virtual disk with the defaults

Direct testing additionally requires [`bcvk`](https://github.com/bootc-dev/bcvk)
version 0.18 or newer and `virtiofsd`. `virtiofsd` is packaged separately on Fedora, Fedora CoreOS,
uCore, Debian, Snow, and Cayo hypervisor hosts. Set `VIRTIOFSD_BIN` when it is
installed outside bcvk's normal search paths.

Access to `/dev/kvm` is commonly granted through membership in the `kvm`
group. Installing packages or changing group membership may require an
administrator, but running the test does not.

## Basic Usage

Run the test from the `ucore` directory and provide a source image followed by
the target image:

```bash
just vm-test SOURCE_IMAGE TARGET_IMAGE
```

The usual Fedora CoreOS to uCore test is:

```bash
just vm-test \
  quay.io/fedora/fedora-coreos:stable \
  ghcr.io/ublue-os/ucore-minimal:stable
```

To test an upgrade between two uCore images:

```bash
just vm-test \
  ghcr.io/ublue-os/ucore-minimal:stable-20250101 \
  ghcr.io/ublue-os/ucore-minimal:stable
```

## Direct Image Testing

For faster testing of one uCore image, use direct mode:

```bash
just vm-test-direct ghcr.io/ublue-os/ucore-minimal:stable
```

This is useful for `ucore-minimal`, `ucore`, and locally built or downstream
uCore images already available in host Podman storage. Direct mode does not
boot FCOS first and does not run `bootc switch`; it is a testing shortcut, not
a replacement for the documented FCOS install/switch workflow.

Direct mode uses rootless bcvk to run an installer VM. bcvk creates a
privileged container under the current user's rootless Podman account, so host
`root` and `sudo` are still not required. The script creates a temporary
FCOS-compatible disk with these partitions:

- 1 MiB BIOS boot partition
- 127 MiB EFI System Partition
- 384 MiB ext4 `/boot` partition
- XFS root partition using the remaining space

It installs with `bootc install to-filesystem`, using the generated root and
boot filesystem UUIDs. It injects its temporary SSH key with
`--root-ssh-authorized-keys`, so direct-mode guest checks connect as `root`
rather than the FCOS `core` user. The installer VM receives a swap device and
a disk-sized `/var/tmp` tmpfs to hold imported image layers.

In direct mode, the image under test has two roles: bcvk boots it as the
installer VM, and `bootc install` installs the same image onto the temporary
target disk. Therefore, the image must be bootable by bcvk and include `bootc`,
`sgdisk`, `blockdev`, `udevadm`, `mkfs.vfat`, `mkfs.ext4`, `mkfs.xfs`, `blkid`,
`mount`, and `umount`. Direct mode reports any missing installer tool before
partitioning the disk.

The script always starts from an official Fedora CoreOS QEMU disk. The disk is
used directly as the source deployment only for these exact references:

- `quay.io/fedora/fedora-coreos:stable`
- `quay.io/fedora/fedora-coreos:testing`
- `quay.io/fedora/fedora-coreos:next`

Each reference selects the matching CoreOS stream. If an explicitly configured
`VM_TEST_FCOS_STREAM` conflicts with that source stream, the test exits rather
than silently booting a different source.

When any other source image is provided, including a pinned FCOS tag or digest,
a registry mirror, or a custom image with `fedora-coreos` in its name, the
script follows this sequence:

1. Boot the Fedora CoreOS bootstrap disk.
2. Switch to and boot `SOURCE_IMAGE`.
3. Switch to and boot `TARGET_IMAGE`.
4. Reboot `TARGET_IMAGE` a second time.

Source and target images already present in host Podman storage can be used
without publishing them. The script first tries to pull the host-resolved
digest inside the guest. If that digest is not available from a registry, it
transfers the host image into the guest with `podman save` and `podman load`.

## Validation

The test checks:

- The staged image is the image that boots
- The rollback deployment matches the previous deployment
- The target reports `VARIANT_ID=ucore`
- The running kernel has its module directory
- Podman works inside the guest
- DNS resolution and outbound HTTPS connectivity work
- systemd reaches `running` or `degraded` within the boot timeout
- No new critical systemd units fail
- Files under `/etc` and `/var` persist
- The machine ID remains unchanged
- Every SSH host key type and fingerprint remains unchanged
- The same checks still pass after a second target reboot

For images with the `swtpm` package, the test also verifies the `swtpm`,
`swtpm_svirt`, and `swtpm_libvirt` SELinux modules are installed at priority
200, `/usr/bin/swtpm` resolves and is labeled `swtpm_exec_t`, and no bind mount
masks that deployed file. These checks run on both target boots.

Direct mode validates the installed image digest on both boots and performs
the same health, networking, identity, SSH-key, and persistence checks. It
does not assert a rollback deployment because no `bootc switch` occurs.

## Configuration

The following environment variables are optional:

| Variable | Default | Purpose |
| --- | --- | --- |
| `VM_TEST_CPUS` | `2` | Number of virtual CPUs |
| `VM_TEST_MEMORY` | `4096` | Guest memory in MiB |
| `VM_TEST_DISK_SIZE` | `40G` | Virtual disk size |
| `VM_TEST_BOOT_TIMEOUT` | `300` | Seconds to wait for SSH and systemd after a boot |
| `VM_TEST_SHUTDOWN_TIMEOUT` | `120` | Seconds to wait for SSH to stop during reboot |
| `VM_TEST_SSH_PORT` | `2222` | Unprivileged host port forwarded to guest SSH |
| `VM_TEST_FCOS_CACHE` | `$XDG_CACHE_HOME/ucore-vm-test/fcos` | Fedora CoreOS image cache |
| `VM_TEST_FCOS_STREAM` | Direct SOURCE stream or `stable` | Bootstrap stream; must match SOURCE only for direct stream references |
| `VM_TEST_KEEP` | Unset | Keep the work directory and running VM when nonempty |
| `VIRTIOFSD_BIN` | bcvk search paths | Path to `virtiofsd` for direct mode |

`VM_TEST_CPUS` and `VM_TEST_MEMORY` apply to both the bcvk installer VM and
the booted test VM in direct mode.

For example:

```bash
VM_TEST_CPUS=4 VM_TEST_MEMORY=8192 VM_TEST_SSH_PORT=2223 \
  just vm-test SOURCE_IMAGE TARGET_IMAGE
```

Set `VM_TEST_KEEP=1` to inspect the guest after the test. The script prints the
SSH command and QEMU process ID before exiting.

## Files Left Behind

### Successful Run

With the default configuration, QEMU is stopped and the temporary
`/var/tmp/ucore-vm-test.*` work directory is removed. The following persistent
host state remains:

- Verified Fedora CoreOS images under
  `$XDG_CACHE_HOME/ucore-vm-test/fcos`, or `~/.cache/ucore-vm-test/fcos` when
  `XDG_CACHE_HOME` is unset
- The cache lock file named `.lock`
- An empty SSH port lock file under `$XDG_RUNTIME_DIR`, or under
  `~/.cache/ucore-vm-test` when `XDG_RUNTIME_DIR` is unset
- Source or target images that the script pulled into host Podman storage
- A temporary `localhost/ucore-vm-test-install:*` image tag while a direct-mode
  run is active; it is removed during normal cleanup and retained with
  `VM_TEST_KEEP`

Lock files remain on disk, but their locks are released when the script exits.
Cached Fedora CoreOS versions and host Podman images are not automatically
pruned.

### Failed Run

QEMU is stopped by default, but the work directory is retained for debugging.
Depending on how early the failure occurred, it may contain:

```text
/var/tmp/ucore-vm-test.XXXXXX/
|-- disk.qcow2
|-- OVMF_VARS.qcow2
|-- config.ign
|-- id_ed25519
|-- id_ed25519.pub
|-- console.log
|-- qemu.pid
|-- direct.qcow2
|-- direct-install.sh
`-- installer/
    |-- console.txt
    |-- install.log
    |-- journal.json
`-- diagnostics/
    |-- bootc-status.json
    |-- failed-units.txt
    |-- journal-boot.txt
    |-- journal-boot-minus-1.txt
    |-- os-release.txt
    |-- uname.txt
    `-- console-tail.txt
```

Some diagnostic files may be empty when the failure occurred before SSH was
available. If the test fails before its work directory is created, diagnostics
are written to `/var/tmp/ucore-vm-test-diagnostics.XXXXXX` instead.

The retained directory contains a private SSH key and a writable VM disk. Keep
its existing permissions and remove the directory when it is no longer needed.

### `VM_TEST_KEEP`

When `VM_TEST_KEEP` is nonempty, both successful and failed runs leave QEMU
running and retain the complete work directory. Stop the recorded QEMU process
before deleting that directory.

### Interrupted Run

An uncatchable termination such as `SIGKILL` can bypass normal cleanup. It may
leave a running QEMU process, a work directory under `/var/tmp`, or a
`.download.*` directory in the Fedora CoreOS cache. Check the recorded
`qemu.pid` before removing files from an interrupted run.
