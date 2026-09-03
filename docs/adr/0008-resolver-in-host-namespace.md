# ADR 0008: The per-network resolver runs in the host namespace

- **Status**: Accepted. **Supersedes [ADR 0007](./0007-coredns-per-chassis-namespace.md)**
- **Date**: 2026-08-08
- **Deciders**: Sam Schmitt
- **Scope**: where a network's DNS resolver runs on a hypervisor host, what
  addresses it answers on, and how its replies get back to the guest
- **Affects**: STR-40 (roadmap #769 phase 4), which ADR 0007 landed without the
  forwarding that was the issue's headline outcome
- **Does not affect**: the instance metadata service, which **stays** in its
  per-network chassis namespace (ADR 0003). That split is the substance of this
  decision, not an oversight — see "Why metadata stays".

## Summary

Each network's resolver answers on a **distinct pair of addresses derived from a
per-network index** the control plane allocates: `169.254.<hi>.<lo>` and
`fd00:ec2:1::<index>`. Those addresses are terminated in the **host network
namespace**, on a **second OVN `localport`** of their own, with a per-network
policy-routing rule (`ip rule from <addr> lookup <table>`) steering replies back
out the right port. A **single** host-wide CoreDNS binds one server block per
address pair.

This reverses ADR 0007, which put the resolver in the network's existing chassis
namespace on a well-known pair of addresses shared by every network. That
decision was correct about everything it weighed and wrong about the one thing it
did not: egress.

## Context

ADR 0007 records its own gap, so this only needs to restate the shape of it. A
chassis namespace has exactly one interface, an OVS internal port on the tenant
switch, and its only addresses are link-local. A resolver in there cannot reach
an upstream: a query to a public resolver either ARPs for that address on a
tenant switch where nothing answers, or leaves via the network's gateway with a
`169.254/16` source that no SNAT rule matches and no router can route back to.

That is not a missing feature at the edge of phase 4. **Forwarding is why phase 4
exists** — the bug on the issue is that a guest on a network with
`externalAccess: false` cannot resolve a public name. ADR 0007 shipped the other
half (CNAME/TXT/SRV, which the OVN `DNS` table cannot express) and shipped
`resolver_enabled` as an opt-in precisely because the headline outcome was
missing. `docs/architecture/dns.md` §The forwarding gap listed three ways out.
This takes the third, which is the design STR-40's issue proposed in the first
place.

## Decision

### The resolver moves to the host namespace

A process in the host namespace forwards through the hypervisor's own egress —
its resolv.conf, its routes, its NAT. Nothing has to be built for that; it is
what "host namespace" means. `LogicalNetwork.dnsServers` (redefined in STR-40 as
the resolver's upstream forwarders) becomes load-bearing rather than inert.

### Each network gets distinct addresses, derived from an index

ADR 0007's single well-known pair worked only because each namespace was a
separate address space. In one shared namespace they collide the moment a
hypervisor runs NICs on two networks. So the address becomes per network.

What is allocated and stored is a **single index**, not two addresses:
`NetworkResolverEndpoint` derives both families from it, so there are not two
columns that can disagree and the v6 scheme can change without a data migration.
Allocation is **fleet-wide and sequential** (`ResolverAddressAllocator`, under a
`pg_advisory_xact_lock`), not hashed from the network id: ~65k usable addresses
means birthday collisions appear at a few hundred networks, well inside what one
deployment reaches, and a collision here is two networks whose guests are told to
resolve at the same address on a host that terminates both.

Fleet-wide rather than per host because an index scoped per host would depend on
where a VM is placed — not knowable when the network is created, and changing
under migration.

`169.254.169.254` and `169.254.169.253` are excluded from the range. The first is
the metadata service's; the second is ADR 0007's resolver constant, which a host
mid-upgrade may still have on an interface.

### Replies are routed by policy routing, not by the namespace

The one real thing a namespace gave the resolver was reply routing: a reply from
a link-local address in a namespace with a single interface can only leave the
right way. In the host namespace, a reply sourced from `169.254.x.y` would follow
the host's `main` table and go out the wrong interface, or nowhere.

Per-network policy routing replaces it. Each resolver port gets its own routing
table (`20_000 + index`) holding a default route out that port, and an
`ip rule from <resolver-address> lookup <table>`. The source address is unique per
network by construction, so the rule cannot be ambiguous. Rules are deleted
before being added so a re-reconcile does not stack duplicates, and torn down
*before* the OVS detach so a rule never outlives the port it points at.

### The resolver gets its own localport, separate from metadata's

Two ports rather than one, because the two services now terminate in different
namespaces and a `localport` is attached to exactly one. They share a teardown
set and each is protected from teardown by its own service's silence, so a
control plane that has an opinion about one and not the other does not reap the
other's port.

### One CoreDNS for the host, not one per network

A single process binding one server block per address pair. Verified empirically
before committing to it: CoreDNS will serve the same zone name from different
bind addresses with different contents, which is the property this needs, since
two networks may both hold a zone called `corp.example.com`. Zone files are
namespaced under `zones/<network-uuid>/` for the same reason.

This collapses the per-network supervisor, backoff and adoption machinery ADR
0007 needed into one, and it is strictly less to run: N networks on a host cost
one process, not N.

### Isolation is explicit, because a host-namespace foot deserves it

The resolver's interface is in the host namespace, on a tenant switch. Five
things are set on it and none is incidental:

- `net.ipv4.conf.<dev>.forwarding=0` and the v6 equivalent, so the host does not
  become a router between a tenant network and anything else it can reach.
- `rp_filter=2` (loose), because strict reverse-path filtering would drop guest
  queries whose source the policy-routed table does not have a route back to.
- `arp_ignore=1` and `arp_announce=2`. The kernel default answers ARP arriving
  on *any* interface for *any* local address, which would put the hypervisor's
  own management address one ARP reply away from a tenant L2 domain — and
  `forwarding=0` does not help, because traffic to a local address is delivered
  locally rather than forwarded. `1` answers only for the resolver pair actually
  configured here.
- `net.ipv6.conf.<dev>.accept_ra=0`, because a guest can emit Router
  Advertisements and a host that accepted them from inside a tenant network
  would take routes, and a default gateway, from it.
- The `ip rule` matches **only** the resolver's own source address, so nothing
  else on the host is steered into a tenant network's table.

The ingress `tc` policer ADR 0003's amendment describes still applies, now to
this port as well — and it matters more here, since one CoreDNS in the host's
own namespace answers for every network on the hypervisor.

**`rp_filter` is only half in our hands, and that is a deployment
requirement rather than a setting.** The kernel validates a source against
`max(conf.all.rp_filter, conf.<dev>.rp_filter)`, so a host whose `all` is `1`
stays strict on this interface whatever the per-device value says, and every
guest query is dropped silently. Lowering `all` would weaken source validation
on the hypervisor's own NICs, which is not a trade this feature makes on an
operator's behalf — so `HostPreflight` reports it as an advisory check with the
remedy instead.

## Why metadata stays

The metadata service is **not** moving, and the asymmetry is the point.

Metadata's security model *is* source-IP attribution: a request is authorized as
coming from a particular VM because of the address it arrived from, which is only
trustworthy because the namespace makes that address unforgeable across networks.
It also needs no egress at all — it answers out of the agent's own state.
Everything ADR 0003 argues for it still holds.

DNS is the opposite on both counts. It needs egress, and it does not attribute:
every guest on a network gets the same answers, so which guest asked does not
change the reply. The namespace was costing it the thing it needs and giving it
something it does not use.

So the two services diverge, and a reader finding one supervisor in a namespace
and one outside should read that as a considered split.

## Consequences

- **The bug STR-40 was filed for is fixed.** A guest on a network without
  external access resolves public names through the hypervisor's egress.
- **`resolverEnabled` can default on** for new networks, which ADR 0007's version
  could not justify.
- **A larger host-namespace surface.** ADR 0007's version put nothing in the host
  namespace; this puts one interface and one `ip rule` per network per host. The
  mitigations above are what make that acceptable, and they are asserted in
  tests (`ResolverHostPortPlanTests`) rather than left to a reviewer's memory.
- **A fleet-wide allocation to keep consistent**, with a 65k ceiling and an
  explicit `409` when it is exhausted. Indexes are never moved once assigned —
  moving one would change what guests were told over DHCP and strand every lease
  until it renewed.
- **ADR 0007's addresses are not what anything answers on now.** They were AWS's
  well-known VPC resolver addresses, which was a real ergonomic argument and is
  the one thing lost here; operators read the address out of the network rather
  than knowing it in advance. The index's two octets read directly out of the
  address to soften that.
- **The OVN `DNS` table is still in front**, unchanged. Losing a CoreDNS still
  degrades a network to "internal A/AAAA/PTR resolve, everything else does not"
  rather than to no DNS — and now one process failing degrades every network on
  the host that way, where before it was one. Backstopped by the same
  supervision and by OVN answering first for the records it can express.
