FROM alpine:latest
RUN wget -O /usr/local/bin/cloud-hypervisor "https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v44.0/cloud-hypervisor-static-aarch64" && chmod +x /usr/local/bin/cloud-hypervisor

ENTRYPOINT [ "/usr/local/bin/cloud-hypervisor", "--api-socket", "/var/run/app.sock" ]
