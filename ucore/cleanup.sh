#!/usr/bin/bash

set -eoux pipefail

find /boot/ -maxdepth 1 -mindepth 1 -exec rm -fr {} \; || true
find /tmp/* -maxdepth 0 -type d \! -name rpms -exec rm -fr {} \; || true
find /var/* -maxdepth 0 -type d \! -name cache -exec rm -fr {} \;
find /var/cache/* -maxdepth 0 -type d \! -name libdnf5 \! -name rpm-ostree -exec rm -fr {} \;

# Make ublue-os-signing's policy authoritative for uCore after this stage's
# package work; containers-common can otherwise replace it during the build.
policy_source=/usr/share/ublue-os/signing/usr/etc/containers/policy.json
test -f "$policy_source"
rm -f /etc/containers/policy.json
install -Dpm 0644 "$policy_source" /etc/containers/policy.json
jq -e '.transports.docker["ghcr.io/ublue-os"] | any(.type == "sigstoreSigned")' \
    /etc/containers/policy.json >/dev/null

# Remove build-time runtime files without following symlinks or entering mounts.
clean_runtime_dir() {
    local entry
    for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
        [[ -e "${entry}" || -L "${entry}" ]] || continue
        mountpoint -q -- "${entry}" && continue
        if [[ -d "${entry}" && ! -L "${entry}" ]]; then
            clean_runtime_dir "${entry}"
            rmdir --ignore-fail-on-non-empty -- "${entry}"
        else
            rm -f -- "${entry}"
        fi
    done
}
clean_runtime_dir /run

# Containerfile.in runs bootc container lint after cleanup for each image stage.
mkdir -p /var/tmp \
&& chmod -R 1777 /var/tmp
