#!/usr/bin/bash

set -eoux pipefail

rm -rf /tmp/* || true
find /var/* -maxdepth 0 -type d \! -name cache -exec rm -fr {} \;
find /var/cache/* -maxdepth 0 -type d \! -name libdnf5 \! -name rpm-ostree -exec rm -fr {} \;

# this currently fails on /usr/etc and /var/cache
#bootc container lint
ostree container commit
mkdir -p /var/tmp \
&& chmod -R 1777 /var/tmp