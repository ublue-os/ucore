#!/bin/sh

set -ouex pipefail

RELEASE="$(rpm -E %fedora)"

# build list of all packages requested for exclusion
EXCLUDED_PACKAGES=($(jq -r "[(.all.exclude | (.all, select(.\"$IMAGE_NAME\" != null).\"$IMAGE_NAME\")[]), \
                             (select(.\"$COREOS_VERSION\" != null).\"$COREOS_VERSION\".exclude | (.all, select(.\"$IMAGE_NAME\" != null).\"$IMAGE_NAME\")[])] \
                             | sort | unique[]" /ctx/packages.json))

# build list of all packages requested for inclusion
INCLUDED_PACKAGES=($(jq -r "[(.all.include | (.all, select(.\"$IMAGE_NAME\" != null).\"$IMAGE_NAME\")[]), \
                             (select(.\"$COREOS_VERSION\" != null).\"$COREOS_VERSION\".include | (.all, select(.\"$IMAGE_NAME\" != null).\"$IMAGE_NAME\")[])] \
                             | sort | unique[]" /ctx/packages.json))

# remove any excluded packages which are present on image before install
if [[ "${#EXCLUDED_PACKAGES[@]}" -gt 0 ]]; then
    dnf -y remove \
        "${EXCLUDED_PACKAGES[@]}"
else
    echo "No packages to remove."
fi

# Install Packages
if [[ "${#INCLUDED_PACKAGES[@]}" -gt 0 ]]; then
    dnf -y install \
        "${INCLUDED_PACKAGES[@]}"
else
    echo "No packages to install."

fi

if [[ "${#EXCLUDED_PACKAGES[@]}" -gt 0 ]]; then
    EXCLUDED_PACKAGES=($(rpm -qa --queryformat='%{NAME} ' ${EXCLUDED_PACKAGES[@]}))
fi

# remove any excluded packages which are still present on image
if [[ "${#EXCLUDED_PACKAGES[@]}" -gt 0 ]]; then
    dnf -y remove \
        "${EXCLUDED_PACKAGES[@]}"
else
    echo "No packages to remove."
fi
