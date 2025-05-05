#!/usr/bin/bash

set -eoux pipefail

rm -rf /tmp/* || true
find /var/* -maxdepth 0 -type d -exec rm -fr {} \;

# this currently fails on /usr/etc
#bootc container lint
ostree container commit
mkdir -p /var/tmp \
&& chmod -R 1777 /var/tmp