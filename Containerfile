ARG IMAGE_NAME="${IMAGE_NAME:-ucore}"
ARG COREOS_VERSION="${COREOS_VERSION:-stable}"

FROM quay.io/fedora/fedora-coreos:${COREOS_VERSION}

ARG IMAGE_NAME
ARG COREOS_VERSION

ADD build.sh /tmp/build.sh
ADD post-install.sh /tmp/post-install.sh
ADD packages.json /tmp/packages.json

COPY etc /etc
COPY usr /usr

RUN /tmp/build.sh
RUN /tmp/post-install.sh
RUN rm -rf /tmp/* /var/*
RUN ostree container commit
RUN mkdir -p /var/tmp && chmod -R 1777 /var/tmp