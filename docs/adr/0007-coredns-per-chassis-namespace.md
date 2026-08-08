# ADR 0007: The per-network resolver is a CoreDNS in the chassis namespace

- **Status**: Accepted with a known gap — landed STR-40, but see "The gap this
  decision opened" below, which may yet reverse it
- **Date**: 2026-08-08
- **Deciders**: Sam Schmitt
- **Scope**: where a network's DNS resolver runs on a hypervisor host, and what
  addresses it answers on
- **Affects**: STR-40 (roadmap #769 phase 4). STR-56 landed the metadata
  listener independently and in parallel; the two converged on the same
  per-namespace helper-process shape without either inheriting it from the
  other, which is itself evidence for the constraint ADR 0003 identified
- **Does not affect**: what the resolver *serves*. Zones, records and their
  assembly are control-plane concerns settled in phase 1, and the OVN `DNS`
  table (phase 3) is untouched — it still front-ends this resolver and is what
  makes running it without HA acceptable.

## Summary

Each network's resolver answers on **one well-known pair of link-local
addresses** — `169.254.169.253` and `fd00:ec2::253` — terminated in the
network's **existing per-chassis namespace** (`strato-md-<network-uuid>`, ADR
0003) on the **same OVN `localport`** the instance metadata service already
publishes from. One CoreDNS process runs per namespace, launched with
`ip netns exec`.

This is deliberately *not* what STR-40's issue proposed, and the difference is
worth recording because the issue's argument is a good one that a later decision
invalidated.

## Context

STR-40's issue argued for **a distinct address per network**, allocated
sequentially from `169.254.0.0/16` and stored on the network row, so that a
**single CoreDNS in the host namespace** could disambiguate by destination
address with one `bind`-ed server block per address — "no namespaces, no plugin,
no `setns`". The reasoning was sound on its own terms: a shared address is
identical on every network, source IP is ambiguous once tenant subnets overlap,
and recovering identity from a shared listener needs either a namespace per
network or `IP_PKTINFO` ingress-ifindex tricks CoreDNS does not expose.

Between that issue and its implementation, [ADR 0003](./0003-imds-chassis-namespace.md)
landed. It built exactly the machinery the issue was trying to avoid — one
network namespace per (chassis, network), terminating a `localport` — for
instance metadata, and it **rejected the host-namespace alternative explicitly**,
on three counts: a bug in route or rule programming leaks tenant traffic into the
host's own routing rather than into an empty namespace; there is no precedent
for it in this codebase, whereas namespaces have several; and there is no
precedent for it upstream either.

## Decision

Reuse the namespace. The resolver is a second service on the per-network chassis
foot, and because the namespace disambiguates, its address is a constant.

Three things follow, and each is a cost the issue's design would not have paid:

- **One CoreDNS process per network with a local NIC on this host.** Bounded by
  networks-per-chassis, not by VMs, and it is the shape ADR 0003 already
  anticipated when it wrote that per-namespace listening "does not compose
  cheaply with a single-process Swift agent" and named a helper process per
  namespace as one of the two ways to pay for it. OpenStack runs an haproxy per
  `ovnmeta-*` namespace for the same reason — and STR-56, deciding the same
  question for the metadata listener at the same time, arrived at a forked
  helper (`MetadataServerSupervisor`) independently. Two features reaching the
  same shape from opposite directions is the strongest available evidence that
  the constraint is real rather than an artifact of either design.
- **The agent supervises a long-lived child**, which it had never done before —
  libvirt owns QEMU and swtpm, Firecracker is driven over its API socket, and
  the agent itself assumes an external supervisor. So `ProcessRunner` gained a
  `spawn`, and the supervisor owns restart backoff, crash-loop reporting, and
  adoption of a process a previous agent incarnation started.
- **A packaging dependency.** CoreDNS is a Go binary the installer downloads,
  and a host without it reports `resolverCapable: false`.

## What reusing the namespace buys

- **Reply routing, which the issue's design does not address.** A guest's
  `10.0.0.5` may exist on three networks at once. In the host namespace, a reply
  from a socket bound to that network's distinct link-local address still needs
  a route to `10.0.0.5`, and there is exactly one such route in a namespace —
  so at most one of the three networks works, and which one depends on insertion
  order. Recovering it needs source-based policy routing: a table and a rule per
  network, in the host namespace, which is the VRF-shaped design ADR 0003
  rejected on blast radius. The chassis namespace already has a default route
  per family for precisely this.
- **No address allocation.** No column, no migration, no IPAM allocator, no
  sequential-vs-hashed decision (the issue correctly notes birthday collisions
  appear at a few hundred networks if hashed), and no per-network state to keep
  consistent between the control plane and the datapath.
