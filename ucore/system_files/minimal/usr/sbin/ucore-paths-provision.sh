#!/usr/bin/bash
#
# some paths are not provisioned properly in CoreOS OCI images
# at least some due to restrictions on paths in /var
#
# ucore-paths-provision.sh will ensure these are created
# and restore SElinux context where applicable
#
CONFIG=/etc/systemd/ucore-paths-provision.conf

for MODE_PATH in $(cat $CONFIG|grep -v ^#); do
    MP=(${MODE_PATH//;/ })
    if [ ! -d "${MP[1]}" ]; then
        mkdir -p -m ${MP[0]} ${MP[1]}
        restorecon -v ${MP[1]}
    fi
done