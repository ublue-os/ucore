#!/usr/bin/env bash
# Verify a ucore image can boot on a VM and survive a reboot.
#
# By default, boots an official Fedora CoreOS QEMU image (the recommended
# starting point for uCore), uses it directly for canonical FCOS stream
# sources or bootc-switches to any other SOURCE_IMAGE, then switches to
# TARGET_IMAGE and validates health and persistence through a second ordinary
# reboot.  The --direct mode instead installs one uCore image to a temporary
# FCOS-compatible disk through bcvk for faster image-specific testing.
#
# Usage:  ./vm-test.sh SOURCE_IMAGE TARGET_IMAGE
#         ./vm-test.sh --direct IMAGE
# Documentation: vm-test.md
#
# Examples:
#   # Recommended path: FCOS -> uCore
#   ./vm-test.sh \
#     quay.io/fedora/fedora-coreos:stable \
#     ghcr.io/ublue-os/ucore-minimal:stable
#
#   # Older uCore -> newer uCore (via FCOS first boot)
#   ./vm-test.sh \
#     ghcr.io/ublue-os/ucore-minimal:stable-20250101 \
#     ghcr.io/ublue-os/ucore-minimal:stable
#
#   # Direct image-specific test (not the recommended install workflow)
#   ./vm-test.sh --direct ghcr.io/ublue-os/ucore-minimal:stable
#
# Direct mode deliberately does not use `bootc install to-disk`: FCOS needs a
# separate /boot partition, while to-disk creates only an ESP and rootfs.  It
# instead provisions the FCOS-compatible GPT layout and uses to-filesystem.
#
# Environment (all optional):
#   VM_TEST_CPUS              vCPUs (default 2)
#   VM_TEST_MEMORY            Memory in MiB (default 4096)
#   VM_TEST_DISK_SIZE         Disk size e.g. 40G (default 40G)
#   VM_TEST_BOOT_TIMEOUT      Seconds to wait for SSH after boot (default 300)
#   VM_TEST_SHUTDOWN_TIMEOUT  Seconds to wait for SSH to go down (default 120)
#   VM_TEST_KEEP              If non-empty, retain work dir + VM on exit
#   VM_TEST_SSH_PORT          Host port for SSH forward (default 2222)
#   VM_TEST_FCOS_CACHE        Dir for cached FCOS qemu image
#                             (default $XDG_CACHE_HOME/ucore-vm-test/fcos)
#   VM_TEST_FCOS_STREAM       CoreOS bootstrap stream (default direct SOURCE
#                             stream, otherwise stable; conflicts are rejected)
#   VIRTIOFSD_BIN              Path to virtiofsd for --direct (optional)
#
# Prerequisites: Linux, /dev/kvm, podman, jq, curl, xz, qemu-system-x86_64,
#   qemu-img, OVMF (edk2), ssh, ssh-keygen, flock, sha256sum, ss.
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
: "${VM_TEST_CPUS:=2}"
: "${VM_TEST_MEMORY:=4096}"
: "${VM_TEST_DISK_SIZE:=40G}"
: "${VM_TEST_BOOT_TIMEOUT:=300}"
: "${VM_TEST_SHUTDOWN_TIMEOUT:=120}"
: "${VM_TEST_KEEP:=}"
: "${VM_TEST_SSH_PORT:=2222}"
: "${VM_TEST_FCOS_CACHE:=${XDG_CACHE_HOME:-$HOME/.cache}/ucore-vm-test/fcos}"
VM_TEST_FCOS_STREAM_EXPLICIT=${VM_TEST_FCOS_STREAM+x}
: "${VM_TEST_FCOS_STREAM:=stable}"

WORK_DIR=""
SSH_KEY=""
QEMU_PID=""
QEMU_CONSOLE_LOG=""
DISK_IMAGE=""
BCVK_CONTAINER=""
FCOS_QEMU_SHA256=""
BOOT_ID=""
MACHINE_ID=""
SOURCE_DIGEST=""
STAGED_DIGEST=""
FAIL_COUNT=0
SSH_USER="core"
DIRECT_MODE=0
DIRECT_REF=""
DIRECT_SOURCE_REF=""
HOST_DIRECT_DIGEST=""
HOST_DIRECT_ID=""
DIRECT_DISK=""
VIRTIOFSD_PATH=""
PORT_LOCK_FD=""
declare -A SSH_HOST_KEY_FPS=()
declare -A BASELINE_FAILED_UNITS=()

phase="init"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
# shellcheck disable=SC2317
cleanup() {
    local exit_code=$?
    if [[ "$exit_code" -ne 0 ]]; then
        collect_diagnostics || true
    fi
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        if [[ -z "$VM_TEST_KEEP" ]]; then
            kill "$QEMU_PID" 2>/dev/null || true
            local i=0
            while kill -0 "$QEMU_PID" 2>/dev/null && ((i++ < 20)); do sleep 0.5; done
            kill -9 "$QEMU_PID" 2>/dev/null || true
        else
            echo "VM_TEST_KEEP is set: QEMU PID $QEMU_PID still running" >&2
            echo "  ssh -i $SSH_KEY -p $VM_TEST_SSH_PORT ${SSH_USER}@localhost" >&2
        fi
    fi
    if [[ -n "$BCVK_CONTAINER" ]]; then
        if [[ -z "$VM_TEST_KEEP" ]]; then
            podman rm -f "$BCVK_CONTAINER" >/dev/null 2>&1 || true
        else
            echo "VM_TEST_KEEP is set: bcvk installer container $BCVK_CONTAINER retained" >&2
        fi
    fi
    if [[ -n "$DIRECT_SOURCE_REF" && -z "$VM_TEST_KEEP" ]]; then
        podman untag "$DIRECT_SOURCE_REF" "$DIRECT_SOURCE_REF" >/dev/null 2>&1 || true
    fi
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        if [[ -z "$VM_TEST_KEEP" && "$exit_code" -eq 0 ]]; then
            rm -rf "$WORK_DIR"
        else
            echo "Work dir retained: $WORK_DIR" >&2
            if [[ -n "${DIAG_DIR:-}" && -d "${DIAG_DIR:-}" ]]; then
                echo "Diagnostics: $DIAG_DIR" >&2
            fi
        fi
    fi
}

die() {
    echo "FATAL [$phase]: $*" >&2
    exit 1
}

