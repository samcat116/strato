# Per-site OVN central

One OVN control cluster (northbound DB, southbound DB, `ovn-northd`) per
**site** (availability zone). This is what lets a single logical network span
multiple hypervisors: all of a site's agents share this northbound DB, and
their `ovn-controller`s form geneve tunnels between chassis registered in the
shared southbound DB (issue #343, [networking architecture](../../docs/architecture/networking.md)).

Run it on one host per site that every hypervisor in the site can reach
(Phase 2 assumes a routable site network — LAN or customer-provided):

```sh
cd deploy/ovn-central
docker compose up -d --build
```

It listens on plain TCP: `6641` (northbound) and `6642` (southbound). Plain
TCP assumes the site network is trusted; for anything less, issue certs with
`ovn-pki` and switch the remotes to `ssl:`. On the agent side, point
`ovn_northbound` at `ssl:<central-host>:6641` and put the PKI material in
`[ovn_northbound_tls]` (the counterparts of ovn-nbctl's `-C`/`-c`/`-p`):

```toml
ovn_northbound = "ssl:<central-host>:6641"

[ovn_northbound_tls]
ca_cert = "/etc/strato/pki/cacert.pem"
client_cert = "/etc/strato/pki/agent-cert.pem"
client_key = "/etc/strato/pki/agent-privkey.pem"
```

## Pointing the site's hypervisors at it

On **every** agent in the site, in `config.toml`:

```toml
network_mode = "ovn"
# southbound, consumed by ovn-controller (chassis bootstrap writes it to OVS)
ovn_remote = "tcp:<central-host>:6642"
# northbound, consumed by the Strato agent itself (VM ports, topology)
ovn_northbound = "tcp:<central-host>:6641"
```

Each hypervisor still runs `ovn-controller` and Open vSwitch locally
(`ovn-host` + `openvswitch-switch`); it must **not** run its own
`ovn-central` — that is the old per-node model this replaces.

The host running ovn-central can be (and typically is) also a hypervisor; its
agent uses the same `tcp:` endpoints (or the local unix sockets).

## Control-plane side

1. Create a site and register the agents into it (`POST /api/sites`, then
   registration tokens carrying `siteId`).
2. Designate exactly one agent as the site's **network controller**
   (`PUT /api/sites/:id` with `networkControllerAgentId`) — the single writer
   of this NB's topology. Until one is designated, VMs place and their ports
   bind, but no switches/routers are created.
3. Pin networks to the site (`POST /api/networks` with `siteId`) so the
   scheduler keeps their VMs on the site's hosts.

## Verifying the site fabric

With two agents in the site and a VM on each, on either hypervisor:

```sh
# both chassis registered in the shared SB
ovn-sbctl --db=tcp:<central-host>:6642 show
# geneve tunnel ports to each peer chassis
ovs-vsctl show | grep -A3 geneve
# one logical switch, ports from both hosts
ovn-nbctl --db=tcp:<central-host>:6641 show
```

Then ping between the two VMs on the same logical network — that traffic
crosses the geneve tunnel.
