ARG BASE=quay.io/centos-bootc/centos-bootc:stream10
FROM $BASE

LABEL org.opencontainers.image.title="OpenCHAMI CentOS Stream 10 bootc"
LABEL org.opencontainers.image.description="CentOS Stream 10 bootc image preconfigured for OpenCHAMI provisioning"
LABEL org.opencontainers.image.source="https://github.com/${IMAGE_REPO:-openchami/oc-image-mode}"
LABEL org.openchami.image.type="bootc"
LABEL org.openchami.image.os="centos-stream10"

RUN dnf -y install \
        cloud-init \
        openssh-server \
        ipmitool \
        lldpd \
        rsyslog \
        htop \
        tmux \
        jq \
    && dnf clean all

COPY cloud-init/99_openchami.cfg /etc/cloud/cloud.cfg.d/99_openchami.cfg

RUN useradd -m -G wheel bootc-user \
    && echo "bootc-user:bootc-user" | chpasswd \
    && echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel-sudo \
    && systemctl enable sshd cloud-init cloud-init-local cloud-config cloud-final lldpd

RUN rm -rf /var/cache/dnf /var/lib/dnf /var/cache/ldconfig \
    && bootc container lint
