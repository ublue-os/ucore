FROM quay.io/fedora/fedora-coreos:stable

COPY etc /etc

# Remove undesired packages
RUN rpm-ostree override remove \
moby-engine \
toolbox

# Install needed packages
RUN rpm-ostree install \
podman \
podman-docker \
distrobox \
duperemove \
cockpit-system \
cockpit-ostree \
cockpit-podman \
cockpit-networkmanager \
cockpit-storaged

# Finalize
RUN sed -i 's/#AutomaticUpdatePolicy.*/AutomaticUpdatePolicy=stage/' /etc/rpm-ostreed.conf && \
    systemctl enable rpm-ostreed-automatic.timer && \
    rpm-ostree cleanup -m && \
    ostree container commit
