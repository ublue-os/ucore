ARG FEDORA_MAJOR_VERSION=37

FROM quay.io/fedora/fedora-coreos:stable

COPY etc /etc

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

# Override replace testing version of rpm-ostree so systems aren't bricked when layering packages. This will need to be removed relatively soon
RUN wget https://kojipkgs.fedoraproject.org//packages/rpm-ostree/2022.18/2.fc37/x86_64/rpm-ostree-2022.18-2.fc37.x86_64.rpm && \
wget https://kojipkgs.fedoraproject.org//packages/rpm-ostree/2022.18/2.fc37/x86_64/rpm-ostree-libs-2022.18-2.fc37.x86_64.rpm && \
rpm-ostree override replace rpm-ostree-2022.18-2.fc37.x86_64.rpm rpm-ostree-libs-2022.18-2.fc37.x86_64.rpm

# Finalize
RUN sed -i 's/#AutomaticUpdatePolicy.*/AutomaticUpdatePolicy=stage/' /etc/rpm-ostreed.conf && \
    systemctl enable rpm-ostreed-automatic.timer && \
    rpm-ostree cleanup -m && \
    ostree container commit
