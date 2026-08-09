# DNS

Internal name resolution in Strato is built on **one control-plane-owned record
model** with swappable realization. This document describes that model — what a
zone is, where records come from, and how a zone's contents are assembled — and
sketches the layers that will realize it.

Status: **phases 1 and 3 are implemented; phase 4 is partial.** Zones,
attachments, records, and hostnames are fully manageable through the API and
CLI; the assembler produces a correct record set for a zone; and the A/AAAA/PTR
subset of that set is realized into the OVN `DNS` table by each network's
topology authority, so a guest resolves its peers by `<hostname>.<zone>` in the
datapath.

Phase 4's resolver serves the **full record vocabulary** — CNAME, TXT and SRV,
which the datapath cannot express — and **forwards everything else through the
hypervisor's own egress**, which is what lets a guest on a network with no
external access resolve a public name at all. Inbound resolution from outside the
overlay (phase 5) and external publication (phase 6) are untouched.

## What exists before this

Resolver-setting delivery only. `LogicalNetwork.dnsServers` / `domainName` ship
over the wire and reach the guest on whichever path addresses its NIC: DHCP NICs
get them as OVN `DHCP_Options` (`dns_server` plus `domain_name`/`domain_search`,
`agent/Sources/StratoAgentCore/DHCPOptions.swift`), and statically addressed NICs
get them as the `nameservers` `addresses`/`search` block of the cloud-init
network-config (`CloudInitProvisioner.networkConfigYAML`). They are seeded with
public resolvers so guests can look up *public* names. Nothing resolves a
Strato-owned name, and the OVN `DNS` table is never touched.