- **A constant security-group carve-out.** The implicit non-overridable egress
  allow lives on the site-singleton drop port group and matches a fixed address.
  A per-network address would have made the match vary per switch, which means
  per-network port groups — "a whole new object lifetime", as the metadata
  carve-out's own doc comment puts it — for a rule that has to exist on every
  managed port anyway.
- **No new L3 foot in the host namespace.** The issue named this as its own
  blast radius ("this gives the hypervisor an L3 foot in every tenant network")
  and named netns-per-network as the known migration if isolation proved
  insufficient. That migration target already existed.

## Alternatives considered

### A distinct address per network, single host-namespace CoreDNS

The issue's proposal. Rejected for the reasons above: it re-opens the decision
ADR 0003 closed, needs policy routing the issue does not account for, and its
one advantage — a single process — is bought by moving every tenant network's L3
into the host namespace.

Worth stating plainly because the single-process advantage is real: on a host
running many networks, this design uses meaningfully less memory. If
networks-per-chassis grows to where a CoreDNS each is the binding constraint,
that is when to revisit — and the revisit is a socket-binding change, not an
addressing change, because nothing outside the agent knows how the address is
terminated.

### A resolver written in Swift, inside the agent

Removes the packaging dependency and the supervision machinery. Rejected because
it does not remove the *reason* for them: the listener still has to be
per-namespace, and `setns(2)` is per-thread while Swift's concurrency runtime
schedules continuations across a shared pool. An in-agent listener would mean
pinning a thread per namespace and guaranteeing no continuation ever moves,
which is a stronger constraint than "run a process per namespace" and a much
easier one to violate silently.

It would also mean writing a DNS server: a zone-file parser, an RRset store,
a forwarder with caching, EDNS, and TCP fallback. CoreDNS is a mature
implementation of all of it, and the zone-file format is a stable interface an
operator can read on the host.

### A distinct address per network, terminated in the chassis namespace

The hybrid. Rejected because it is strictly worse than either: it pays the
per-namespace process cost *and* the allocation cost, and buys nothing, since
the namespace already provides the identity the distinct address existed to
provide. The two coherent designs are the issue's and this one; mixing them is
not.

## Consequences

- **A network's resolver stops when its last local NIC leaves the host**, the
  same trigger the namespace itself has. A draining agent stops every resolver
  at shutdown so it does not keep answering for networks it no longer converges.
- **Enabling the resolver is a site-wide decision**, not a per-host one. The
  DHCP option pointing guests at the address is one row per network authored by
  the topology authority, while the process answering is per chassis, so the
  control plane withholds `resolverEnabled` unless every agent in the site
  reports `resolverCapable`. One un-provisioned host therefore holds the feature
  back for its whole site, which is why the agent's preflight reports a missing
  CoreDNS loudly.
- **The addresses are AWS's.** `169.254.169.253` / `fd00:ec2::253` are what the
  Amazon-provided VPC resolver answers on, adopted for the reason
  `InstanceMetadataEndpoint` adopted `169.254.169.254`: operators already know
  them, and inventing our own buys nothing. It also means the `fd00:ec2::/32`
  ULA overlap caveat that already applies to the metadata address applies here
  too (issue #1014).
- **The OVN `DNS` table is still in front.** OVN intercepts UDP/53 regardless of
  destination, so losing a CoreDNS degrades a network to "internal A/AAAA/PTR
  still resolve, everything else does not" rather than to no DNS. That is what
  makes a single non-HA process per network an acceptable thing to depend on,
  and it is the same argument layer 2 of the DNS design was built to support.

## The gap this decision opened

Recorded here rather than left for a future reader to rediscover: **this
decision lost upstream forwarding, and forwarding is the reason phase 4 exists.**

The chassis namespace has no egress of its own. Its only interface is the OVS
internal port on the tenant switch and its only addresses are link-local, so a
query to a public resolver either ARPs for that address on a tenant switch —
where nothing answers — or leaves via the network's gateway with a `169.254/16`
source that no SNAT rule matches and no router can route back to.

The issue's host-namespace design had this for free. A resolver in the host
namespace forwards through the *hypervisor's* egress, which is exactly what lets
a guest on a network with `externalAccess: false` resolve a public name — the
headline bug STR-40 was filed to fix.

The comparison in "What reusing the namespace buys" above is therefore
incomplete: it weighed attribution, reply routing, allocation cost and
security-group shape, and did not weigh egress, where the rejected design wins
outright. `docs/architecture/dns.md` §The forwarding gap lists the three ways
out and what each costs. Two of them keep this decision; the third reverses it.
Whichever is chosen should be recorded as an amendment here.

What this decision *does* deliver as it stands is the full record vocabulary —
CNAME, TXT and SRV, which the OVN `DNS` table cannot express — served from a
namespace that correctly attributes and routes. That is real, and it is why
`resolver_enabled` ships as an opt-in rather than being reverted.
