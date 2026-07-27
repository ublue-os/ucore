#!/usr/bin/env bash
# Verify a ucore image can boot on a VM and survive a reboot.
#
# Boots an official Fedora CoreOS QEMU image (the recommended starting
# point for uCore), optionally bootc-switches to SOURCE_IMAGE when it is
# not FCOS, then bootc-switches to TARGET_IMAGE, reboots, and validates
# health and persistence through a second ordinary reboot.
#
# Usage:  ./vm-test.sh SOURCE_IMAGE TARGET_IMAGE
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
# Why FCOS QEMU image (not bootc install to-disk / bcvk)?
#   bootc install to-disk on FCOS/uCore does not create a LABEL=boot
#   partition, and FCOS sets skip-boot-uuid=true.  GRUB then fails with
#   "no such device: boot".  Even after writing bootuuid.cfg, bare
#   bootc-installed FCOS disks were observed to reset under UEFI before
#   reaching multi-user.  The official FCOS QEMU image boots reliably
#   and matches the documented install-from-CoreOS path.
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
#   VM_TEST_FCOS_STREAM       Override CoreOS bootstrap stream (default SOURCE
#                             tag when stable/testing/next, otherwise stable)
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
BOOT_ID=""
MACHINE_ID=""
SOURCE_DIGEST=""
STAGED_DIGEST=""
FAIL_COUNT=0
SSH_USER="core"
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
    ssh_cmd "sudo -n -- $cmd"
}

# Write a file as root via tee (avoids sudo redirect pitfalls).
vm_root_write() {
    local path="$1" content="$2"
    ssh_cmd "printf '%s\n' $(printf '%q' "$content") | sudo -n tee $(printf '%q' "$path") >/dev/null"
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
        echo "        command failed: sudo $*" >&2
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

is_fcos_ref() {
    local ref="$1"
    [[ "$ref" == *fedora-coreos* || "$ref" == *fedora/fedora-coreos* ]]
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
create_ignition() {
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q
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
        -fw_cfg "name=opt/com.coreos/config,file=$WORK_DIR/config.ign" \
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
    local exact_ref switch_ref guest_digest guest_id transferred=0
    exact_ref=$(digest_ref "$ref" "$expected_digest")
    switch_ref="$exact_ref"

    echo "Guest: podman pull $exact_ref"
    if ! vm_root podman pull "$exact_ref"; then
        echo "Exact registry pull unavailable; transferring $ref from host Podman storage"
        if ! podman save "$ref" | ssh_cmd 'sudo -n podman load'; then
            die "failed to transfer image '$ref' into guest storage"
        fi
        switch_ref="$ref"
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
    keys=$(ssh_cmd 'sudo -n bash -c "for f in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf \"\$f\"; done"') || return 1
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
    local unit
    while IFS= read -r unit; do
        [[ -z "$unit" ]] && continue
        BASELINE_FAILED_UNITS["$unit"]=1
    done < <(ssh_cmd 'sudo -n systemctl --failed --no-legend --plain' 2>/dev/null | awk '{print $1}')
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

    variant_id=$(vm_ssh bash -c 'source /usr/lib/os-release && echo "${VARIANT_ID:-}"')
    assert_eq "ucore" "$variant_id" "VARIANT_ID=ucore"

    assert_root "kernel modules available" bash -c 'test -d "/usr/lib/modules/$(uname -r)"'
    assert_guest "podman works" podman version
    assert_guest "DNS resolution works" getent hosts example.com
    assert_guest "network connectivity" curl -sf --max-time 10 https://example.com -o /dev/null

    check_system_health

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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
[[ $# -eq 2 ]] || {
    echo "Usage: $0 SOURCE_IMAGE TARGET_IMAGE" >&2
    exit 1
}

SOURCE_ARG="$1"
TARGET_ARG="$2"

if is_fcos_ref "$SOURCE_ARG" && [[ -z "$VM_TEST_FCOS_STREAM_EXPLICIT" ]]; then
    source_tag=${SOURCE_ARG##*/}
    source_tag=${source_tag##*:}
    case "$source_tag" in
        stable | testing | next) VM_TEST_FCOS_STREAM="$source_tag" ;;
    esac
fi

trap cleanup EXIT

phase="preflight"
echo "=== Preflight ==="
preflight

phase="resolve images"
echo ""
echo "=== Resolve Images ==="
ensure_image "$TARGET_ARG" "target"
HOST_TARGET_DIGEST="$HOST_DIGEST"
HOST_TARGET_ID="$HOST_IMAGE_ID"
TARGET_REF="$TARGET_ARG"

SOURCE_IS_FCOS=0
if is_fcos_ref "$SOURCE_ARG"; then
    SOURCE_IS_FCOS=1
    echo "source image: $SOURCE_ARG (FCOS — using official QEMU disk image)"
    HOST_SOURCE_DIGEST="fcos-qemu-image"
else
    ensure_image "$SOURCE_ARG" "source"
    HOST_SOURCE_DIGEST="$HOST_DIGEST"
    HOST_SOURCE_ID="$HOST_IMAGE_ID"
    SOURCE_REF="$SOURCE_ARG"
fi

if [[ "$SOURCE_IS_FCOS" -eq 0 && "$HOST_SOURCE_DIGEST" == "$HOST_TARGET_DIGEST" ]]; then
    die "source and target have the same digest ($HOST_SOURCE_DIGEST)"
fi

# ---------------------------------------------------------------------------
phase="prepare FCOS"
echo ""
echo "=== Prepare FCOS QEMU Image ==="
ensure_fcos_qemu_image

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

# If SOURCE is not FCOS, switch to it first (older uCore path).
if [[ "$SOURCE_IS_FCOS" -eq 0 ]]; then
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
