ARG COREOS_VERSION="${COREOS_VERSION:-stable}"
ARG ZFS_VERSION="${ZFS_VERSION}"

FROM quay.io/fedora/fedora-coreos:${COREOS_VERSION} as kernel-query

#We can't use the `uname -r` as it will pick up the host kernel version
RUN rpm -qa kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' > /kernel-version.txt

# Using https://openzfs.github.io/openzfs-docs/Developer%20Resources/Custom%20Packages.html
FROM registry.fedoraproject.org/fedora:latest as builder
ARG ZFS_VERSION

ADD certs /tmp/certs

RUN install -Dm644 /tmp/certs/public_key.der   /etc/pki/akmods/certs/public_key.der
RUN install -Dm644 /tmp/certs/private_key.priv /etc/pki/akmods/private/private_key.priv
RUN install -Dm644 /tmp/certs/private_key.priv /lib/modules/$(cat /kernel-version.txt)/build/certs/signing_key.pem

COPY --from=kernel-query /kernel-version.txt /kernel-version.txt

WORKDIR /etc/yum.repos.d
RUN BUILDER_VERSION=$(grep VERSION_ID /etc/os-release | cut -f2 -d=) \
    && curl -L -O https://src.fedoraproject.org/rpms/fedora-repos/raw/f${BUILDER_VERSION}/f/fedora-updates-archive.repo \
    && sed -i 's/enabled=AUTO_VALUE/enabled=true/' fedora-updates-archive.repo
RUN dnf install -y jq dkms gcc make autoconf automake libtool rpm-build libtirpc-devel libblkid-devel \
    libuuid-devel libudev-devel openssl-devel zlib-devel libaio-devel libattr-devel elfutils-libelf-devel \
    kernel-$(cat /kernel-version.txt) kernel-modules-$(cat /kernel-version.txt) kernel-devel-$(cat /kernel-version.txt) \
    python3 python3-devel python3-setuptools python3-cffi libffi-devel git ncompress libcurl-devel

WORKDIR /
RUN curl -L -O https://github.com/openzfs/zfs/releases/download/zfs-${ZFS_VERSION}/zfs-${ZFS_VERSION}.tar.gz \
    && tar xzf zfs-${ZFS_VERSION}.tar.gz \
    && mv zfs-${ZFS_VERSION} /tmp/zfs

WORKDIR /tmp/zfs
# build
RUN ./configure \
        -with-linux=/usr/src/kernels/$(cat /kernel-version.txt)/ \
        -with-linux-obj=/usr/src/kernels/$(cat /kernel-version.txt)/ \
    && make -j 1 rpm-utils rpm-kmod
# sort into directories for easier install later
RUN mkdir -p /tmp/rpms/{debug,devel,other,src} \
    && mv *src.rpm /tmp/rpms/src/ \
    && mv *devel*.rpm /tmp/rpms/devel/ \
    && mv *debug*.rpm /tmp/rpms/debug/ \
    && mv zfs-dracut*.rpm /tmp/rpms/other/ \
    && mv zfs-test*.rpm /tmp/rpms/other/ \
    && mv *.rpm /tmp/rpms/
RUN find /tmp/rpms | sort


FROM scratch

# Copy build RPMs
COPY --from=builder /tmp/rpms/ /
