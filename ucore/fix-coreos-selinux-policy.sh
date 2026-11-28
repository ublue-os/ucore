#!/usr/bin/env bash

set -euo pipefail

# Temporary until FCOS testing includes the unpinned policy packages:
# https://github.com/coreos/fedora-coreos-config/pull/4508
[[ "$(rpm -E %fedora)" == 45 ]] || exit 0

package_at_least() {
    local installed
    installed="$(rpm -q --qf '%{EPOCHNUM}:%{VERSION}-%{RELEASE}' "$1")"
    [[ "$(rpm --eval "%{lua:print(rpm.vercmp(\"${installed}\", \"$2\"))}")" -ge 0 ]]
}

if package_at_least selinux-policy 0:45.23-1.fc45 &&
    package_at_least selinux-policy-targeted 0:45.23-1.fc45 &&
    package_at_least container-selinux 4:2.251.0-1.fc45; then
    exit 0
fi

dnf -y install \
    'selinux-policy >= 45.23-1.fc45' \
    'selinux-policy-targeted >= 45.23-1.fc45' \
    'container-selinux >= 4:2.251.0-1.fc45'

# RPMs populate /var/lib/selinux, but CoreOS uses /etc/selinux as its store.
# Import the packaged base modules through semodule, preserving CoreOS's
# additional modules, priorities, local settings, and disabled-module state.
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
cd "$work"
mapfile -t modules < <(find /var/lib/selinux/targeted/active/modules/100 \
    -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
(( ${#modules[@]} > 0 ))
semodule --store-path /var/lib/selinux --priority 100 --hll --extract "${modules[@]}"

# Keep policy-store renames in one overlay layer during the transaction.
cp -a /etc/selinux/targeted /etc/selinux/targeted.rebuilt
rm -rf /etc/selinux/targeted
mv /etc/selinux/targeted.rebuilt /etc/selinux/targeted
semodule --noreload --priority 100 --install ./*.pp
semodule --noreload --priority 200 --install /usr/share/selinux/packages/container.pp.bz2

# The policy RPM replaces the file_contexts.subs_dist that rpm-ostree
# postprocessed when composing CoreOS. Unprocessed, it aliases /var/home to
# /home while the home directory rules are generated for HOME=/var/home, so
# every file in a home directory is labelled default_t and sshd rejects
# ~/.ssh/authorized_keys.d/ignition (#485). Redo rpm-ostree's postprocessing,
# postprocess_subs_dist in rust/src/composepost.rs, on the new file. dnf can
# also leave a file that is already postprocessed, so an alias is added only
# when no active line substitutes its source yet.
subs_dist=/etc/selinux/targeted/contexts/files/file_contexts.subs_dist
#### SUBS_DIST
sed -i 's|^/var/home[[:space:]]|# &|' "$subs_dist"
aliases="$(
    {
        echo "/home /var/home"
        echo "/usr/etc /etc"
        sed -n 's|^/etc/|/usr&|p' "$subs_dist"
        echo "/usr/lib/opt /opt"
        echo "/var/lib/selinux /etc/selinux"
    } | awk 'NR == FNR { if ($1 !~ /^#/) substituted[$1] = 1; next }
        !($1 in substituted) { print; substituted[$1] = 1 }' "$subs_dist" -
)"
if [[ -n "$aliases" ]]; then
    printf '%s\n' "$aliases" >> "$subs_dist"
fi
