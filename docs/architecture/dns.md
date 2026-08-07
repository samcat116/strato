# DNS

Internal name resolution in Strato is built on **one control-plane-owned record
model** with swappable realization. This document describes that model — what a
zone is, where records come from, and how a zone's contents are assembled — and
sketches the layers that will realize it.

Status: **phase 1 (the record model) is implemented.** Zones, attachments,
records, and hostnames are fully manageable through the API and CLI, and the
assembler produces a correct record set for a zone. Nothing is realized
anywhere yet: no agent sees any of this, and no guest can resolve a Strato-owned
name. That arrives with phase 3.

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

- **The CoreDNS driver (phase 4) cannot put these in the forward zone's file.**
  It will need to synthesize a separate reverse zone from the same assembled
  set — filtering PTR entries out of the forward file and grouping them by
  their `in-addr.arpa` / `ip6.arpa` suffix. The assembler's output already
  carries everything needed to do that; what it does not carry is a *decision*,
  and this paragraph is it.
- **A hand-made reverse zone is not reconciled against derived PTRs.**
  `2.0.192.in-addr.arpa` is a legal `DNSZone` name, so an operator can create
  one and author PTRs in it. Those are never compared against the PTRs derived
  into a forward zone, so the write-time conflict check — careful everywhere
  else — has a blind spot here. Nothing today realizes either, so nothing is
  broken yet; closing it means deciding whether reverse space is a zone of its
  own at all, which is phase 3's business.

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

Four layers sit over the one record model. Only the model exists today.

1. **Control plane owns zones and records.** (This document. Implemented.)
2. **OVN `DNS` table** for internal A/AAAA/PTR, answered in the datapath by
   `ovn-controller`. No server process, no HA story, no failure domain.
3. **Per-network link-local CoreDNS** for the full record vocabulary, external
   forwarding, and isolated networks.
4. **Control-plane resolver / external publication** for ops-facing inbound
   resolution and public names.

Layers 2 and 3 compose without the guest knowing. OVN's `dns_lookup()`
intercepts UDP/53 *regardless of destination IP* and spoofs a reply; misses and
all TCP pass through. So the DHCP `dns_server` option can point at the CoreDNS
address and OVN transparently front-ends it. That is also what makes layer 3
safe to run without HA: if CoreDNS were the only resolver, losing an agent would
be a DNS outage; with OVN in front it degrades to "internal names still resolve,
external ones don't."

Two consequences for how records get written, when that time comes:

- **Records live on the network carrier, not the VM spec.** DHCP/DNS edits
  deliberately do not bump VM generations, so converged VMs never re-realize
  their NICs. The level-triggered network reconcile is what converges DNS rows,
  exactly as it does `DHCP_Options`.
- **DNS rows are written by the topology authority, not the VM's host.**
  `Logical_Switch.dns_records` is switch-scoped topology, so under
  `SiteNetworkAuthority` it belongs to the site's designated network controller
  agent — but a zone's records span every VM on the network across *all* agents.

## Open questions

- **Do sandboxes get derived records?** They share IPAM and the NIC shape, so
  it is nearly free, but they have no guest networking yet. Deferred.
- **Per-zone record count limits.** There is a constant cap
  (`DNSZone.maxRecordsPerZone`) rather than a `ResourceQuota` column, on the
  security-group precedent: dead quota plumbing would be worse than an honest
  cap.
- **Whether authored `PTR` records are user-writable or always derived.** They
  are writable today — see "Where reverse records live" for the reconciliation
  gap that leaves.

## References

- Models: `control-plane/Sources/App/Models/DNSZone.swift`,
  `DNSZoneNetwork.swift`, `DNSRecord.swift`, `DNSName.swift`
- Assembly: `control-plane/Sources/App/Services/DNSZoneAssembler.swift`
- Write rules: `control-plane/Sources/App/Services/DNSZoneService.swift`
- API: `control-plane/Sources/App/Controllers/DNSController.swift`
- Networking design (the L2/L3 substrate): [networking](./networking.md)
- IAM vocabulary: [iam](./iam.md)