collect_diagnostics() {
    local d
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        d="$WORK_DIR/diagnostics"
        mkdir -p "$d"
    else
        d="$(mktemp -d /var/tmp/ucore-vm-test-diagnostics.XXXXXX)"
    fi
    DIAG_DIR="$d"
    echo "Collecting diagnostics to $d" >&2
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        vm_root bootc status --format json >"$d/bootc-status.json" 2>/dev/null || true
        vm_root systemctl --failed --no-pager >"$d/failed-units.txt" 2>/dev/null || true
        vm_root journalctl -b --no-pager >"$d/journal-boot.txt" 2>/dev/null || true
        vm_root journalctl -b -1 --no-pager >"$d/journal-boot-minus-1.txt" 2>/dev/null || true
        vm_ssh cat /usr/lib/os-release >"$d/os-release.txt" 2>/dev/null || true
        vm_ssh uname -a >"$d/uname.txt" 2>/dev/null || true
    fi
    if [[ -n "$QEMU_CONSOLE_LOG" && -f "$QEMU_CONSOLE_LOG" ]]; then
        tail -c 256000 "$QEMU_CONSOLE_LOG" >"$d/console-tail.txt" 2>/dev/null || true
    fi
}

red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
pass_msg() { printf '  \033[32mok\033[0m  %s\n' "$*"; }
fail_msg() {
    red "  FAIL  $*"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# ---------------------------------------------------------------------------
# SSH helpers (core user + sudo for privileged commands)
# ---------------------------------------------------------------------------
# Run a remote shell command string (single argument to ssh).
ssh_cmd() {
    ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=5 \
        -o BatchMode=yes \
        -i "$SSH_KEY" \
        -p "$VM_TEST_SSH_PORT" \
        "${SSH_USER}@localhost" \
        "$@"
}

# Run argv as the unprivileged guest user.
vm_ssh() {
    local cmd
    printf -v cmd '%q ' "$@"
    ssh_cmd "$cmd"
}

# Run argv as root inside the guest.
vm_root() {
    local cmd
    printf -v cmd '%q ' "$@"
    if [[ "$SSH_USER" == root ]]; then
        ssh_cmd "$cmd"
    else
        ssh_cmd "sudo -n -- $cmd"
    fi
}

# Write a file as root via tee (avoids sudo redirect pitfalls).
vm_root_write() {
    local path="$1" content="$2"
    if [[ "$SSH_USER" == root ]]; then
        ssh_cmd "printf '%s\n' $(printf '%q' "$content") > $(printf '%q' "$path")"
    else
        ssh_cmd "printf '%s\n' $(printf '%q' "$content") | sudo -n tee $(printf '%q' "$path") >/dev/null"
    fi
}

wait_ssh_up() {
    local prior_boot_id="${1:-}"
    local deadline=$((SECONDS + VM_TEST_BOOT_TIMEOUT))
    echo "Waiting up to ${VM_TEST_BOOT_TIMEOUT}s for SSH on port ${VM_TEST_SSH_PORT}..."
    while ((SECONDS < deadline)); do
        local b
        if b=$(vm_ssh cat /proc/sys/kernel/random/boot_id 2>/dev/null); then
            if [[ -n "$b" ]]; then
                if [[ -z "$prior_boot_id" || "$b" != "$prior_boot_id" ]]; then
                    if [[ -n "$prior_boot_id" ]]; then
                        echo "SSH is available (boot_id changed)."
                    else
                        echo "SSH is available."
                    fi
                    return 0
                fi
            fi
        fi
        sleep 2
    done
    return 1
}

wait_ssh_down() {
    local deadline=$((SECONDS + VM_TEST_SHUTDOWN_TIMEOUT))
    echo "Waiting up to ${VM_TEST_SHUTDOWN_TIMEOUT}s for SSH to go down..."
    while ((SECONDS < deadline)); do
        if ! vm_ssh true 2>/dev/null; then
            echo "SSH is down."
            return 0
        fi
        sleep 2
    done
    echo "Warning: SSH did not go down within timeout (continuing)." >&2
}

read_boot_id() {
    BOOT_ID=$(vm_ssh cat /proc/sys/kernel/random/boot_id)
    [[ -n "$BOOT_ID" ]] || die "failed to read boot_id"
}

assert_eq() {
    local expected="$1" actual="$2" desc="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass_msg "$desc"
    else
        fail_msg "$desc"
        echo "        expected: '$expected'" >&2
        echo "        got:      '$actual'" >&2
    fi
}

assert_guest() {
    local desc="$1"
    shift
    if vm_ssh "$@" >/dev/null 2>&1; then
        pass_msg "$desc"
    else
        fail_msg "$desc"
        echo "        command failed: $*" >&2
    fi
}

assert_root() {
    local desc="$1"
    shift
    if vm_root "$@" >/dev/null 2>&1; then
        pass_msg "$desc"
    else
        fail_msg "$desc"
        if [[ "$SSH_USER" == root ]]; then
            echo "        command failed: $*" >&2
        else
            echo "        command failed: sudo -n -- $*" >&2
        fi
    fi
}

normalize_arch() {
    case "${1:-}" in
        amd64 | x86_64) echo "x86_64" ;;
        arm64 | aarch64) echo "aarch64" ;;
        *) echo "${1:-}" ;;
    esac
}

digest_ref() {
    local ref="${1%%@*}" digest="$2" last
    last=${ref##*/}
    if [[ "$last" == *:* ]]; then
        ref=${ref%:*}
    fi
    printf '%s@%s\n' "$ref" "$digest"
}

direct_fcos_stream() {
    case "$1" in
        quay.io/fedora/fedora-coreos:stable) printf '%s\n' stable ;;
        quay.io/fedora/fedora-coreos:testing) printf '%s\n' testing ;;
        quay.io/fedora/fedora-coreos:next) printf '%s\n' next ;;
        *) return 1 ;;
    esac
}

