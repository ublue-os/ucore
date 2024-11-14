#!/bin/sh

set -ouex pipefail

RELEASE="$(rpm -E %fedora)"

## CONDITIONAL: install sanoid if ZFS
if [[ "-zfs" == "${ZFS_TAG}" ]]; then
    rpm-ostree install sanoid
fi

# install packages.json stuffs
export IMAGE_NAME=ucore
/ctx/packages.sh

# install packages direct from github
# Fedora 41 packages missing for mergerfs
#/ctx/github-release-install.sh trapexit/mergerfs fc${RELEASE}.x86_64
curl --fail --retry 5 --retry-delay 5 --retry-all-errors -sSL -o /tmp/mfs-api.json \
    "https://api.github.com/repos/trapexit/mergerfs/releases/latest"
MFS_TGZ_URL=$(cat /tmp/mfs-api.json | \
    jq -r --arg arch_filter "linux_amd64" \
    '.assets | sort_by(.created_at) | reverse | .[] | select(.name|test($arch_filter)) | select (.name|test("tar.gz$")) | .browser_download_url')
curl -sSL -o /tmp/mergerfs.tar.gz "${MFS_TGZ_URL}"
tar -zxvf /tmp/mergerfs.tar.gz -C /usr --strip-components=2

# tweak os-release
sed -i '/^PRETTY_NAME/s/(uCore.*$/(uCore)"/' /usr/lib/os-release
