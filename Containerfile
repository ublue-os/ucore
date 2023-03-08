ARG COREOS_VERSION=${COREOS_VERSION:-stable}

FROM quay.io/fedora/fedora-coreos:${COREOS_VERSION}

COPY etc /etc
RUN mkdir -p /var/lib/duperemove

# Remove undesired packages
RUN rpm-ostree override remove \
toolbox \
zincati

# Install needed packages
RUN cd /etc/yum.repos.d/ \
    && curl -LO https://pkgs.tailscale.com/stable/fedora/tailscale.repo \
    && rpm-ostree install \
        cockpit-system \
        cockpit-ostree \
        cockpit-podman \
        cockpit-networkmanager \
        cockpit-storaged \
        distrobox \
        docker-compose \
        duperemove \
        firewalld \
        podman \
        podman-compose \
        tailscale \
        wget \
        wireguard-tools \
        xdg-dbus-proxy \
        xdg-user-dirs \
    && rm tailscale.repo

# Finalize
RUN sed -i 's/#AutomaticUpdatePolicy.*/AutomaticUpdatePolicy=stage/' /etc/rpm-ostreed.conf && \
    sed -i 's/#DefaultTimeoutStopSec.*/DefaultTimeoutStopSec=60s/' /etc/systemd/user.conf && \
    sed -i 's/#DefaultTimeoutStopSec.*/DefaultTimeoutStopSec=60s/' /etc/systemd/system.conf && \
    systemctl enable rpm-ostreed-automatic.timer && \
    rpm-ostree cleanup -m && \
    ostree container commit
