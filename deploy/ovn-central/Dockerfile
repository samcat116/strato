FROM ubuntu:24.04

# Per-site OVN central: northbound DB, southbound DB, and ovn-northd for one
# Strato site (issue #343). Every hypervisor in the site points its
# ovn-controller (`ovn_remote`) and the Strato agent's NB client
# (`ovn_northbound`) at this host.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ovn-central \
        ovn-common \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 6641 = northbound (agents' NB clients), 6642 = southbound (ovn-controller)
EXPOSE 6641/tcp 6642/tcp

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s \
    CMD ovn-nbctl --db=tcp:127.0.0.1:6641 --timeout=3 ls-list >/dev/null || exit 1

ENTRYPOINT ["/entrypoint.sh"]