assert_ssh_port_free() {
    if ss -H -tln | awk '{print $4}' | grep -Eq "(^|:|\\])${VM_TEST_SSH_PORT}$"; then
        die "port ${VM_TEST_SSH_PORT} already in use (set VM_TEST_SSH_PORT to override)"
    fi
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
    [[ "$(uname -s)" == "Linux" ]] || die "must run on Linux"
    [[ "$(uname -m)" == "x86_64" ]] || die "only x86_64 is supported currently"
    [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm is not accessible"

    [[ "$VM_TEST_SSH_PORT" =~ ^[0-9]+$ ]] || die "VM_TEST_SSH_PORT must be numeric"
    ((VM_TEST_SSH_PORT >= 1024 && VM_TEST_SSH_PORT <= 65535)) ||
        die "VM_TEST_SSH_PORT must be between 1024 and 65535 for rootless use"

    for cmd in podman jq curl xz qemu-system-x86_64 qemu-img ssh ssh-keygen flock sha256sum ss; do
        command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' not found in PATH"
    done

    if [[ "$DIRECT_MODE" -eq 1 ]]; then
        command -v bcvk >/dev/null 2>&1 || die "'bcvk' is required for --direct mode"
        local bcvk_version bcvk_major bcvk_minor
        bcvk_version=$(bcvk --version | awk '{print $2}')
        [[ "$bcvk_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
            die "could not determine bcvk version (need 0.18.0 or newer)"
        IFS=. read -r bcvk_major bcvk_minor _ <<<"$bcvk_version"
        ((bcvk_major > 0 || bcvk_minor >= 18)) ||
            die "bcvk $bcvk_version is too old; need 0.18.0 or newer for --direct mode"
        if [[ -n "${VIRTIOFSD_BIN:-}" ]]; then
            VIRTIOFSD_PATH="$VIRTIOFSD_BIN"
        else
            local candidate
            for candidate in /usr/libexec/virtiofsd /usr/bin/virtiofsd /usr/local/bin/virtiofsd /usr/lib/virtiofsd; do
                if [[ -x "$candidate" ]]; then
                    VIRTIOFSD_PATH="$candidate"
                    break
                fi
            done
        fi
        [[ -n "$VIRTIOFSD_PATH" && -x "$VIRTIOFSD_PATH" ]] ||
            die "virtiofsd is required for --direct mode (install the virtiofsd package or set VIRTIOFSD_BIN)"
    fi

    local ovmf_code="/usr/share/edk2/ovmf/OVMF_CODE_4M.qcow2"
    local ovmf_vars="/usr/share/edk2/ovmf/OVMF_VARS_4M.qcow2"
    [[ -f "$ovmf_code" ]] || die "OVMF code not found: $ovmf_code"
    [[ -f "$ovmf_vars" ]] || die "OVMF vars not found: $ovmf_vars"

    local lock_dir="${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ucore-vm-test}"
    [[ ! -L "$lock_dir" ]] || die "runtime directory must not be a symlink: $lock_dir"
    mkdir -p "$lock_dir"
    [[ "$(stat -c %u "$lock_dir")" == "$UID" ]] || die "runtime directory is not owned by current user: $lock_dir"
    chmod 700 "$lock_dir"
    local port_lock="$lock_dir/port-${VM_TEST_SSH_PORT}.lock"
    if [[ -e "$port_lock" || -L "$port_lock" ]]; then
        [[ -f "$port_lock" && ! -L "$port_lock" && "$(stat -c %u "$port_lock")" == "$UID" ]] ||
            die "unsafe port lock file: $port_lock"
    fi
    exec {PORT_LOCK_FD}>"$port_lock"
    flock -n "$PORT_LOCK_FD" || die "port ${VM_TEST_SSH_PORT} is reserved by another vm-test"
    assert_ssh_port_free

    echo "Preflight OK: podman $(podman --version | awk '{print $3}'), QEMU/KVM, OVMF"
}

# ---------------------------------------------------------------------------
# Image helpers
# ---------------------------------------------------------------------------
# Ensure image is in local podman storage. Sets HOST_DIGEST and HOST_IMAGE_ID.
ensure_image() {
    local arg="$1" role="$2"
    if ! podman image inspect "$arg" >/dev/null 2>&1; then
        if [[ "$arg" == */* || "$arg" == *.* ]]; then
            echo "Pulling $role image: $arg"
            podman pull "$arg" >&2 || die "failed to pull $role image '$arg'"
        else
            die "cannot find $role image '$arg'; pull or build it first"
        fi
    fi
    HOST_DIGEST=$(podman image inspect --format '{{.Digest}}' "$arg")
    [[ "$HOST_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] ||
        die "$role image '$arg' has no usable OCI digest"
    HOST_IMAGE_ID=$(podman image inspect --format '{{.Id}}' "$arg")
    HOST_IMAGE_ID=${HOST_IMAGE_ID#sha256:}
    [[ "$HOST_IMAGE_ID" =~ ^[0-9a-f]{64}$ ]] || die "$role image '$arg' has no usable image ID"
    local host_arch img_arch
    host_arch=$(normalize_arch "$(uname -m)")
    img_arch=$(normalize_arch "$(podman image inspect --format '{{.Architecture}}' "$arg")")
    [[ "$host_arch" == "$img_arch" ]] || die "$role image arch '$img_arch' != host '$host_arch'"
    echo "$role image: $arg (digest=$HOST_DIGEST)"
}

# ---------------------------------------------------------------------------
# FCOS QEMU image cache
# ---------------------------------------------------------------------------
ensure_fcos_qemu_image() {
    local stream="$VM_TEST_FCOS_STREAM"
    local cache="$VM_TEST_FCOS_CACHE"
    [[ ! -L "$cache" ]] || die "FCOS cache must not be a symlink: $cache"
    mkdir -p "$cache"
    [[ "$(stat -c %u "$cache")" == "$UID" ]] || die "FCOS cache is not owned by current user: $cache"
    chmod 700 "$cache"

    local lock_fd
    exec {lock_fd}>"$cache/.lock"
    flock "$lock_fd"

    echo "Fetching FCOS ${stream} stream metadata..."
    local artifact url compressed_sha uncompressed_sha filename img
    artifact=$(curl -fsSL "https://builds.coreos.fedoraproject.org/streams/${stream}.json" |
        jq -er '.architectures.x86_64.artifacts.qemu.formats["qcow2.xz"].disk') ||
        die "could not resolve FCOS ${stream} qemu image metadata"
    url=$(jq -r '.location' <<<"$artifact")
    compressed_sha=$(jq -r '.sha256' <<<"$artifact")
    uncompressed_sha=$(jq -r '."uncompressed-sha256"' <<<"$artifact")
    [[ "$compressed_sha" =~ ^[0-9a-f]{64}$ && "$uncompressed_sha" =~ ^[0-9a-f]{64}$ ]] ||
        die "FCOS ${stream} metadata contains invalid checksums"
    FCOS_QEMU_SHA256="$uncompressed_sha"
    filename=${url##*/}
    [[ "$filename" == *.qcow2.xz && "$filename" != */* ]] || die "unexpected FCOS artifact name: $filename"
    img="$cache/${filename%.xz}"

    if [[ -e "$img" || -L "$img" ]]; then
        [[ -f "$img" && ! -L "$img" ]] || die "unsafe FCOS cache entry: $img"
        [[ "$(stat -c %u "$img")" == "$UID" ]] || die "FCOS cache entry is not owned by current user: $img"
        if printf '%s  %s\n' "$uncompressed_sha" "$img" | sha256sum --check --status; then
            echo "Using verified cached FCOS qemu image: $img"
            FCOS_QEMU_IMAGE="$img"
            exec {lock_fd}>&-
            return 0
        fi
        rm -f -- "$img"
    fi

    echo "Downloading $url"
    local tmp_dir tmp_xz tmp_img
    tmp_dir=$(mktemp -d "$cache/.download.XXXXXX")
    tmp_xz="$tmp_dir/$filename"
    tmp_img="$tmp_dir/${filename%.xz}"
    if ! curl -fL --retry 3 --retry-delay 5 -o "$tmp_xz" "$url"; then
        rm -rf -- "$tmp_dir"
        die "failed to download FCOS qemu image"
    fi
    if ! printf '%s  %s\n' "$compressed_sha" "$tmp_xz" | sha256sum --check --status; then
        rm -rf -- "$tmp_dir"
        die "downloaded FCOS qemu image checksum mismatch"
    fi
    echo "Decompressing..."
    if ! xz -dc "$tmp_xz" >"$tmp_img" ||
        ! printf '%s  %s\n' "$uncompressed_sha" "$tmp_img" | sha256sum --check --status; then
        rm -rf -- "$tmp_dir"
        die "decompressed FCOS qemu image checksum mismatch"
    fi
    mv -T -- "$tmp_img" "$img"
    rm -rf -- "$tmp_dir"
    FCOS_QEMU_IMAGE="$img"
    exec {lock_fd}>&-
    echo "FCOS qemu image ready: $img"
}

# ---------------------------------------------------------------------------
# VM lifecycle (QEMU + Ignition)
# ---------------------------------------------------------------------------
create_ssh_key() {
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q
}

create_ignition() {
    create_ssh_key
    local pub
    pub=$(cat "${SSH_KEY}.pub")
    # core user is the FCOS default; passwordless sudo is standard on FCOS.
    cat >"$WORK_DIR/config.ign" <<EOF
{
  "ignition": { "version": "3.4.0" },
  "passwd": {
    "users": [
      {
        "name": "core",
        "sshAuthorizedKeys": ["${pub}"]
      }
    ]
  }
}
EOF
    echo "Generated Ignition config and SSH key"
}

create_direct_installer() {
    local script="$WORK_DIR/direct-install.sh"
    cat >"$script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source_ref=$1
target_ref=$2
tmp_size=$3
key_path=$4
disk=/dev/disk/by-id/virtio-output
target=/mnt/ucore-vm-test

for command in sgdisk blockdev udevadm mkfs.vfat mkfs.ext4 mkfs.xfs blkid mount umount bootc; do
    command -v "$command" >/dev/null || {
        echo "required command not found in target image: $command" >&2
        exit 1
    }
done

[[ -b "$disk" ]] || {
    echo "attached target disk not found: $disk" >&2
    exit 1
}
[[ -r "$key_path" ]] || {
    echo "SSH public key not found: $key_path" >&2
    exit 1
}

# bootc imports image layers through container storage; use the disk-sized
# tmpfs backed by bcvk's equally sized swap device rather than the small root.
mount -t tmpfs -o "size=$tmp_size" tmpfs /var/tmp
mkdir -p /var/tmp/containers
rm -rf /var/lib/containers
ln -s /var/tmp/containers /var/lib/containers

sgdisk --zap-all "$disk"
sgdisk --new=1:2048:+1MiB --typecode=1:21686148-6449-6E6F-744E-656564454649 --change-name=1:BIOS-BOOT "$disk"
sgdisk --new=2:0:+127MiB --typecode=2:C12A7328-F81F-11D2-BA4B-00A0C93EC93B --change-name=2:EFI-SYSTEM "$disk"
sgdisk --new=3:0:+384MiB --typecode=3:BC13C2FF-59E6-4262-A352-B275FD6F7172 --change-name=3:boot "$disk"
sgdisk --new=4:0:-2048 --typecode=4:4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709 --change-name=4:root "$disk"
blockdev --rereadpt "$disk"
udevadm settle

mkfs.vfat -F 32 -n EFI-SYSTEM /dev/disk/by-partlabel/EFI-SYSTEM
mkfs.ext4 -F -L boot /dev/disk/by-partlabel/boot
mkfs.xfs -f -L root /dev/disk/by-partlabel/root
root_uuid=$(blkid -s UUID -o value /dev/disk/by-partlabel/root)
boot_uuid=$(blkid -s UUID -o value /dev/disk/by-partlabel/boot)

mkdir -p "$target"
mount /dev/disk/by-partlabel/root "$target"
mkdir -p "$target/boot"
mount /dev/disk/by-partlabel/boot "$target/boot"
mkdir -p "$target/boot/efi"
mount /dev/disk/by-partlabel/EFI-SYSTEM "$target/boot/efi"

export STORAGE_OPTS=additionalimagestore=/run/virtiofs-mnt-hoststorage
bootc install to-filesystem \
    --source-imgref "$source_ref" \
    --target-imgref "$target_ref" \
    --root-mount-spec "UUID=$root_uuid" \
    --boot-mount-spec "UUID=$boot_uuid" \
    --root-ssh-authorized-keys "$key_path" \
    --generic-image \
    --skip-fetch-check \
    "$target"

sync
umount "$target/boot/efi"
umount "$target/boot"
umount "$target"
sgdisk --print "$disk"
EOF
    chmod 700 "$script"
}

install_direct_image() {
    local installer_name installer_dir script_in_guest key_in_guest
    DIRECT_DISK="$WORK_DIR/direct.qcow2"
    qemu-img create -f qcow2 "$DIRECT_DISK" "$VM_TEST_DISK_SIZE" >/dev/null

    DIRECT_SOURCE_REF="localhost/ucore-vm-test-install:${HOST_DIRECT_ID}-${RANDOM}${RANDOM}"
    podman tag "$DIRECT_REF" "$DIRECT_SOURCE_REF" ||
        die "failed to tag direct image as '$DIRECT_SOURCE_REF'"

    installer_name="ucore-vm-test-installer-${BASHPID}-${RANDOM}${RANDOM}"
    installer_dir="$WORK_DIR/installer"
    mkdir -p "$installer_dir"
    create_direct_installer
    script_in_guest=/run/virtiofs-mnt-installer/direct-install.sh
    key_in_guest=/run/virtiofs-mnt-installer/id_ed25519.pub

    echo "Starting bcvk installer VM for $DIRECT_REF"
    BCVK_CONTAINER=$(bcvk ephemeral run -d -K --name "$installer_name" \
        --bind-storage-ro \
        --bind "$WORK_DIR:installer" \
        --mount-disk-file "$DIRECT_DISK:output:qcow2" \
        --add-swap "$VM_TEST_DISK_SIZE" \
        --memory "$VM_TEST_MEMORY" \
        --vcpus "$VM_TEST_CPUS" \
        --virtiofsd "$VIRTIOFSD_PATH" \
        --log-dir="journal,console=$installer_dir" \
        "$DIRECT_REF") || die "failed to start bcvk installer VM"

    echo "Installing direct image to FCOS-compatible disk"
    if ! bcvk ephemeral ssh "$BCVK_CONTAINER" -- bash "$script_in_guest" \
        "containers-storage:$DIRECT_SOURCE_REF" "$DIRECT_REF" "$VM_TEST_DISK_SIZE" "$key_in_guest" \
        >"$installer_dir/install.log" 2>&1; then
        die "direct installer failed (see $installer_dir/install.log)"
    fi

    podman rm -f "$BCVK_CONTAINER" >/dev/null 2>&1 || true
    BCVK_CONTAINER=""
}

vm_start() {
    local backing="$1"
    DISK_IMAGE="$WORK_DIR/disk.qcow2"
    qemu-img create -f qcow2 -F qcow2 -b "$backing" "$DISK_IMAGE" >/dev/null
    qemu-img resize "$DISK_IMAGE" "$VM_TEST_DISK_SIZE" >/dev/null

    local ovmf_code="/usr/share/edk2/ovmf/OVMF_CODE_4M.qcow2"
    local ovmf_vars="$WORK_DIR/OVMF_VARS.qcow2"
    cp /usr/share/edk2/ovmf/OVMF_VARS_4M.qcow2 "$ovmf_vars"

    QEMU_CONSOLE_LOG="$WORK_DIR/console.log"
    local pidfile="$WORK_DIR/qemu.pid"
    local ignition_args=()
    if [[ -f "$WORK_DIR/config.ign" ]]; then
        ignition_args=(-fw_cfg "name=opt/com.coreos/config,file=$WORK_DIR/config.ign")
    fi

    # Recheck immediately before QEMU binds; the per-user lock also prevents
    # concurrent vm-test runs from choosing the same port.
    assert_ssh_port_free
    if ! qemu-system-x86_64 \
        -machine q35,accel=kvm \
        -cpu host \
        -m "$VM_TEST_MEMORY" -smp "$VM_TEST_CPUS" \
        -drive "if=pflash,format=qcow2,readonly=on,file=$ovmf_code" \
        -drive "if=pflash,format=qcow2,file=$ovmf_vars" \
        -drive "file=$DISK_IMAGE,format=qcow2,if=virtio" \
        -netdev "user,id=n0,hostfwd=tcp::${VM_TEST_SSH_PORT}-:22" \
        -device virtio-net-pci,netdev=n0 \
        "${ignition_args[@]}" \
        -display none \
        -serial "file:$QEMU_CONSOLE_LOG" \
        -daemonize \
        -pidfile "$pidfile"; then
        die "QEMU failed to start; verify port ${VM_TEST_SSH_PORT} is available"
    fi

    [[ -s "$pidfile" ]] || die "QEMU did not create its pidfile"
    QEMU_PID=$(cat "$pidfile")
    kill -0 "$QEMU_PID" 2>/dev/null || die "QEMU exited during startup"
    echo "QEMU started (PID $QEMU_PID, SSH port $VM_TEST_SSH_PORT)"
}

# ---------------------------------------------------------------------------
# bootc switch helper
# ---------------------------------------------------------------------------
# Pull the host-resolved digest inside the guest. If the image is local-only
# or registry authentication is unavailable in the guest, transfer the exact
# host image through SSH instead.
guest_bootc_switch() {
    local ref="$1" expected_digest="$2" expected_id="$3"
    local exact_ref switch_ref guest_digest guest_id import_ref transferred=0
    exact_ref=$(digest_ref "$ref" "$expected_digest")
    switch_ref="$exact_ref"

    echo "Guest: podman pull $exact_ref"
    if ! vm_root podman pull "$exact_ref"; then
        echo "Exact registry pull unavailable; transferring $ref from host Podman storage"
        if ! podman save "$ref" | ssh_cmd 'sudo -n podman load'; then
            die "failed to transfer image '$ref' into guest storage"
        fi
        import_ref="localhost/ucore-vm-test-import:$expected_id"
        vm_root podman tag "$expected_id" "$import_ref" ||
            die "failed to tag transferred image '$expected_id' as '$import_ref'"
        switch_ref="$import_ref"
        transferred=1
    fi

    guest_digest=$(vm_root podman image inspect --format '{{.Digest}}' "$switch_ref") ||
        die "failed to inspect guest image '$switch_ref'"
    if [[ "$transferred" -eq 0 ]]; then
        [[ "$guest_digest" == "$expected_digest" ]] ||
            die "guest image digest '$guest_digest' != host-resolved digest '$expected_digest'"
        echo "Guest image digest verified: $guest_digest"
    else
        guest_id=$(vm_root podman image inspect --format '{{.Id}}' "$switch_ref") ||
            die "failed to read transferred guest image ID"
        guest_id=${guest_id#sha256:}
        [[ "$guest_id" == "$expected_id" ]] ||
            die "transferred guest image ID '$guest_id' != host image ID '$expected_id'"
        echo "Transferred guest image ID verified: $guest_id"
        echo "Transferred manifest digest: $guest_digest"
    fi

    echo "Guest: bootc switch --transport containers-storage $switch_ref"
    vm_root bootc switch --quiet --transport containers-storage "$switch_ref" \
        || die "bootc switch failed for $switch_ref"
}

guest_bootc_digest() {
    local slot="$1" # booted|staged|rollback
    vm_root bootc status --format json | jq -r ".status.${slot}.image.imageDigest // \"null\""
}

# ---------------------------------------------------------------------------
# State / health
# ---------------------------------------------------------------------------
capture_guest_host_keys() {
    local -n output=$1
    local keys line fingerprint ktype
    output=()
    keys=$(vm_root bash -c "for f in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf \"\$f\"; done") || return 1
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        fingerprint=$(awk '{print $2}' <<<"$line")
        ktype=$(sed -n 's/.*(\([^)]*\))$/\1/p' <<<"$line")
        [[ -n "$ktype" && -n "$fingerprint" ]] || continue
        # shellcheck disable=SC2034 # Assigned through the caller's nameref.
        output["$ktype"]="$fingerprint"
    done <<<"$keys"
}

wait_system_settled() {
    local deadline=$((SECONDS + VM_TEST_BOOT_TIMEOUT)) state
    while ((SECONDS < deadline)); do
        state=$(vm_ssh systemctl is-system-running 2>/dev/null || true)
        case "$state" in
            running | degraded)
                printf '%s\n' "$state"
                return 0
                ;;
        esac
        sleep 2
    done
    return 1
}

record_baseline_state() {
    read_boot_id
    echo "boot_id: $BOOT_ID"

    MACHINE_ID=$(vm_ssh cat /etc/machine-id)
    [[ -n "$MACHINE_ID" ]] || die "failed to read machine-id"

    SOURCE_DIGEST=$(guest_bootc_digest booted)
    # Fresh FCOS may report a digest from the metal/qemu image transport
    echo "machine-id: $MACHINE_ID"
    echo "booted digest: $SOURCE_DIGEST"

    SSH_HOST_KEY_FPS=()
    capture_guest_host_keys SSH_HOST_KEY_FPS || die "failed to capture baseline SSH host keys"
    ((${#SSH_HOST_KEY_FPS[@]} > 0)) || die "no baseline SSH host keys found"
    echo "SSH host keys: ${#SSH_HOST_KEY_FPS[@]} recorded (${!SSH_HOST_KEY_FPS[*]})"

    BASELINE_FAILED_UNITS=()
    local unit failed_units
    if [[ "$SSH_USER" == root ]]; then
        failed_units=$(ssh_cmd 'systemctl --failed --no-legend --plain' 2>/dev/null || true)
    else
        failed_units=$(ssh_cmd 'sudo -n systemctl --failed --no-legend --plain' 2>/dev/null || true)
    fi
    while IFS= read -r unit; do
        [[ -z "$unit" ]] && continue
        BASELINE_FAILED_UNITS["$unit"]=1
    done < <(awk '{print $1}' <<<"$failed_units")
    echo "Baseline failed units: ${#BASELINE_FAILED_UNITS[@]}"

    # Prefer top-level /var paths; some /var/lib subtrees are deployment-tied.
    vm_root_write /var/ucore-vm-test-marker "source marker"
    vm_root_write /etc/ucore-vm-test.conf "ucore-vm-test persisted"
}

check_system_health() {
    local state
    state=$(vm_ssh systemctl is-system-running 2>/dev/null || echo "unknown")
    case "$state" in
        running) pass_msg "system is-system-running: $state" ;;
        degraded) pass_msg "system is-system-running: $state (degraded)" ;;
        *) fail_msg "system is-system-running: $state (expected running or degraded)" ;;
    esac

    local new_failed=() unit
    while IFS= read -r unit; do
        [[ -z "$unit" ]] && continue
        if [[ -z "${BASELINE_FAILED_UNITS[$unit]:-}" ]]; then
            new_failed+=("$unit")
        fi
    done < <(vm_root systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')

    if [[ ${#new_failed[@]} -eq 0 ]]; then
        pass_msg "no new failed units"
        return
    fi

    local critical=0 u
    for u in "${new_failed[@]}"; do
        case "$u" in
            boot*.mount | *.mount) critical=1 ;;
            systemd-boot*) critical=1 ;;
            sshd* | *.ssh*) critical=1 ;;
            NetworkManager* | network*.target) critical=1 ;;
            bootc*) critical=1 ;;
        esac
    done
    if [[ $critical -eq 1 ]]; then
        fail_msg "new critical failed units: ${new_failed[*]}"
    else
        pass_msg "new non-critical failed units: ${new_failed[*]} (allowed)"
    fi
}

check_swtpm_selinux() {
    if ! vm_root rpm -q swtpm >/dev/null 2>&1; then
        return
    fi

    assert_root "swtpm executable installed" test -x /usr/bin/swtpm
    assert_root "swtpm SELinux package installed" rpm -q swtpm-selinux
    # shellcheck disable=SC2016 # The awk expression is evaluated by guest bash.
    assert_root "swtpm SELinux modules installed at priority 200" bash -c '
        semodule --list-modules=full | awk '\''
            $1 == 200 && ($2 == "swtpm" || $2 == "swtpm_svirt" || $2 == "swtpm_libvirt") {
                found[$2] = 1
            }
            END { exit !(found["swtpm"] && found["swtpm_svirt"] && found["swtpm_libvirt"]) }
        '\''
    '
    assert_root "swtpm expected SELinux context" bash -c \
        "matchpathcon /usr/bin/swtpm | grep -Eq 'swtpm_exec_t(:|$)'"
    assert_root "swtpm deployed SELinux context" bash -c \
        "stat -Lc '%C' /usr/bin/swtpm | grep -Eq 'swtpm_exec_t(:|$)'"
    assert_root "swtpm is not masked by a bind mount" bash -c \
        "awk '\$5 == \"/usr/bin/swtpm\" { found = 1 } END { exit found }' /proc/self/mountinfo"
}

validate_ucore_boot() {
    local expected_digest="$1"
    local expect_rollback="${2:-}"

    local booted_digest rollback_digest variant_id settled_state
    if settled_state=$(wait_system_settled); then
        pass_msg "system settled after boot: $settled_state"
    else
        fail_msg "system did not settle within ${VM_TEST_BOOT_TIMEOUT}s"
    fi
    booted_digest=$(guest_bootc_digest booted)
    rollback_digest=$(guest_bootc_digest rollback)

    assert_eq "$expected_digest" "$booted_digest" "booted digest matches expected"
    if [[ -n "$expect_rollback" && "$expect_rollback" != "null" ]]; then
        assert_eq "$expect_rollback" "$rollback_digest" "rollback digest matches previous"
    fi

    variant_id=$(vm_ssh bash -c "source /usr/lib/os-release && echo \"\${VARIANT_ID:-}\"")
    assert_eq "ucore" "$variant_id" "VARIANT_ID=ucore"

    assert_root "kernel modules available" bash -c "test -d \"/usr/lib/modules/\$(uname -r)\""
    assert_guest "podman works" podman version
    assert_guest "DNS resolution works" getent hosts example.com
    assert_guest "network connectivity" curl -sf --max-time 10 https://example.com -o /dev/null

    check_system_health
    check_swtpm_selinux

    assert_root "/var marker persisted" grep -q 'source marker' /var/ucore-vm-test-marker
    assert_root "/etc marker persisted" grep -q 'ucore-vm-test persisted' /etc/ucore-vm-test.conf

    local current_machine_id
    current_machine_id=$(vm_ssh cat /etc/machine-id)
    assert_eq "$MACHINE_ID" "$current_machine_id" "machine-id unchanged"

    local -A current_host_keys=()
    local ktype
    if ! capture_guest_host_keys current_host_keys; then
        fail_msg "SSH host keys could not be read"
        return
    fi
    assert_eq "${#SSH_HOST_KEY_FPS[@]}" "${#current_host_keys[@]}" "SSH host key type count unchanged"
    for ktype in "${!SSH_HOST_KEY_FPS[@]}"; do
        if [[ -z "${current_host_keys[$ktype]:-}" ]]; then
            fail_msg "SSH host key $ktype is missing"
        else
            assert_eq "${SSH_HOST_KEY_FPS[$ktype]}" "${current_host_keys[$ktype]}" "SSH host key $ktype unchanged"
        fi
    done
    for ktype in "${!current_host_keys[@]}"; do
        [[ -n "${SSH_HOST_KEY_FPS[$ktype]:-}" ]] || fail_msg "unexpected SSH host key type $ktype"
    done
}

run_direct_test() {
    phase="resolve direct image"
    echo ""
    echo "=== Resolve Direct Image ==="
    ensure_image "$DIRECT_REF" "direct"
    HOST_DIRECT_DIGEST="$HOST_DIGEST"
    HOST_DIRECT_ID="$HOST_IMAGE_ID"

    WORK_DIR=$(mktemp -d /var/tmp/ucore-vm-test.XXXXXX)
    echo "Work directory: $WORK_DIR"
    SSH_KEY="$WORK_DIR/id_ed25519"
    create_ssh_key
    SSH_USER=root

    phase="install direct image"
    echo ""
    echo "=== Install Direct Image ==="
    install_direct_image

    phase="boot direct image"
    echo ""
    echo "=== Boot Direct Image ==="
    vm_start "$DIRECT_DISK"
    wait_ssh_up || die "SSH did not become available after direct image boot"

    phase="validate direct boot"
    echo ""
    echo "=== Validate Direct Boot ==="
    record_baseline_state
    validate_ucore_boot "$HOST_DIRECT_DIGEST"

    phase="direct second reboot"
    echo ""
    echo "=== Second Ordinary Reboot ==="
    vm_root systemctl reboot 2>/dev/null || true
    wait_ssh_down || true
    wait_ssh_up "$BOOT_ID" || die "SSH did not return after direct image reboot"
    read_boot_id
    echo "New boot_id: $BOOT_ID"

    phase="validate direct second boot"
    echo ""
    echo "=== Validate Direct Second Boot ==="
    validate_ucore_boot "$HOST_DIRECT_DIGEST"

    phase="summary"
    echo ""
    echo "========================================"
    echo "  Direct VM Test Summary"
    echo "========================================"
    echo "  image:    $DIRECT_REF  ($HOST_DIRECT_DIGEST)"
    echo "  workdir:  $WORK_DIR"
    echo "========================================"

    if [[ "$FAIL_COUNT" -eq 0 ]]; then
        echo "PASSED: All assertions passed."
    else
        red "FAILED: $FAIL_COUNT assertion(s) failed."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [[ $# -eq 2 && "$1" == --direct ]]; then
    DIRECT_MODE=1
    DIRECT_REF="$2"
elif [[ $# -eq 2 && "$2" == --direct ]]; then
    echo "Usage: $0 --direct IMAGE" >&2
    exit 1
elif [[ $# -eq 2 ]]; then
    SOURCE_ARG="$1"
    TARGET_ARG="$2"

    SOURCE_DIRECT_FCOS_STREAM=""
    if SOURCE_DIRECT_FCOS_STREAM=$(direct_fcos_stream "$SOURCE_ARG"); then
        if [[ -n "$VM_TEST_FCOS_STREAM_EXPLICIT" &&
            "$VM_TEST_FCOS_STREAM" != "$SOURCE_DIRECT_FCOS_STREAM" ]]; then
            echo "FATAL [arguments]: SOURCE stream '$SOURCE_DIRECT_FCOS_STREAM' conflicts" \
                "with VM_TEST_FCOS_STREAM '$VM_TEST_FCOS_STREAM'" >&2
            exit 1
        fi
        VM_TEST_FCOS_STREAM="$SOURCE_DIRECT_FCOS_STREAM"
    fi
else
    echo "Usage: $0 SOURCE_IMAGE TARGET_IMAGE" >&2
    echo "       $0 --direct IMAGE" >&2
    exit 1
fi

trap cleanup EXIT

phase="preflight"
echo "=== Preflight ==="
preflight

if [[ "$DIRECT_MODE" -eq 1 ]]; then
    run_direct_test
    exit 0
fi

phase="resolve images"
echo ""
echo "=== Resolve Images ==="
ensure_image "$TARGET_ARG" "target"
HOST_TARGET_DIGEST="$HOST_DIGEST"
HOST_TARGET_ID="$HOST_IMAGE_ID"
TARGET_REF="$TARGET_ARG"

SOURCE_IS_DIRECT_FCOS_STREAM=0
if [[ -n "$SOURCE_DIRECT_FCOS_STREAM" ]]; then
    SOURCE_IS_DIRECT_FCOS_STREAM=1
    echo "source image: $SOURCE_ARG (using official ${SOURCE_DIRECT_FCOS_STREAM} QEMU disk image)"
    HOST_SOURCE_DIGEST="fcos-qemu-pending"
else
    ensure_image "$SOURCE_ARG" "source"
    HOST_SOURCE_DIGEST="$HOST_DIGEST"
    HOST_SOURCE_ID="$HOST_IMAGE_ID"
    SOURCE_REF="$SOURCE_ARG"
fi

if [[ "$SOURCE_IS_DIRECT_FCOS_STREAM" -eq 0 && "$HOST_SOURCE_DIGEST" == "$HOST_TARGET_DIGEST" ]]; then
    die "source and target have the same digest ($HOST_SOURCE_DIGEST)"
fi

# ---------------------------------------------------------------------------
phase="prepare FCOS"
echo ""
echo "=== Prepare FCOS QEMU Image ==="
ensure_fcos_qemu_image
if [[ "$SOURCE_IS_DIRECT_FCOS_STREAM" -eq 1 ]]; then
    HOST_SOURCE_DIGEST="qemu-sha256:$FCOS_QEMU_SHA256"
fi

WORK_DIR=$(mktemp -d /var/tmp/ucore-vm-test.XXXXXX)
echo "Work directory: $WORK_DIR"
SSH_KEY="$WORK_DIR/id_ed25519"
create_ignition

# ---------------------------------------------------------------------------
phase="boot FCOS"
echo ""
echo "=== Boot FCOS ==="
vm_start "$FCOS_QEMU_IMAGE"
wait_ssh_up || die "SSH did not become available after FCOS boot"

echo ""
echo "=== Validate FCOS Boot ==="
# First boot can take a bit after SSH is up; wait within the boot timeout.
state=$(wait_system_settled || echo unknown)
case "$state" in
    running | degraded) pass_msg "system is-system-running: $state" ;;
    *) fail_msg "system is-system-running: $state (expected running or degraded)" ;;
esac
assert_root "bootc status succeeds" bootc status --format json
record_baseline_state

# Every source except a canonical FCOS stream reference is explicitly booted.
if [[ "$SOURCE_IS_DIRECT_FCOS_STREAM" -eq 0 ]]; then
    phase="switch to source"
    echo ""
    echo "=== Switch to Source ($SOURCE_REF) ==="
    guest_bootc_switch "$SOURCE_REF" "$HOST_SOURCE_DIGEST" "$HOST_SOURCE_ID"
    STAGED_DIGEST=$(guest_bootc_digest staged)
    [[ "$STAGED_DIGEST" != "null" ]] || die "no staged deployment after switch to source"
    echo "Staged source digest: $STAGED_DIGEST"

    echo "Rebooting into source..."
    vm_root systemctl reboot 2>/dev/null || true
    wait_ssh_down || true
    wait_ssh_up "$BOOT_ID" || die "SSH did not return after switch to source"
    read_boot_id

    local_booted=$(guest_bootc_digest booted)
    [[ "$local_booted" == "$STAGED_DIGEST" ]] ||
        die "booted source digest '$local_booted' != staged digest '$STAGED_DIGEST'"
    pass_msg "booted into source image"
    SOURCE_DIGEST="$local_booted"
    # Refresh baseline markers after source switch
    record_baseline_state
fi

# ---------------------------------------------------------------------------
phase="stage target"
echo ""
echo "=== Stage Target ($TARGET_REF) ==="
guest_bootc_switch "$TARGET_REF" "$HOST_TARGET_DIGEST" "$HOST_TARGET_ID"

STAGED_DIGEST=$(guest_bootc_digest staged)
staged_image=$(vm_root bootc status --format json | jq -r '.status.staged.image.image.image // "null"')
[[ "$STAGED_DIGEST" != "null" ]] || die "no staged deployment after bootc switch to target"
echo "Staged:        $staged_image"
echo "Staged digest: $STAGED_DIGEST"

if [[ "$STAGED_DIGEST" == "$SOURCE_DIGEST" ]]; then
    die "staged digest equals pre-switch digest; no update performed"
fi

PRE_SWITCH_DIGEST="$SOURCE_DIGEST"

# ---------------------------------------------------------------------------
phase="switch reboot"
echo ""
echo "=== Switch Reboot ==="
vm_root systemctl reboot 2>/dev/null || true
wait_ssh_down || true
wait_ssh_up "$BOOT_ID" || die "SSH did not return with new boot_id after switch reboot"
read_boot_id
echo "New boot_id: $BOOT_ID"

echo ""
echo "=== Validate Switched Boot ==="
validate_ucore_boot "$STAGED_DIGEST" "$PRE_SWITCH_DIGEST"

# ---------------------------------------------------------------------------
phase="second reboot"
echo ""
echo "=== Second Ordinary Reboot ==="
vm_root systemctl reboot 2>/dev/null || true
wait_ssh_down || true
wait_ssh_up "$BOOT_ID" || die "SSH did not return with new boot_id after second reboot"
read_boot_id
echo "New boot_id: $BOOT_ID"

echo ""
echo "=== Validate Second Boot ==="
validate_ucore_boot "$STAGED_DIGEST" "$PRE_SWITCH_DIGEST"

# ---------------------------------------------------------------------------
phase="summary"
echo ""
echo "========================================"
echo "  VM Test Summary"
echo "========================================"
echo "  source:   $SOURCE_ARG  ($HOST_SOURCE_DIGEST)"
echo "  target:   $TARGET_ARG  ($HOST_TARGET_DIGEST)"
echo "  workdir:  $WORK_DIR"
echo "========================================"

if [[ "$FAIL_COUNT" -eq 0 ]]; then
    echo "PASSED: All assertions passed."
else
    red "FAILED: $FAIL_COUNT assertion(s) failed."
    exit 1
fi
