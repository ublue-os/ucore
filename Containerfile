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
podman-compose \
distrobox \
duperemove \
cockpit-system \
cockpit-ostree \
cockpit-podman \
cockpit-networkmanager \
cockpit-storaged \
xdg-dbus-proxy \
xdg-user-dirs

# Finalize
RUN rpm-ostree cleanup -m && \
    ostree container commit
