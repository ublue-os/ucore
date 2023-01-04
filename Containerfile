ARG FEDORA_MAJOR_VERSION=37

FROM quay.io/fedora/fedora-coreos:stable

COPY etc /etc
RUN mkdir -p /var/lib/duperemove

# Remove undesired packages
RUN rpm-ostree override remove \
moby-engine \
toolbox \
zincati

# Install needed packages
RUN rpm-ostree install \
cockpit-system \
cockpit-ostree \
cockpit-podman \
cockpit-networkmanager \
cockpit-storaged \
distrobox \
duperemove \
firewalld \
podman \
podman-docker \
podman-compose \
wget \
wireguard-tools \
xdg-dbus-proxy \
xdg-user-dirs

# Finalize
RUN sed -i 's/#AutomaticUpdatePolicy.*/AutomaticUpdatePolicy=stage/' /etc/rpm-ostreed.conf && \
    sed -i 's/#DefaultTimeoutStopSec.*/DefaultTimeoutStopSec=15s/' /etc/systemd/user.conf && \
    sed -i 's/#DefaultTimeoutStopSec.*/DefaultTimeoutStopSec=15s/' /etc/systemd/system.conf && \
    systemctl enable rpm-ostreed-automatic.timer && \
    rpm-ostree cleanup -m && \
    ostree container commit