`domainName` is held to the same grammar as a zone name (`DNSName.normalizedZoneName`),
so the two names in this model agree on one spelling. That is also a safety
property rather than tidiness: neither destination carries the value as text —
one is a netplan document keyed by indentation, the other an option map with its
own quoting — so an unvalidated domain edits the structure around it rather than
appearing in it (issue #876).

## Why the control plane owns the record model

The control plane already owns IPAM (`IPAMService`), so it is the only
component that knows every name → address mapping in the deployment. An agent
knows its own VMs; only the control plane knows all of them. That makes the
record model a control-plane concern and realization a driver — which is the
same split OpenStack draws between ML2/OVN (writes the NB `DNS` table) and
Designate (a control plane for DNS, driving pools of real nameservers).

## The model

### Zones

A `DNSZone` is a **first-class, arbitrarily-named, project-owned** resource.

| Field | Notes |
|---|---|
| `name` | An FQDN — `acme.internal`, `corp.example.com`. Lowercased, no trailing dot. |
| `project_id` | The owner. Unique on `(project_id, name)`. |
| `description`, `created_by_id`, timestamps | |

Two decisions here are load-bearing:

- **Names are not constrained to `.internal`.** A tenant may serve
  `corp.example.com` internally. That overlap with the public name is not a
  mistake to prevent — it is exactly what makes split-horizon possible later.
- **Uniqueness is per project, not global.** Two tenants may both serve
  `corp.example.com` without seeing each other's records.

### Attachment to networks

`DNSZoneNetwork` is a many-to-many join between zones and logical networks.
Attaching a zone to a network means *"VMs on this network can resolve this
zone."* This is Route 53's private-hosted-zone shape, and it maps directly onto
`Logical_Switch.dns_records` being a **set** of weak references — one switch can
carry several zones' rows.

`LogicalNetwork.primaryDNSZone` (nullable) is the separate, *singular* question:
which zone do this network's VMs **register into**. It must name one of the
network's attached zones. A network with attachments but no primary resolves
those zones without registering into them — the natural shape for a shared
services zone.

Keeping the two apart is what makes derived-record placement unambiguous while
attachment stays many-to-many.

### Hostnames

`VM.hostname` is a nullable RFC 1123 label, defaulted at create time from a
slugified `VM.name`.

It is an explicit stored field rather than something derived on read, for two
reasons. A slug is lossy, so recomputing it would let a VM *rename* silently
move that VM's records out from under whatever depends on them. And operators
need to pick names a slug cannot produce.

The *guest* configures itself under the same label: it reaches the agent on
`DesiredVMState.metadata.hostname` and becomes the seed ISO's `local-hostname`
(see [agent](./agent.md)). Nothing on either side may fabricate a hostname for
a VM that has none, because a fabricated name is one this zone does not
publish — the guest would then answer to a name its own records don't name.

A hostname must be unique within each zone the VM registers into. Two write
paths enforce that differently, on purpose:

- **Creation defaults** are disambiguated with a numeric suffix (`web-server`,
  `web-server-2`). Two VMs called "web server" is an ordinary thing to do, and a
  `409` on VM create over an implicit DNS label would be baffling.
- **Explicit hostnames** — on create or update — answer `409` on a collision.
  The caller named the value, so the conflict is worth reporting.

Making a zone a network's primary is also checked: it retroactively registers
every VM already on that network, so it is refused when those VMs would collide.

### Records

`DNSRecord` holds user-authored entries: `zone_id`, `name` (relative to the
zone, `@` for the apex), `type`, `value`, `ttl`, `view`.

The type vocabulary is `A`/`AAAA`/`CNAME`/`TXT`/`SRV`/`PTR` — deliberately
wider than any backend realizes today. The OVN driver handles A/AAAA/PTR only;
realization drivers reject what they can't do with a clear error. An operator
authoring a `TXT` before the resolver phase lands should get "no backend on this
network realizes TXT yet", not a validation error implying Strato will never
support it.

`view` (`internal` / `external` / `both`, default `both`) is carried now so
split-horizon isn't a retrofit onto a column that doesn't exist. Nothing
consumes it until external publication.

### Text bounds

Zone and record text is bounded at the request boundary and again by a `CHECK`
constraint on the column (STR-198, `BoundDNSTextColumns`), on the terms
`docs/api-reference.md` describes for every other resource. Names take the
*grammar's* ceiling rather than the generic 128 — `DNSName.maxNameLength`, RFC
1035's 253 — because a name held to 128 would refuse zones that resolve today. A
record's `value` is bounded by its type in `DNSZoneService.validatedValue`, and
the column carries only the generic free-text ceiling above it, deliberately
loose: a backstop that refused RDATA the API accepted would turn a caller's
success into a 500.

This matters more here than for a name that stays in a table. A zone name is
rendered into every FQDN the zone answers on, realized into the OVN `DNS` table
and into a per-network CoreDNS zone, and compared on every reconcile through the
`recordsHash` in `external_ids`.

## Assembly: derived ∪ authored

A zone's record set is computed on demand and **never stored**
(`DNSZoneAssembler`). Persisting a second copy would just be a cache to
invalidate on every VM lifecycle event.

**Derived** — for every VM on a network whose primary zone is this zone:

- `<hostname>.<zone>` → all its allocated addresses, as an `A` entry and an
  `AAAA` entry
- the matching `PTR` at the `in-addr.arpa` / `ip6.arpa` name

A VM with NICs on two networks that share a primary zone publishes both NICs'
addresses under one name, which is the DNS-correct answer for a multi-homed
host.

**Authored** — the `DNSRecord` rows.

Both mature implementations of this idea auto-generate only A and PTR
(OpenStack Designate, Proxmox's PowerDNS plugin), which is why CNAME, TXT, and
SRV live in the authored tier rather than being synthesized from anything.

### The output shape

`AssembledDNSRecord` is `(name, type, values, ttl, view, origin)`. Values are a
*list* because an RRset genuinely is one. Keeping the address family in `type`
rather than flattening both families into one blob is what makes the output
realization-agnostic:

- the **OVN** driver joins the `A` and `AAAA` values for a name into the single
  space-separated string `Logical_Switch.dns_records` takes;
- a **CoreDNS** zone file keeps them apart.

Neither shape is baked into the assembler. Both drivers consume the same output.

TTL and view are properties of the **RRset**, not of its member records
(RFC 2181 §5.2), so the assembler emits exactly one entry per `(name, type)`
and the write path refuses a record whose TTL or view disagrees with the set it
joins. That is a deliberate narrowing of what the schema can express — the
unique index is `(zone_id, name, type, value)`, so mixed TTLs are *storable* —
and it is enforced because neither planned driver could realize them: OVN keeps
one row per name, and a zone file writes one TTL per RRset. Editing a TTL or
view through the record API applies it to the whole set. For rows that predate
the rule, assembly degrades safely: lowest TTL and narrowest view win, so a
disagreement caches less and publishes less rather than more.

### Where reverse records live

Derived PTRs are emitted **into the forward zone's record set**, under names
like `20.1.168.192.in-addr.arpa` that are not beneath the zone's own name. That
is out of bailiwick in zone-file terms, and it is deliberate: the OVN `DNS`
table is a flat name → value map with no notion of a zone apex, so reverse and
forward entries are co-tenants of one row set and nothing needs to own
`in-addr.arpa`.

Two consequences to settle before the driver phases, rather than in them:

- **The CoreDNS driver cannot put these in the forward zone's file.** It
  synthesizes a separate reverse zone from the same assembled set — filtering
  PTR entries out of the forward file and grouping them by their
  `in-addr.arpa` / `ip6.arpa` suffix. Done in phase 4; see "Realizing a zone
  into CoreDNS" below.
- **A hand-made reverse zone is not reconciled against derived PTRs.**
  `2.0.192.in-addr.arpa` is a legal `DNSZone` name, so an operator can create
  one and author PTRs in it. Those are never compared against the PTRs derived
  into a forward zone, so the write-time conflict check — careful everywhere
  else — has a blind spot here.

  **Phase 4 settles this, and the answer is that reverse space is not a zone of
  its own.** Both drivers treat a PTR as a record like any other, wherever it
  was authored: the OVN driver puts derived and authored PTRs alike into one
  flat name → value space, and the CoreDNS driver regroups *both* into the same
  synthesized reverse zone. So a hand-made `2.0.192.in-addr.arpa` zone is not a
  second authority for that space — its records simply join the same pool, and
  a name published twice resolves to whichever the merge kept (derived wins,
  per "Conflict handling" below).

  The consequence worth naming is that creating such a zone buys nothing the
  record API does not already give you, and the write-time conflict check still
  will not warn you when its contents shadow a derived PTR. That is a gap in the
  *warning*, not in the outcome.

### Conflict handling

An authored record that collides with a derived one is **rejected at write
time** with a clear error, rather than being silently shadowed — a shadowed
record is the worst outcome available, because the API reports a name the
resolver never answers with and nothing says why. CNAME's exclusivity rule
(RFC 1034 §3.6.2 — a CNAME owner may hold no other data) is enforced against
both tiers.

The assembler still prefers derived on a collision, as the safe direction for
the race the write-time check cannot close (a VM created between check and
write): a machine's own address answering for its own name is the one thing that
must not silently break.

## API, authz, CLI

`/api/dns-zones` — zone CRUD, `…/{id}/records` for authored records,
`…/{id}/networks` for attachments, and `…/{id}/recordset` for the assembled
view (exactly what a realization driver will consume).

Authorization is ordinary: `dns_zone` and `dns_record` are Cedar resource types
with a `dns:*` action group (`read`/`list`/`create`/`update`/`delete`/`attach`/
`detach`), gated by `AuthorizationMiddleware` like every other resource, with
no controller-local fast paths. A zone's container is its project; a **record's
container is its zone** — unlike the snapshot types, whose container is the
project because they only *reference* their parent. A record cannot exist
without a zone, so delegating a zone carries its records.

Attaching a zone to a network additionally requires `update` on the network:
attachment changes what that network's VMs resolve, so owning the zone alone is
not enough (the volume/floating-IP rule).

CLI: `strato dns zone` and `strato dns record`, plus `strato network create
--dns-server/--domain-name` and `strato network update` for the DHCP-delivered
resolver settings and the primary-zone pointer.

## Realization: the layers above this

Four layers sit over the one record model; the first two exist today. The
layers are **not** the roadmap's phases — there are four of these and six of
those, because phase 2 was a dependency (`swift-ovn`'s `DNS` CRUD) that added no
layer of its own. Each layer names the phase that built it:

1. **Control plane owns zones and records** (phase 1). This document.
   Implemented.
2. **OVN `DNS` table** for internal A/AAAA/PTR, answered in the datapath by
   `ovn-controller` (phase 3). No server process, no HA story, no failure
   domain. Implemented — see "Realizing a zone into OVN" below.
3. **Per-network link-local CoreDNS** for the full record vocabulary, external
   forwarding, and isolated networks (phase 4). Implemented — see "Realizing a
   zone into CoreDNS" below.
4. **Control-plane resolver / external publication** for ops-facing inbound
   resolution and public names (phases 5 and 6).

Layers 2 and 3 compose without the guest knowing. OVN's `dns_lookup()`
intercepts UDP/53 *regardless of destination IP* and spoofs a reply; misses and
all TCP pass through. So the DHCP `dns_server` option can point at the CoreDNS
address and OVN transparently front-ends it. That is also what makes layer 3
safe to run without HA: if CoreDNS were the only resolver, losing an agent would
be a DNS outage; with OVN in front it degrades to "internal names still resolve,
external ones don't."

## Realizing a zone into OVN (phase 3, wire v36)

Each zone attached to a network becomes one row in the OVN Northbound `DNS`
table, referenced from `Logical_Switch.dns_records` on every attached network's
switch. `ovn-controller` answers `dns_lookup()` from those rows in the
datapath, so there is no resolver process to run and nothing to make highly
available.

Two decisions govern how the rows get written, and both were settled by the
model above rather than by the driver:

- **Records live on the network carrier, not the VM spec.** DHCP/DNS edits
  deliberately do not bump VM generations, so converged VMs never re-realize
  their NICs. `DesiredStateMessage.dnsZones` — not `NetworkSpec` — is what
  carries them, and the level-triggered network reconcile is what converges the
  rows, exactly as it does `DHCP_Options`.
- **DNS rows are written by the topology authority, not the VM's host.**
  `Logical_Switch.dns_records` is switch-scoped topology, so under
  `SiteNetworkAuthority` it belongs to the site's designated network controller
  agent — but a zone's records span every VM on the network across *all*
  agents. So `DesiredStateAssembler` scopes *which zones* an agent is sent by
  its topology authority, and assembles each zone's records fleet-wide. It is
  the one list in the sync whose contents are not the receiving agent's own
  workloads. A non-authoritative agent is sent `nil`, never `[]`, so a
  controller handover cannot produce two writers reading each other's rows as
  garbage.

Because a VM created on agent A changes a zone realized by agent B, VM
lifecycle mutations already ring the doorbell for the site's network controller
alongside the VM's own agent (`AgentService.syncDesiredState`). Edits to the DNS
model itself — records, attachments, a zone rename, a VM's hostname — ring the
fleet-wide doorbell instead: a zone's blast radius is every network it is
attached to, which may span sites, so the affected agents are not known at the
mutation site. Every ring is a latency optimization; the agent's own periodic
re-fetch is the correctness backstop.

Agent-side (`agent/Sources/StratoAgentCore/DNSZoneRealization.swift`):

- **Ownership** is `(strato-managed, dns-zone-id)` in `external_ids` — never the
  row's contents and never the zone *name*, which is unique only within a
  project. An operator's own rows in the shared `DNS` table carry no marker, so
  they are never adopted, rewritten, or torn down. Same convention as
  `DHCPRowIdentity`.
- **Only A/AAAA/PTR are realized.** A name's A and AAAA values are joined into
  the one space-separated string OVN's map takes; a PTR's reverse name maps to
  its target. CNAME, TXT, and SRV produce a non-fatal diagnostic naming the
  types that were not realized, rather than failing the sync — they are phase
  4's job. Values are re-validated against their type for `DHCPOptions`'
  reason: the whole zone is one OVSDB row, so one unparseable value would
  otherwise cost every name in it.
- **An unchanged zone costs no OVSDB transaction.** The control plane's
  `recordsHash` is stamped on the row and compared on the next sync, because a
  zone's record map is O(VMs on its networks) and ships on every sync. The
  stamp is never load-bearing for correctness: the flattened records are
  compared too, so a hand-edited row or an agent whose realization changed
  across an upgrade still heals.
- **Teardown is `observed − desired`** over managed rows, and deleting a `DNS`
  row is enough to unpublish it — `Logical_Switch.dns_records` is a weak
  reference set, so ovsdb-server drops the UUID from every switch naming it.

## Realizing a zone into CoreDNS (phase 4, wire v37)

The OVN table answers A/AAAA/PTR because that is all
`Logical_Switch.dns_records` can hold. Phase 4 puts a real resolver behind it,
which is what makes CNAME, TXT and SRV resolve — and, more urgently, what fixes
**external** resolution on a network without external access.

That last part is the bug this phase exists for. OVN is an *interceptor*, not a
forwarder: a miss is released toward whatever `dns_server` the guest was handed
over DHCP, and on a network whose `externalAccess` is off there is no SNAT and
therefore no path to a public resolver. Those guests could resolve nothing
external at all. A resolver on the guest's own hypervisor forwards on its
behalf and closes it. OpenStack hit exactly this moving from ML2/OVS, where
dnsmasq had been forwarding.

### Where it runs

**In the host network namespace**, on an OVN `localport` of its own —
`lsp-<network-uuid>-resolver`, a sibling of the one instance metadata publishes
from. See [networking](./networking.md) §Link-local services.

**Running in the host namespace is the load-bearing decision**, because it is
what makes forwarding possible at all. A resolver in the network's chassis
namespace (where [ADR 0007](../adr/0007-coredns-per-chassis-namespace.md) first
put it) has only link-local addresses and no egress: a query to a public resolver
either ARPs for that address on a tenant switch where nothing answers, or leaves
with a `169.254/16` source that no SNAT rule matches. A process in the host
namespace forwards through the hypervisor's own egress, which needs building
nothing. That is the whole bug this phase was filed for.
[ADR 0008](../adr/0008-resolver-in-host-namespace.md) records the reversal, and
why instance metadata does **not** follow it out — metadata's security model *is*
source-IP attribution, which is exactly what the namespace provides and what a
shared namespace would destroy, and metadata needs no egress at all.

**So each network gets its own addresses**, derived from a single index the
control plane allocates fleet-wide (`ResolverAddressAllocator`, column
`resolver_index`) and stored on the network row: `169.254.<hi>.<lo>` and
`fd00:ec2:1::<index>`, both computed by `NetworkResolverEndpoint`. ADR 0007's
single well-known pair worked only because each namespace was a separate address
space; in one shared namespace they collide the moment a hypervisor runs NICs on
two networks. Allocation is sequential rather than hashed from the network id —
~65k usable addresses means a hash collides at a few hundred networks, and a
collision is two networks told to resolve at the same address on a host that
terminates both. `169.254.169.254` and `.253` are excluded: the metadata service
owns the first, and the second is ADR 0007's constant, which a host mid-upgrade
may still hold.

**Replies are routed by policy routing.** The one thing the namespace genuinely
gave the resolver was that a reply could only leave the right way. In the host
namespace a reply sourced from `169.254.x.y` would follow the `main` table and go
out the wrong interface. So each resolver port gets a routing table of its own
(`20_000 + index`) holding a default route out that port, and an
`ip rule from <resolver-address> lookup <table>`. The source address is unique
per network by construction, so the rule cannot be ambiguous; the rule is deleted
before it is added so a re-reconcile does not stack duplicates, and torn down
*before* the OVS detach so it never outlives the port it points at.

**The host-namespace foot is fenced explicitly**, because it is one. Forwarding
is off on the interface for both families, so the host cannot become a router
between a tenant network and anything else it can reach; `rp_filter` is loose,
because strict reverse-path filtering would drop the guest queries the
policy-routed table has no return route for; `arp_ignore=1` / `arp_announce=2`
stop the host answering ARP here for addresses on its *other* interfaces, which
the kernel default would otherwise do and which `forwarding=0` does not prevent
(traffic to a local address is delivered, not forwarded); `accept_ra=0` keeps a
guest's Router Advertisements out of the host's routing table; and the `ip rule`
matches only the resolver's own source address. All of them are asserted in
`ResolverHostPortPlanTests` rather than left to a reviewer's memory. The ingress
`tc` policer that caps guest packet rate applies here too.

One of those is only half ours: the kernel validates a source against
`max(conf.all.rp_filter, conf.<dev>.rp_filter)`, so a host whose
`net.ipv4.conf.all.rp_filter` is `1` stays strict here regardless and drops
every guest query. `HostPreflight` reports that as an advisory check —
[ADR 0008](../adr/0008-resolver-in-host-namespace.md) explains why the agent
does not simply lower it.

### What the agent renders

`CoreDNSZoneRenderer` is pure, golden-file tested, and produces **one host-wide
`Corefile`** — a server block per network, bound to that network's own address
pair — plus one zone file per zone under `<config_dir>/zones/<network-uuid>/`.
The zone files are namespaced by network because two networks may both hold a
zone called `corp.example.com` with different contents. That a single CoreDNS
will serve the same zone name from different bind addresses was verified
empirically before the design committed to it. Per block:

- **One forward zone file per attached zone**, with a synthesized SOA and NS —
  CoreDNS's `file` plugin refuses a zone without an SOA. Both point at
  `ns.strato.invalid.`, deliberately outside every zone: an in-zone `ns.<zone>`
  would collide with a tenant's own record, and a `CNAME` authored at that name
  would put a CNAME beside other data and make CoreDNS refuse the entire zone.
- **Synthesized reverse zones.** PTRs are filtered out of the forward file and
  regrouped at the `/24` (`in-addr.arpa`) and `/64` (`ip6.arpa`) boundary
  derived from the PTR name itself — not from the network's subnet, which the
  renderer does not have and which would be the wrong key for a zone attached to
  two networks.
- **A catch-all `.` block** with `forward . <upstreams>`, `cache`, and `errors`.
  An empty upstream list renders no `forward` at all: the resolver answers its
  zones and REFUSEs everything else. Synthesizing a public default would put a
  tenant's queries somewhere the operator never chose.

Three things it refuses to emit rather than emit wrong, on
`OVNDNSRecords.flatten`'s reasoning in its sharper form — a zone file is parsed
as a whole, so one bad line costs every name in it: a `CNAME` coexisting with
other data at the same owner, a TXT value carrying a quote or backslash (which
would round-trip differently through the OVN driver if escaped here), and any
value that fails its type's shape check. Each is a logged diagnostic.

The serial is derived from the zone's content digest — the control plane's
`recordsHash` for a forward zone, a locally computed one for a synthesized
reverse zone. It changes when and only when the zone does, which is what a
serial is for. It is **not monotonic**, which would matter if anything ever
transferred these zones; nothing does.

### What travels, and what gates it

`DesiredDNSRecord` gains a `ttl` at wire v37. Phase 3 deliberately left it off —
an OVN `DNS` row has nowhere to put one — and a zone file writes one TTL per
RRset, so this is the field that was waiting for a reader. It is folded into
`recordsHash`, which moves every stamp once on upgrade and heals with one
rewrite per zone.

**Zone delivery widens past the topology authority.** OVN `DNS` rows are
switch-scoped topology and only the site's controller may write them, but the
CoreDNS answers wherever the guests are. So from v37 a zone is sent to any agent
that either authors an attached network *or* runs a local NIC on one, and the
agent decides which half it realizes from `networksAuthoritative` — which it
already receives. The records themselves stay assembled fleet-wide, as they have
since phase 3.

**`LogicalNetwork.dnsServers` is redefined, not replaced.** With the resolver on,
the DHCP `dns_server` option becomes the resolver's link-local address and the
configured list becomes the resolver's *upstream forwarders*. The column, its
validation, and the wire field are unchanged; only the consumer moves. That is
safe across skew in both directions because a pre-v37 agent never sees
`resolverEnabled` and keeps handing the list to guests verbatim, which is exactly
the old behaviour. The API and UI say which reading applies.

**The capability is site-wide, not per agent.** The control plane withholds
`resolverEnabled` unless *every* agent registered to the site reports
`AgentRegisterMessage.resolverCapable`. The DHCP
option pointing guests at the resolver is one row per network authored by the
topology authority, while the process answering runs per host — so one host
without CoreDNS would give that network DNS that works until a VM lands
somewhere else, which presents as an intermittent network fault rather than as
the missing dependency it is. Offline agents count; a host that is down is one
that will come back.

### Forwarding

A miss on the zones a network holds is forwarded to the upstreams in
`LogicalNetwork.dnsServers`, through the **hypervisor's** egress — its routes,
its NAT, its own resolvers. That is what closes the bug this phase was filed for:
a guest on a network with `externalAccess: false` has no path to a public
resolver of its own, and does not need one, because the query leaves the host as
the host's.

This is the whole reason the resolver runs where it does; ADR 0007's chassis
namespace could not do it, and
[ADR 0008](../adr/0008-resolver-in-host-namespace.md) is the reversal. An empty
upstream list still forwards nowhere by design — the resolver then answers its
own zones and REFUSEs the rest.

### Degradation

If CoreDNS dies, OVN keeps intercepting UDP/53 whatever the destination and
keeps answering A/AAAA/PTR from its own table. So the failure mode is "internal
names still resolve, external ones don't" rather than "no DNS" — which is what
makes running this without HA acceptable, and is the same argument layer 2 was
built to support. One process now serves every network on the host, so that
degradation is host-wide rather than per network; OVN answering first for what it
can express is what keeps the blast radius tolerable.

The supervisor restarts an exited CoreDNS with exponential backoff capped at a
minute, and reports a crash loop after three consecutive failures. A record edit
costs no restart at all: the `file` plugin watches its zone files and the
Corefile carries `reload`.

A rollback below v37 tears down the resolver's localport, its addresses and its
policy-routing rules while leaving metadata's port untouched, and reverts the
DHCP row in the same sync, so guests are told to use the real resolvers again at
their next lease. That is a consistent rollback rather than a half-state. Each of
the two localports is protected from teardown by *its own* service's silence, so
a sync with no opinion about the resolver does not reap the metadata port and
vice versa.

### Reachability

Two things could silently break DNS for every guest and are handled explicitly:

- **Security groups.** The site-singleton drop group carries four
  non-overridable `allow-related` egress ACLs to the resolver address at
  priority 1003 — v4/v6 × udp/tcp, because an OVN match is per family *and* per
  protocol and a resolver that answers only UDP breaks every truncated response.
  Without them a default-deny egress policy would blackhole DNS. `dropGroupRevision`
  was bumped to 5 so the drop group is rewritten on upgrade.
- **Routes.** The resolver address is link-local and belongs to no subnet, so it
  needs an advertised route: DHCP option 121 for v4, and the NoCloud
  `network-config` for statically addressed NICs and for all v6 (there is no
  DHCPv6 counterpart to option 121). Same mechanisms, same one-NIC-per-family
  rule, as the metadata routes.

Guests may push at most `[resolver] rate_limit_pps` packets per second at each of
a network's link-local service interfaces — 1024 by default, AWS's ceiling —
policed on ingress with `tc`. The cap is per interface rather than per service,
so metadata and DNS get one each: they are separate devices in separate
namespaces since ADR 0008. What it protects is the hypervisor rather than either
service, which is why the resolver's foot needs it most — one CoreDNS in the
host's own namespace answers for every network on the host.

## Open questions

- **Do sandboxes get derived records?** They share IPAM and the NIC shape, so
  it is nearly free, but they have no guest networking yet. Deferred.
- **Per-zone record count limits.** There is a constant cap
  (`DNSZone.maxRecordsPerZone`) rather than a `ResourceQuota` column, on the
  security-group precedent: dead quota plumbing would be worse than an honest
  cap.
- **Whether authored `PTR` records are user-writable or always derived.** They
  are writable today. Phase 4 settled *where* they land — both drivers pool them
  with the derived ones — but the write-time conflict check still does not warn
  when a hand-made reverse zone shadows a derived PTR. See "Where reverse
  records live".

## References

- Models: `control-plane/Sources/App/Models/DNSZone.swift`,
  `DNSZoneNetwork.swift`, `DNSRecord.swift`, `DNSName.swift`
- Assembly: `control-plane/Sources/App/Services/DNSZoneAssembler.swift`
- Write rules: `control-plane/Sources/App/Services/DNSZoneService.swift`
- API: `control-plane/Sources/App/Controllers/DNSController.swift`
- Sync assembly: `DesiredStateAssembler.desiredDNSZones`; wire types in
  `shared/Sources/StratoShared/ReconciliationProtocol.swift`
- OVN realization: `agent/Sources/StratoAgentCore/DNSZoneRealization.swift`,
  driven through `NetworkActuator` by `NetworkServiceLinux`
- CoreDNS realization: `agent/Sources/StratoAgentCore/CoreDNSZoneRenderer.swift`
  (pure), `ResolverSupervisionPolicy.swift` (pure),
  `agent/Sources/StratoAgent/ResolverSupervisor.swift` (processes)
- Addresses: `shared/Sources/StratoShared/NetworkResolverEndpoint.swift`;
  allocation in `control-plane/Sources/App/Services/ResolverAddressAllocator.swift`
- Host foot: `agent/Sources/StratoAgentCore/ResolverHostPortPlan.swift`, and
  [ADR 0008](../adr/0008-resolver-in-host-namespace.md) — with
  [ADR 0003](../adr/0003-imds-chassis-namespace.md) /
  [ADR 0007](../adr/0007-coredns-per-chassis-namespace.md) for the chassis
  namespace it moved out of
- Networking design (the L2/L3 substrate): [networking](./networking.md)
- IAM vocabulary: [iam](./iam.md)
