# Networking Architecture &amp; Roadmap

> **Status:** Design / roadmap document. Describes the current state of Strato
> networking (L3 and multi-node are implemented) and the intended evolution
> toward multi-site connectivity. Sections marked _(future)_ are not yet
> implemented.

Strato's networking is built on **OVN/OVS** on Linux (via
[SwiftOVN](https://github.com/samcat116/swift-ovn)) and QEMU user-mode SLIRP on
macOS (dev/test only). The control plane owns **IPAM** and network CRUD; agents
translate desired state into the OVN/OVS data plane on each hypervisor.

This document covers where we are, the target deployment topology (a SaaS
control plane orchestrating customer-run sites), the layered model we are
building toward, and a phased roadmap.

## Current state (as of this writing)

Most of the layered model below is implemented. What exists today:

- **First-class networks.** Every `LogicalNetwork` belongs to exactly one
  project (issue #765) — names are unique only within their project, IPAM
  (`IPAMService`) allocates per network id — and networks ride the periodic
  sync as `DesiredNetworkState` entries, so topology is level-triggered from
  desired state rather than a side effect of VM placement (§Phase 1).
- **L3 within a site.** Per-project logical routers, cross-switch east-west,
  and SNAT egress through an operator-configured uplink (§Phase 1).
- **Multi-node sites.** A shared per-site OVN central
  (`deploy/ovn-central/`) with a CP-designated network-controller agent as
  the single topology writer; one logical network spans a site's nodes over
  geneve (§Phase 2).
- **Floating IPs**, realized as distributed `dnat_and_snat`, with opt-in BGP
  advertisement via OVN dynamic routing + FRR (§Phase 3).
- **Security groups** as OVN ACLs on port groups, with a site-wide
  default-drop group (§Security groups).
- **IPv4/IPv6 dual-stack**: a generated ULA /64 alongside each network's v4
  subnet by default, per-family NIC address rows, RA + DHCPv6 delivery.
- **Instance metadata dataplane**: the per-VM metadata document rides the
  sync (wire v26), the OVN localport + per-chassis namespace exist (wire
  v27), and guests are told how to reach the addresses (STR-53) — see
  §Instance metadata (IMDS).

What genuinely remains missing (details in §Known gaps):

- **No guest-visible metadata service yet**: nothing listens in the metadata
  namespace (STR-56), and on a network with security groups attached the
  implicit egress allow that would let a guest reach it is still missing
  (STR-54).
- **Sandbox guest networking** is plumbed but off the wire — the guest can't
  configure the NIC (STR-101) and the fleet-wide flag awaits its per-agent
  gate (STR-103).
- **CP-hosted ingress** (§Phase 4) and **inter-site L3** (§Phase 5) are
  unbuilt.
- **DNS realization**: zones are modeled control-plane-side, but guests still
  get DHCP option delivery only; the OVN `DNS` table is not yet written (see
  [dns](./dns.md)).

## Target deployment topology

The product shape is a **SaaS control plane** orchestrating **customer-run
sites**. A **site** (a.k.a. availability zone) is a group of the customer's
hypervisors that share — or can be made to share — a routable underlay.

```
                    ┌─────────────────────────────┐
                    │   SaaS Control Plane          │
                    │   (orchestration + IPAM +     │
                    │    ingress edge, §Layer 2)    │
                    └───────────┬─────────────────┘
                        WSS (agent dials out)
              ┌─────────────────┼─────────────────┐
              │                 │                 │
        ┌─────┴─────┐     ┌─────┴─────┐     ┌─────┴─────┐
        │  Site A   │     │  Site B   │     │  Site C   │
        │ (OVN dep) │◄───►│ (OVN dep) │◄───►│ (OVN dep) │
        └───────────┘ BGP └───────────┘ BGP └───────────┘
          east-west via direct site-to-site tunnels (§Layer 0)
```

Two planes, deliberately separate:

- **Control plane (CP ↔ agent):** the existing WebSocket. The agent dials
  _out_ over WSS, so it works behind NAT with no inbound config. Orchestration
  **does not** ride the data-plane VPN.
- **Data plane (hypervisor ↔ hypervisor):** OVN geneve tunnels, which require
  chassis encap IPs to be mutually routable — provided by the underlay
  (§Layer 0).

### Division of responsibility

- **Control plane owns:** IPAM, network/router/floating-IP _desired state_, and
  pushing it to sites over the WebSocket. It is an orchestrator, **not** an OVN
  participant.
- **Each site owns its own OVN deployment** (one NB/SB/northd per site) — the
  site is the OVN blast radius. This preserves fault isolation between sites and
  between tenants, and keeps the southbound DB off the WAN.
- **Agents own** the local data plane: TAP creation, `iface-id` port binding
  (always local to the chassis, even when the NB is shared), and chassis
  bootstrap.

IPAM's allocation is what the control plane *assigned* a NIC (`vm_interface_addresses`).
What the guest actually *configured* — DHCP leases, IPv6 SLAAC, manual changes —
is only visible through the QEMU guest agent, reported per-MAC and persisted
separately (`vm_interface_observed_addresses`) so the API and UI can show
observed alongside allocated (issue #563). See
[agent](./agent.md#qemu-guest-agent-qga).

## The layered model

We build connectivity as four independent layers. Keeping them separate is what
lets a datacenter site and a NAT'd/scattered site use different underlays while
sharing everything above.

### Layer 0 — Underlay (chassis reachability)

OVN needs chassis encap IPs to be mutually routable; it does **not** build this
itself. Options, pluggable per site:

- **LAN / customer-provided routing** — nodes already on one routed network.
  Nothing for Strato to do.
- **Mesh VPN (WireGuard)** — for nodes behind NAT or across the WAN. A managed
  mesh (Tailscale / Netbird / Netmaker style) gives NAT traversal, key
  rotation, and roaming; rolling raw WireGuard means owning peer discovery and
  NAT hole-punching ourselves.
- **BGP-routed / EVPN fabric** _(datacenter sites)_ — leaf-spine L3 fabric with
  ECMP and BGP/BFD failover. OVN rides on top unchanged; full EVPN Type-2/-5 is
  only warranted when the fabric must carry L2/VTEP state for non-OVN endpoints.

Contract each driver must satisfy: **chassis encap IPs are mutually routable.**

**Topology guidance:** within a site, LAN or a local mesh. Between sites, use
**direct site-to-site tunnels** for east-west — do _not_ hairpin east-west
through the SaaS (latency + SaaS bandwidth cost). A spoke to the SaaS edge
exists only for CP-hosted ingress (§Layer 2).

**MTU is a footgun:** WireGuard (~60–80 B) under geneve (~38–58 B) stacks two
encapsulations. On a 1500 underlay the VM MTU must drop well below 1400, or run
jumbo frames on the underlay where we control it. If WireGuard already
encrypts, do **not** also enable OVN IPsec (double crypto).

_(future)_ **Strato-owned multi-site underlay config.** Long-term, Strato
should own and provision the underlay config across a customer's sites (managed
WireGuard mesh) rather than assuming customer-provided routability. Deferred —
not in the near-term roadmap.

### Layer 1 — Tenant overlay (OVN)

OVN geneve logical switches + **logical routers** + **SNAT**, identical across
all site types. This is where the L3 gap closes:

- A logical router per network (or per project) provides a real gateway.
- **SNAT** to the site uplink gives VMs outbound connectivity.
- Multiple switches connected to one router provide east-west routing within a
  site.

Keep OVN's **geneve** overlay — do not replace it with EVPN-VXLAN. OVN uses
geneve specifically to carry its logical metadata (datapath + ingress/egress
port); VXLAN cannot, and OVN restricts VXLAN to limited hardware-VTEP
integration. EVPN belongs in the underlay/edge, not the tenant overlay.

#### Instance metadata (IMDS) — the localport

Every logical switch with `metadataEnabled` publishes the metadata service's
addresses — `169.254.169.254` and `fd00:ec2::254`, the two cloud-init's Ec2
datasource already probes — via an OVN logical switch port of type
**`localport`** (STR-49). A localport is the primitive designed for exactly
this: `ovn-controller` instantiates it on every chassis and never forwards it
across geneve tunnels, so one address can be published site-wide and every
guest still reaches its own host. OpenStack's neutron metadata agent and
ovn-kubernetes' management port both use it. OVN answers guest ARP and Neighbor
Solicitation from the port's `addresses` field, which is why the addresses need
not belong to the switch's subnets.

The localport is the *transport* half of the IMDS story. The *payload* half
is the per-VM metadata document itself: the control plane builds it (the
factory extension in `InstanceMetadataFactory.swift`) and
`DesiredStateAssembler` attaches it to each VM's
`DesiredVMState.metadata` (wire v26, STR-48/51;
`shared/Sources/StratoShared/InstanceMetadata.swift`). The agent keeps it in
`MetadataStore` (STR-52), written by the reconciler as syncs arrive and read
with no control-plane round trip, so it holds per VM exactly what a metadata
listener should serve — see [agent](./agent.md) §Instance metadata store. With
both halves in place, the only piece missing for guest-visible IMDS is the HTTP
listener inside the namespace (STR-56).

The localport realization itself has **two halves with two different owners**,
and that shape is load-bearing rather than incidental:

- The **localport itself** is one row in the shared northbound database, so it
  is authored only by the site's network controller, from
  `DesiredNetworkState.metadataEnabled`. It rides the network desired state
  rather than the per-VM spec for `dhcpEnabled`'s reason: network-level edits
  don't bump VM generations, so a converged VM would never re-realize it.
- The **chassis-local termination** — an OVS internal port on `br-int` carrying
  `external_ids:iface-id=<lsp>`, moved into a namespace and given both
  addresses — must exist on *every* host running a NIC on that network,
  including the sited agents that receive an empty `networks` list because they
  may not author topology. Its input is therefore the agent's own workload specs
  (`NetworkSpec.metadataEnabled`), and it converges before the reconciler's
  authority guard. Its teardown trigger is different too: the last local NIC
  leaving the network, not the network being deleted.

**One namespace per network per chassis** (`strato-md-<network-uuid>`, mirroring
OpenStack's `ovnmeta-<network>`). Not an isolation nicety — overlapping tenant
subnets are supported by design, so two guests on different networks can both be
`10.0.0.5`. A listener in a shared namespace would see identical
`(source, destination, port)` for both and could not tell which instance was
asking, and "the source address identifies the caller" is the entire security
model of an instance metadata service. Reply routing breaks on the same
ambiguity. See [ADR 0003](../adr/0003-imds-chassis-namespace.md).

Source-IP identification is sound only because VM logical switch ports carry
`port_security`, pinning each to its allocated MAC and addresses — without it a
guest could spoof a neighbour's address and be served that instance's metadata.
Nothing in the metadata code references that dependency, so it is recorded in
the ADR rather than left implicit.

Convergence observes the namespace, not just the OVS interface row: the two have
different lifetimes (`conf.db` on disk, `/var/run/netns` on tmpfs), so after a
host reboot the row returns and `ovn-controller` answers ARP while nothing
terminates the address. Guests would hang rather than fail fast — worse than
having no metadata port at all.

The IPv6 address is added unconditionally, including on v4-only networks, so
both halves of the reconcile derive from one input with no drift. In practice a
guest can only *use* it on a dual-stack network: with no global IPv6 address it
has no valid source address for a ULA destination.

Neither address belongs to the switch's subnets, so both need an advertised
route before a guest can reach them. Most Linux images carry a `169.254.0.0/16`
link-local route that covers the v4 address by accident, but that is not
universal and nothing covers the v6 ULA — so STR-53 advertises both explicitly,
through **two mechanisms with different reach**:

- **DHCP option 121** (`classless_static_route` on the network's OVN
  `DHCP_Options` row) carries the v4 route to any DHCP client that asks for the
  option, whatever the guest OS and whether or not it read a cloud-init seed. A
  client that leaves 121 out of its parameter request list — an older
  `dhclient` without `rfc3442-classless-static-routes` in `request` — never
  sees it, which is exactly why `router` stays in the map beside it. The option
  also repeats the network's default route: RFC 3442 requires a client that
  *does* understand option 121 to ignore option 3 (`router`) outright, so
  advertising only the metadata route would trade the guest's default gateway
  for it.
- **The NoCloud `network-config`** (`CloudInitProvisioner.networkConfigYAML`)
  carries the v4 route for statically addressed NICs, and the **v6 route for
  every** NIC on a dual-stack network. There is no DHCPv6 counterpart to option
  121, and an RA cannot help either: RFC 4191 route information advertises a
  route *via the advertising router*, which has no path to a localport hanging
  off the switch. The seed is the only v6 delivery path there is.

Both are on-link routes with an explicit **zero next hop** (`0.0.0.0` / `::`):
the guest ARPs or NDs for the metadata address itself, which OVN's responder
answers from the localport's `addresses`. The zero next hop is written out
rather than the route being left gateway-less because cloud-init's `eni` and
`sysconfig` renderers — first and second in its renderer priority, so
Debian/ifupdown and RHEL-family images reach them before netplan and
NetworkManager — raise `KeyError` on a gateway-less v2 route and abort the
*entire* network render. The v6 route still no-ops on those two (they emit a
literal `via ::`, which iproute2 rejects); netplan/systemd-networkd and
NetworkManager install it.

Within the seed, one NIC per family carries the routes — the first that can
discharge that family — because two interfaces claiming the same destination is
a duplicate route the guest resolves arbitrarily. That is AWS's `eth0`-only
rule, generalized so a VM whose NIC 0 is on a metadata-disabled network (or is
v4-only while a later NIC is dual-stack) still gets the route.

**That is a property of the seed, not an invariant of the feature.** Option 121
is authored on the *network's* `DHCP_Options` row and delivered to every DHCP
client on that network, which the seed does not arbitrate: a VM with NICs on
two metadata-enabled DHCP networks receives the v4 route on both, and which one
survives is down to the order its DHCP client writes them. Harmless — either
route reaches a namespace serving that same VM — but the deduplication is not
what makes it so, and a per-network option row cannot do better.

Neither mechanism is retroactive for a *booted* guest: the seed is written at
provisioning time, so an existing VM picks up the v6 route only on rebuild,
and option 121 arrives with the next lease — within one `lease_time` (3600s by
default) of enabling the service on a network.

On a network with security groups attached, guest→metadata egress is still
dropped by the default-drop port group until STR-54's implicit allow rules land
— two rules, since OVN ACL matches are per-family.

### Layer 2 — Edge / north-south

Progression from simplest to most capable:

1. **SNAT egress** (Layer 1) — outbound only.
2. **Floating IPs** — OVN `dnat_and_snat` NAT on the router (external_ip =
   floating, logical_ip = VM fixed IP). With a distributed gateway port the NAT
   is handled on the hypervisor hosting the VM ("L3 to the host"). Reachability
   from outside: static routes first, BGP advertisement later.
3. **BGP advertisement of prefixes** (customer brings public IPs at their site)
   — see §OVN dynamic routing. Gives ECMP + fast failover + migration-follow
   for floating IPs.
4. **CP-hosted ingress ("public IP as a service")** — the SaaS owns the public
   IPs; see below.

#### CP-hosted ingress / "CDN"

To give an internal VM a routable public IP without the customer owning public
IP space or configuring inbound firewall rules, the SaaS runs edge nodes and
tunnels traffic in. Two tiers:

- **L7/L4 reverse-proxy ingress (build first).** SaaS edge terminates
  TCP/TLS/HTTP and proxies to the VM over a **dial-out** tunnel (the
  site/agent initiates the tunnel to the edge — zero inbound config at the
  customer). This is the Cloudflare-Tunnel / ngrok / inlets model, and it is
  where actual "CDN" behavior lives (TLS termination, HTTP caching, WAF, DDoS
  absorption). The VM gets a public _endpoint_, not a real IP.
- **L3 elastic public IP (heavier, later).** SaaS assigns a real public /32,
  announces it (BGP/anycast) from the edge, and tunnels all IP traffic for it to
  the VM. AWS-elastic-IP-style; all-protocol.

Both **reuse the floating-IP/NAT machinery** — the edge tunnels to the site
gateway and the site's OVN DNATs to the VM; the "external" side is the SaaS
tunnel instead of the customer's uplink. Go in with eyes open on **bandwidth
cost** (all ingress + return transits the edge; caching only helps HTTP) and
that **multi-PoP anycast is a genuine CDN build**, not a single-edge feature.

### Layer 3 — Inter-site connectivity

- **L3 routing between sites (default).** BGP between **site gateways** (not
  between every hypervisor), over the underlay. Each site stays an independent
  OVN deployment; gateways exchange each site's prefixes. We chose this over
  **OVN-IC**: IC adds per-tenant IC databases, gateway-chassis HA, IPsec, and
  replicating all policy anyway — for only route exchange, which BGP does more
  simply and with real policy control.
- **Stretched L2 across sites _(opt-in, discouraged)_.** Possible two ways:
  (a) one OVN deployment spanning both sites (sacrifices per-site isolation,
  puts SB over the WAN — avoid); (b) an EVPN Type-2 L2 bridge between separate
  deployments (the "real" DCI mechanism). Stretched L2 over a WAN is generally
  an anti-pattern (BUM flooding, coupled failure domains, latency). Default to
  L3; build L2 stretch only for a concrete same-tenant need (legacy same-subnet
  app, cross-site live migration).

## Sandbox NICs

A VM's VMM runs in the host network namespace, so its NIC is a host TAP plugged
straight into `br-int`. A jailed sandbox's Firecracker does not: it runs
chrooted inside `strato-sbx-<id>`, as a per-sandbox uid, with `CAP_NET_ADMIN`
dropped, and its only network backend is a TAP opened *by name from inside the
jail* — no fd passing, no vhost-user. So the device has to exist in that
namespace, owned by that uid.

The path is `NetworkServiceLinux`, driven through the same `NetworkOrchestrator`
the VM path uses — not a special case inside the sandbox runtime — selected by a
`NICPlacement` the agent derives from the jail plan (STR-100; the jail itself —
chroot, per-sandbox uid, netns lifecycle — is described in
[sandboxes.md](./sandboxes.md#jailer-hardening)).

**Port namespace.** Sandbox ports are `sbx-<id>[-<n>]`, deliberately disjoint
from the VM path's `vm-<id>[-<n>]`, so the two kinds are distinguishable in OVN
and OVS. Everything else about the logical port — switch lookup, DHCP options,
addressing, `port_security` — is the VM path unchanged.

**Topology: tc-redirect-tap.** A veth pair straddles the namespace. Its host end
(`vth<digest>`) stays in the host namespace on `br-int` and never moves, so OVS
never loses the device. The peer (`vtp<digest>`) is moved into the netns, and a
TAP there (`tap<digest>`, created `user <uid> group <gid>`) is spliced to it by
two `tc` `matchall`/`mirred` redirects — **both on the `ingress` hook**. A TAP's
ingress is where frames the VMM *writes* appear and its egress is what the VMM
reads, so putting either filter on the egress hook produces a port that binds
and carries nothing. All three names are exactly 15 characters (`IFNAMSIZ`) and
derived from a fixed FNV-1a digest, so create and teardown agree with no
persisted state.

**Why not just move the TAP in.** That was the original design. It was measured
against a real `br-int` + `ovn-controller` and does not work (STR-99): within
30ms of `ip link set <tap> netns <ns>` OVS reports `ofport: -1` and
`error: "could not open network device"`, the device is gone from the datapath
and the OpenFlow port list, and `ovn-controller` releases the `Port_Binding`.

Two consequences worth carrying forward:

- **The failure is silent at the OVSDB level.** The `Port` and `Interface` rows
  survive the move untouched — same UUID, `iface-id` still set — so the port
  still appears in `ovs-vsctl show`. Any health check that looks a port up by
  name, or trusts a row's existence, sees health where there are no packets.
  Check the `error` column, or `ofport != -1`, or the southbound `Port_Binding`.
  The attach path reads back `ofport` and `error` after `add-port` for exactly
  this reason.
- **`ofport` is not stable** across a device's disappearance and return
  (observed 3 → 4). Nothing caches it.

**Teardown** is host-side only: removing the OVS port, deleting the host veth
end (which destroys its peer, and with it the in-namespace devices and their
filters), and — for the NIC that owns it — deleting the namespace. It needs
neither `ip netns exec` nor the namespace to still exist, which is what makes it
work after an agent crash and on the create-rollback path, where the jail's own
artifact cleanup never runs.

Two properties it is worth not breaking. Namespace deletion is scoped to NIC 0,
because namespace lifetime belongs to the *jail*, not to any one NIC — a
multi-NIC sandbox must not have NIC 0's teardown pull the namespace out from
under NIC 1. And the whole teardown is derivable from the **sandbox id alone**:
no jailer config, no ownership. That matters because an agent whose sandbox
runtime has been deconfigured still has jailed leftovers from its previous life
to clean up, and degrading to the VM teardown there would delete `vm-<id>` and a
TAP that never existed while leaving the real `sbx-<id>` port, veth, and
namespace behind — silently, since teardown swallows errors by design.

**MTU** is applied to all three devices from the same `NetworkSpec.mtu` the guest
is given — as it now is for the VM host TAP, which historically kept 1500 even on
a network whose MTU had been lowered for an encapsulated uplink (see the MTU
footgun note above). Two consequences of that VM-path change: it runs on every
reconcile rather than only at create, so it reaches VMs that have been up since
before it existed and a stale stored MTU surfaces then; and OVS derives a
bridge's internal-port MTU from the minimum over its non-internal ports, so the
first VM on a lowered-MTU network pulls `br-int`'s own MTU down host-wide. The
latter is inert in a standard OVN deployment — nothing routes via the `br-int`
internal port — but it is a host-scoped effect of a per-VM setting.

**Host requirements.** iproute2's `ip` *and* `tc`, plus the kernel's `sch_clsact`,
`cls_matchall`, and `act_mirred` modules. Both binaries are invoked by absolute
path resolved from a fixed candidate list, not via `PATH` — a service manager's
stripped environment must not be able to break a host the start-time probe
declared usable — so a `tc` installed outside that list passes the (`PATH`-based)
preflight check and still refuses every networked sandbox. The preflight hint
names the list for that reason. `tc` is advisory rather than a jailing
prerequisite: without it a host still runs sandboxes, it just refuses NICs.

Networked sandboxes are refused, permanently and visibly, in three cases: an
unjailed agent (no namespace to attach into, and the isolation is the point), a
snapshot restore (STR-104), and an attachment that is not a TAP. That last one is
reachable — `network_mode = "user"` builds the user-mode service on *every*
platform, not just macOS, and an agent with no network service degrades every NIC
the same way. Firecracker's only backend is a TAP opened by name, so the runtime
refuses rather than skipping the device and booting a sandbox with no interface
that the control plane still records as having one.

**Not yet wired end to end.** `SandboxSpecBuilder.guestNetworkingSupported` is
still `false`, so no sandbox `NetworkSpec` reaches an agent. The full holding
pattern — what blocks the flag (STR-101, STR-103) and the security-group and
snapshot arms queued behind it (STR-102, STR-104) — is tracked in
[sandboxes.md](./sandboxes.md#guest-networking-the-holding-pattern).

## Security groups

Stateful, NIC-level firewalling modeled AWS-style and realized as **OVN ACLs
on Port_Groups** (the OpenStack/ovn-kubernetes pattern). Wire protocol v20
(v24 added per-rule ACL logging).

### Model (control plane)

- **`SecurityGroup`** rows are project-scoped with per-project unique names;
  **`SecurityGroupRule`** rows are immutable (edit = delete + recreate) and
  carry direction (`ingress`/`egress`), ethertype (`ipv4`/`ipv6`), optional
  protocol (`tcp`/`udp`/`icmp`) with a destination port range (ICMP: type and
  code), a peer that is a CIDR **or a reference to another security
  group** in the same project, and an optional `log` flag that turns on OVN
  ACL logging for the flows the rule admits. Every rule mutation bumps the
  group's `generation` (the `LogicalNetwork.generation` replay-safety
  pattern).
- **Mandatory default group**: every project has an auto-created, undeletable,
  un-renamable `default` group (rules editable) seeded with AWS semantics —
  allow all ingress from the group itself, allow all egress. Every VM NIC
  belongs to at least one group (`vm_interface_security_groups`); VM create
  attaches the default group when the caller picks none, and detach refuses to
  empty a NIC's set. `SeedDefaultSecurityGroups` backfilled pre-existing
  projects, adding a **deletable allow-all-ingress rule** to projects that
  already had workloads so agent upgrades could never cut live inbound
  traffic — deleting that rule is how an operator opts a project into real
  ingress filtering.
- Groups referenced by another group's rules, attached groups, and the default
  group refuse deletion (409, schema-backstopped) — attachment counts span
  both join tables, so a group held only by a sandbox NIC is just as
  undeletable.
- **Sandbox NICs carry membership but no enforcement.**
  `sandbox_interface_security_groups` mirrors the VM join, sandbox create
  attaches the project default, and attach/detach take a `sandboxId` — but
  sandbox guest networking is still off
  (`SandboxSpecBuilder.guestNetworkingSupported`), so a sandbox NIC's
  `NetworkSpec` never reaches an agent and these rows filter nothing. They
  exist so the model and the ≥1-group invariant are already right when guest
  networking lands. The agent-version gate is deliberately *not* applied to
  the sandbox path: with nothing on the wire, no agent version could change
  what an attachment achieves. Note that the agent-side realization
  (`VMNetworkConfig.securityGroupIds`) is nil for a sandbox NIC, so an
  `sbx-` port joins **no** port groups — not even the drop group. STR-102 is
  what grows the sync's membership assembly a sandbox arm; until then a sandbox
  port would come up unfiltered, which is part of why the wire gate stays shut.

### Wire and rollout

- `DesiredStateMessage.securityGroups` carries the groups the receiving
  agent's *authored topology* needs — groups attached to in-scope VMs plus the
  transitive closure of rule references, so every address-set reference
  resolves. `NetworkSpec.securityGroupIds` carries each NIC's membership.
- Both fields are additive and nil-tolerant. Nil `securityGroups` is "no
  opinion", never "tear down all port groups"; a nil per-NIC list marks the
  port unmanaged (it joins no groups, drop group included), which is what
  keeps legacy traffic flowing during a mixed-version rollout. The control
  plane refuses attach/detach for VMs placed on pre-v20 agents and omits both
  fields from their syncs (`WireProtocol.supportsSecurityGroups`).
- **The API says when filtering is inert.** `VMDetail.securityGroupsEnforced`
  is false when a realizing agent — the host, or its site's network
  controller — registered pre-v20, *or* when nothing would author the site's
  ACLs at all (no controller, or an unusable one), so neither a mixed-version
  fleet nor a broken site can quietly show attached groups that no ACL
  applies; nil means the VM is unplaced. It and the attach/detach gate share
  one resolution (`SecurityGroupService.realization`, itself resolved through
  `SiteNetworkAuthority`) so they cannot disagree. Per-NIC membership is on
  the same response (`NetworkInterface.securityGroupIds`), absent rather than
  empty when the server didn't load it.
- Per-rule `log` (v24) is additive with **no gate**, unlike v20's fields: a
  pre-v24 agent builds the identical enforcing ACL and only omits the log
  line, so the failure mode is a missing diagnostic, not open traffic.

### Enforcement (agent)

- One OVN **Port_Group per group** (`pg_<uuid-hex>` — identifier-safe, since
  the name appears in match expressions and in OVN's auto-generated
  `$pg_…_ip4`/`_ip6` address sets, which is also what makes group-reference
  peers work with zero IP bookkeeping). One `allow-related` ACL per rule at
  priority 1002, built by the pure `SecurityGroupACLBuilder`
  (`agent/Sources/StratoAgentCore/SecurityGroupReconciler.swift`).
- The site-singleton **`pg_strato_drop`** group holds every managed port and
  provides the default deny: both-direction `ip` drops at priority 1001 (ARP
  is not `ip`, so address resolution survives) plus DHCPv4/v6, IPv6
  ND/RS/RA, and MLD carve-outs at 1002. MLD is spelled as explicit
  `icmp6.type` values rather than OVN's `mldv1`/`mldv2` predicates, so the
  match parses on every OVN version we support — and it is **asymmetric**: a
  member port may send listener Reports and Dones (131/132/143) but only
  *receive* Queries (130). Letting guests originate Queries would let any
  member win MLD querier election on the shared segment and then stop
  querying, timing out every other guest's multicast state; `pg_strato_drop`
  spans the whole site, so that would cross project boundaries.
- A rule with `log` set maps onto the ACL's `log`/`severity`/`name` columns
  (`severity` pinned to `info`, `name` derived from the rule id so a log line
  names what emitted it). The drop group's own ACLs are never logged — that
  would drown the log in per-guest DHCP and multicast chatter.
- Two revision counters force rewrites on upgrade without waiting for a rule
  edit: `dropGroupRevision` when the drop group's ACL set changes shape, and
  `aclSchemaRevision` when the builder's ACL *construction* changes.
- **Ownership follows the topology-authority split**: port groups and ACLs are
  authored only by the site's network-controller agent (generation-stamped
  full replace of a group's ACL set; teardown = observed managed groups −
  desired), while **membership** is converged by every agent for its own VMs'
  ports — level-triggered each sync (attach/detach on a running VM applies on
  the next nudge, no restart) and at LSP creation, where a not-yet-realized
  port group parks the create on `DependencyPendingError` so a managed NIC
  never boots unfiltered.
- Floating IPs compose without special casing: DNAT'd traffic still traverses
  the LSP, so `to-lport` ACLs see the post-DNAT destination and the external
  source — a FIP'd service is opened with an ordinary CIDR ingress rule.

### Known limitations / follow-ups

- Group-reference peers match only addresses OVN knows from LSP `addresses`.
- Sandbox NIC membership is recorded but not enforced, pending sandbox guest
  networking (see the model section above).
- Network-level stateless ACLs (NACLs, switch-attached) are a follow-up, as
  are ACL meters/stats — `log` is wired, `meter` is not, so a chatty logged
  rule has no rate limit.
- There is no UI for security groups on sandboxes; membership is API-only.

## OVN dynamic routing (native, 25.03+)

OVN gained native dynamic routing in **25.03** (experimental; latest docs
26.03). Key facts that shape our design:

- **OVN still does not speak BGP.** It relies on an external daemon (**FRR**)
  on each chassis. What's native is the _plumbing_: set `dynamic-routing=true`
  on a logical router and `dynamic-routing-redistribute` (`connected`,
  `static`, `connected-as-host`); `ovn-northd` fills an `Advertised_Route`
  table, `ovn-controller` installs it into a Linux **VRF** via Netlink; FRR
  (with `redistribute connected`) advertises to peers. Inbound routes flow back
  via a `Learned_Route` table.
- **What it advertises (overlay → fabric):** connected/tenant routes, static
  routes, **NAT external IPs (floating IPs)**, and **LB VIPs**.
- **What it does NOT do:** build the underlay. Underlay reachability between
  hypervisors is assumed to already exist (that is Layer 0).
- **What it replaces:** the separate `ovn-bgp-agent`. North-south advertisement
  becomes OVN NB configuration + FRR, instead of a bespoke agent.
- **Version floor:** agents need OVN ≥ 25.03 (newer than the current agent
  image pin), and it is still marked experimental. Native BGP-**EVPN** was
  still unsettled as of OVSCon 2025 — treat plain BGP redistribution as real,
  EVPN as emerging.

Implication: floating-IP advertisement is OVN config (router/router-port
options) + shipping FRR on egress hosts, not a custom agent.

## Phased roadmap

Ordered by dependency. Priorities noted; the top product ask is **multi-node
single network within a site** (Phase 2).

### Phase 1 — Foundations + single-node L3 _(no new infra)_ — **implemented**

- Make network (and router) realization **first-class in reconciliation**,
  rather than implicit via `VMSpec.networks`.
- Model a **logical router** in the control plane (per-network or per-project)
  and an "uplink/external" concept.
- Agent: create logical router + router port + **SNAT** in `NetworkServiceLinux`
  (SwiftOVN already wraps `Logical_Router`, `Logical_Router_Port`, `NAT` with
  attached-creation overloads).
- **Result:** VMs get outbound internet + cross-switch east-west _within a
  node_. Works on the current per-agent-local-NB model.

**As built:**

- Networks ride the periodic `DesiredStateMessage` as a first-class
  `networks: [DesiredNetworkState]` list (wire protocol v3, additive/tolerant).
  The control plane emits the networks an agent's VMs reference, each tagged with
  a **`routerKey`** and an `externalAccess` flag; `LogicalNetwork` gains
  `external_access` + a `generation` counter.
- Router scope is **per-project**: networks sharing a project share one logical
  router (cross-switch east-west); a project-less (global) network keys its
  router on its own id. `routerKey` is derived, not a separate table.
- The agent reconciles level-triggered and idempotent via the pure
  `NetworkReconciler` in `StratoAgentCore` (plan + teardown diff), with the live
  OVSDB side effects in `NetworkServiceLinux` behind a `NetworkActuator`.
- All Strato-managed OVN object names are derived from **UUIDs**, never
  user-chosen network names (`OVNNaming`): tenant switches are `net-<networkId>`,
  routers `lr-<routerKey>`, etc. This keeps user names out of OVN's shared
  namespaces, so a network name can't collide with a provider/router object. The
  `NetworkSpec` a VM carries includes `networkId` so its port lands on the same
  UUID-named switch the reconciler creates. On upgrade from an older agent that
  named switches after the network, the reconciler **renames the switch in
  place** to the UUID name — a rename keeps the same OVSDB row, so existing VM
  ports and their dataplane bindings migrate without re-creation.
- Teardown identifies Strato-owned objects by a `strato-managed` external-id
  (external switches also carry `strato-role=external`), never by name prefix, so
  operator or other-feature objects are never candidates.
- SNAT egress uses an external logical switch with a `localnet` port on a
  configured physnet, mapped to a provider bridge, plus a gateway router port and
  a default route. The agent binds the gateway router port to its own chassis
  with a `Gateway_Chassis` row (priority 1) — OVN only programs the centralized
  SNAT on the chassis holding the gateway port, so without the binding the NAT
  rule sits unprogrammed and traffic egresses un-NAT'd (issue #372). It also
  ensures the provider bridge's bridge-named internal port exists so
  `ovs-vswitchd` materializes the Linux netdev (issue #371), and warns when the
  netdev still fails to appear. It requires an **operator-configured, dedicated
  external IP** (`[ovn_uplink] external_cidr` in the agent config) that the host
  does not own — the OVN router port claims that address, so auto-detecting and
  reusing the host's own IP would cause an ARP/address conflict. Without the
  uplink config, routers and east-west are realized but no SNAT
  (`externalAccess` has no effect). The operator connects the provider bridge to
  the external network out of band.
- **Dual-stack egress:** networks are dual-stack by default, so a router port
  with a v6 prefix sends RAs carrying an IPv6 default route. That route needs a
  matching SNAT rule or it black-holes (issue #519), so an `externalAccess`
  network contributes **two** SNAT subnets — its v4 subnet and its v6 prefix —
  and the uplink takes an optional `external_cidr6`/`gateway6` pair: a second
  address on the same gateway router port, the IPv6 SNAT `external_ip`, and a
  `::/0` static route. The two families reconcile independently — each default
  route and SNAT rule is keyed by its own prefix — so a v4-only uplink stays a
  valid configuration. In that case the v6 SNAT rule is skipped with a warning
  rather than failing the reconcile, and IPv6 egress simply doesn't work; v4
  keeps working. `external_cidr` stays required either way, since the gateway
  port's MAC is derived from it. NAT66 over a ULA prefix is a pragmatic
  stopgap — GUA prefix delegation is the cleaner long-term answer.
- **No-egress isolation:** a project's `externalAccess=false` networks are keyed
  onto a separate `-internal` logical router with no uplink, so their guests
  provably have no route to the internet. Tradeoff: an egress and a no-egress
  network in the same project are on different routers and don't route to each
  other; per-network egress policy that preserves that east-west is a follow-up.

### Phase 2 — Multi-node single network within a site _(top priority)_ — **implemented (first cut)**

A single logical switch spanning hypervisors requires a **shared per-site NB**.
The per-agent-local-NB (Unix socket) model cannot express this.

**As built (issue #343):**

- **SwiftOVN TCP/SSL transport** landed upstream (`OVSDBEndpoint`:
  `unix:`/`tcp:`/`ssl:` connection strings); the agent pin was bumped past it.
- **NB authorship decision → agents, not the control plane.** The CP is a SaaS
  the agents dial out to through NAT — it cannot reach a customer site's NB
  over TCP, and the division of responsibility above says it is "an
  orchestrator, not an OVN participant". Refined split: **every** agent in a
  site connects to the shared NB (each binds its own VMs' logical switch
  ports), but **topology authority** — switch/router/SNAT reconciliation and
  teardown — runs only on one CP-designated **network controller** agent per
  site, so the shared, level-triggered-reconciled NB has a single topology
  writer. The CP tells each agent which role it has via
  `DesiredStateMessage.networksAuthoritative` (absent = true, matching older
  CPs where every agent owned its private NB). A non-authoritative agent never
  creates switches: a VM port whose switch doesn't exist yet fails and retries
  after the controller's next sync realizes it.
- **Site model:** `Site` rows group agents (`agents.site_id`, assigned via the
  enrollment's `siteId` or the sites API) and carry the
  `network_controller_agent_id` designation. `logical_networks.site_id` pins a
  network to a site; the scheduler filters placement to that site's agents
  (`VMPlacementRequirements.siteID`, derived from the VM's NICs' networks —
  networks pinned to different sites on one VM are rejected). Site-less agents
  and unpinned networks keep the legacy single-node behavior exactly.
- **Sync assembly:** the controller agent's sync carries every network
  referenced by any VM in the site plus all site-pinned networks
  (`networksAuthoritative=true`); other sited agents get an empty list and
  `false`. Mutation syncs for any site member also nudge the controller.
- **Agent config:** `ovn_northbound` (OVN connection string; default
  `unix:/var/run/ovn/ovnnb_db.sock`) is the NB counterpart of the existing
  `ovn_remote` SB setting. Both point at the site central
  (`tcp:<central-host>:6641/6642`) in a multi-node site. For `ssl:` endpoints
  the `[ovn_northbound_tls]` section carries the PKI material (CA, client
  cert/key, verification toggle, SNI hostname — the agent counterparts of
  ovn-nbctl's `-C`/`-c`/`-p`); it is rejected at load time unless the endpoint
  is actually `ssl:`, and the host preflight verifies the PEM files exist.
- **Per-site ovn-central deployment:** `deploy/ovn-central/` (compose +
  image: NB/SB/northd with plain-TCP listeners; TLS via `ovn-pki` is the
  operator upgrade path). Hypervisors run `ovn-controller` + OVS only.
- Underlay (Layer 0): LAN / customer-provided routability assumed, per plan.
- **Result:** one logical network spans a site's nodes over geneve.

- **Designation (issue #743):** the first OVN-capable node to join a site
  with no controller is designated automatically, at registration and at
  `POST /api/sites/:id/agents/:agentId`, so a single-node site needs no
  manual step. An existing designation is never displaced. A site that still
  ends up without one (only user-mode members, or an operator-cleared field)
  fails loudly instead of stalling: VM/sandbox placement fails the create
  operation, `POST /vms/:id/start` and pinning a network to a *populated*
  controller-less site answer `409`, all naming the `PUT /api/sites/:id` that
  fixes it. The last member of a site may drop its own designation by
  leaving or deregistering — with the site emptied there is no topology left
  to author.

- **Liveness and capability regression (issue #833):** a designation that
  *exists* reaches the same dead end far more often than a missing one — the
  controller is an ordinary hypervisor node that can crash, be drained, or
  re-register in user-mode or on a rolled-back pre-v4 binary, and nothing
  re-checked the bar it was designated under. `SiteNetworkAuthority.resolve`
  therefore also reports `.controllerUnavailable`, and every precondition goes
  through one `refusal` helper so the two "nothing would realize this" states
  are worded and handled alike: placement, `POST /vms/:id/start`, pinning a
  network to the site, attaching a floating IP, and attaching a security group
  (previously a silent no-op there). Two deliberate softenings:
  - **A grace window.** Liveness is judged on heartbeat age against
    `SITE_CONTROLLER_OFFLINE_GRACE_SECONDS` (default 300s), not the 60s
    `Agent.isOnline` threshold, so a node reboot keeps degrading to the
    existing 202-and-converge behavior instead of a wall of `409`s. A
    capability regression gets no grace — it never converges on its own.
  - **The host exemption.** When the unavailable controller *is* the
    workload's own host (the single-node site), the refusal is skipped: the
    workload and its topology author share a fate, the node is already visible
    as offline, and desired state may legitimately be set while it reboots.
    The cross-node stall this exists for is unaffected.

  Reporting, so the outage is visible before the first refusal: `SiteDetail`
  carries `networkControllerStatus` (heartbeat-derived, no grace) and
  `networkControllerIssue` (non-null exactly when work is being refused), the
  sites page renders both, the stale-agent sweep logs a warning naming the site
  and sets the `strato_site_network_controller_up` gauge to 0, and registration
  re-validates a standing designation — handing the job back (so an eligible
  peer can claim it on its next registration) only when the site has another
  eligible member.

Remaining in this phase: automatic controller failover — re-designation away
from a *live* controller needs a fencing story (two agents authoring one shared
NB is worse than the stall), so today a replacement is a manual
`PUT /api/sites/:id`; syncs handle the handover level-triggered. Also geneve
verification on real multi-node hardware (recipe in
`deploy/ovn-central/README.md`).

### Phase 3 — Floating IPs + north-south advertisement — **implemented (first cut)**

- Control plane: external/floating **IP pool** in IPAM, `FloatingIP` model +
  association to a VM NIC, push `dnat_and_snat` into the site NB.
- Reachability: static routes first; then **OVN native dynamic routing + FRR**
  (needs OVN ≥ 25.03 on agents; SwiftOVN needs the `dynamic-routing*` fields on
  its router/router-port models).
- **Result:** customer-provided public IPs at a site, with BGP failover/ECMP.

**As built (issue #344):**

- **Control plane:** `FloatingIPPool` rows (external IPv4 CIDR, optional
  gateway exclusion, optional site pin, org/folder-scoped like sites; the name
  is unique within that owner, not deployment-wide — STR-105) and
  `FloatingIP` rows (pool + address + project, optional FK to a
  `VMNetworkInterface`; `SET NULL` on NIC delete, so removing a VM *detaches*
  rather than releases). `IPAMService.allocateFloatingIP` reuses the
  lowest-free v4 allocator under a per-pool advisory lock. API:
  `/api/floating-ip-pools` (site-style authz: system admin or org
  `manage_agents` to create, `floating_ip_pool#view/manage` after) and
  `/api/floating-ips` (network-style authz: project `create_floating_ip` to
  allocate; `floating_ip#read/update/delete`; `POST :id/attach` / `:id/detach`).
  Attach requires the NIC's network to have `externalAccess` (the NAT needs
  the router's uplink), matching pool/network site when the pool is pinned,
  one floating IP per NIC, and bumps the network `generation` so replayed
  syncs can't resurrect old NAT state.
- **Wire:** `DesiredNetworkState.floatingIPs: [DesiredFloatingIP]?` (optional,
  version-tolerant) — `externalIP`, `logicalIP`, plus `vmId`/`nicIndex` so the
  agent derives the NIC's logical switch port name itself. Assembly scopes
  floating IPs to the VMs whose topology the receiving agent authors (own VMs
  for a site-less agent; every site VM for the site's controller).
- **Agent:** `NetworkReconciler.plan` turns each attachment into a
  `dnat_and_snat` rule on the network's router (gated on `externalAccess`, so
  an isolated `-internal` router never grows an uplink), keyed for
  observe/teardown by `(router, externalIP)` — re-attachment re-points
  `logical_ip` in place. Rules carry `logical_port` (`vm-<id>[-n]`) and a
  derived `external_mac` (`02:01:` + the floating address), making the NAT
  **distributed**: the VM's own chassis handles the floating IP and answers
  external ARP, no gateway-chassis hairpin. The gateway port stays pinned to
  the controller's chassis (`Gateway_Chassis`) as before for subnet SNAT.
- **Dynamic routing (reachability tier 2):** opt-in `[ovn_dynamic_routing]`
  agent config (`enabled`, `redistribute` — default `connected,nat`, `nat` is
  what advertises floating IPs — `vrf_name`, `maintain_vrf`,
  `routing_protocols`). The topology-authority agent applies
  `dynamic-routing*` options to every uplinked router and its gateway port
  via SwiftOVN's helpers, level-triggered, and strips them when disabled.
  FRR does the actual BGP: the agent image ships the `frr` package (inert
  until configured); `deploy/frr/` has the operator recipe + example
  `frr.conf`. Reachability tier 1 (static routes to the uplink IP) needs no
  BGP and works on any OVN.
- **Version floor:** the agent image and `deploy/ovn-central` moved from
  Ubuntu noble (OVN 24.03) to 26.04 LTS (OVN 26.03), clearing the ≥ 25.03
  floor for dynamic routing.
- Remaining in this phase: floating IPs are IPv4-only (like IPAM generally);
  no floating-IP quota; UI; and end-to-end verification of the
  Advertised_Route → FRR path on real multi-node hardware.

### Phase 4 — CP-hosted ingress ("public IP as a service" / CDN)

- SaaS edge nodes + **dial-out reverse-proxy** tunnels; L7/L4 tier first.
- Reuse the floating-IP/NAT path (edge → site gateway → OVN DNAT).
- Later: L3 elastic public IPs (BGP/anycast) and multi-PoP caching.
- **Result:** any internal VM gets a public endpoint with zero customer network
  config.

### Phase 5 — Inter-site L3 + Strato-owned underlay _(future)_

- **BGP between site gateways** for L3 inter-site routing (not OVN-IC).
- **Strato-owned multi-site underlay** (managed WireGuard mesh) instead of
  customer-provided routability.
- L2 stretch as an opt-in special case if a concrete need appears.

## Known gaps / dependencies

- **SwiftOVN model coverage is now largely complete** — `Gateway_Chassis`,
  `HA_Chassis`/`HA_Chassis_Group`, `Logical_Router_Static_Route`, `Port_Group`,
  the `dynamic-routing*` router/router-port fields, and TCP/SSL transport have
  all landed and are consumed by the agent. Its `createBridge` gained
  `ovs-vsctl add-br` semantics (bridge-named internal `Port`/`Interface` pair,
  so the Linux netdev materializes — issue #371); the agent's
  `ensureBridgeLocalPort` still runs as a repair path for bridges created by
  older agents.
- **Agent image** ships the chassis side only (`ovn-host` + OVS, plus an
  unconfigured `frr` for BGP advertisement); the NB/SB/northd central is the
  separate per-site `deploy/ovn-central/` unit.
- **OVN version floor** for dynamic routing (≥ 25.03, experimental) — met
  since the images moved to Ubuntu 26.04 (OVN 26.03), but still experimental
  upstream.
- **Dual-stack IPAM** — networks default to a generated ULA /64 alongside their
  IPv4 subnet, and each NIC carries one address row per family. IPv6 is
  allocated, delivered (RA + DHCPv6), and realized; what remains open is
  IPv6-specific L3 work such as external egress.
- **Metadata reachability** — the localport, its per-chassis namespace
  (STR-49), and the advertised routes (STR-53) exist, but no implicit
  security-group allow does (STR-54) and nothing listens in the namespace
  (STR-56). Until STR-56 lands, the advertised route points at an address with
  no listener behind it: a guest's cloud-init Ec2 probe now *connects* to a
  namespace that RSTs rather than failing to route, which is a faster failure
  than the pre-STR-53 unreachable-address timeout — but a chassis whose
  namespace failed to converge (see the reboot/tmpfs case above) gives the
  guest a route to a black hole and turns the probe into a minutes-long retry
  loop. That is the failure mode to watch for when rolling this out.
- **STR-53 landed on renderer-level verification only.** The entry it replaced
  gated it on STR-49 being verified against a live deployment first, for the
  black-hole reason above. What was actually verified is that the generated
  `network-config` renders correctly through all five of cloud-init's renderers
  (`netplan`, `eni`, `network-manager`, `sysconfig`, `networkd`) and that the
  resulting routes install in the kernel — strong evidence about the *guest*
  half, and what caught the gateway-less `KeyError`, but silent on whether the
  per-chassis namespace converges and binds on real hardware. A boot test on
  Ubuntu 24.04/26.04, Debian 13, Fedora, and Rocky is still owed.
- **Downgrading an agent below wire v27 leaks its metadata namespaces.** A
  pre-STR-49 agent has no concept of `strato-md-*` namespaces or `mdp*` ports, so
  it neither converges nor removes them — the mirror of the localport's nil
  protection, which is handled on the control-plane side but has no agent-side
  equivalent. Sweep by hand after a rollback:
  `ovs-vsctl --columns=name find Interface external_ids:strato-role=metadata`,
  then `ovs-vsctl del-port <name>` and `ip netns del strato-md-<uuid>`.
- **Name resolution** is a separate track: see [dns](./dns.md). What exists on
  this substrate today is DHCP option delivery only (`dns_servers` /
  `domain_name` → OVN `DHCP_Options`); the OVN `DNS` table is not yet written.

## References

- Agent OVN driver: `agent/Sources/StratoAgent/NetworkServiceLinux.swift`
- Chassis bootstrap: `agent/Sources/StratoAgentCore/OVNChassisBootstrap.swift`,
  `AgentConfig.swift`
- Network orchestration: `agent/Sources/StratoAgent/NetworkOrchestrator.swift`
- Control-plane model: `control-plane/Sources/App/Models/LogicalNetwork.swift`,
  `VMNetworkInterface.swift`
- IPAM: `control-plane/Sources/App/Services/IPAMService.swift`
- Wire protocol: `shared/Sources/StratoShared/VMSpec.swift` (`NetworkSpec`),
  `WebSocketProtocol.swift`
- SwiftOVN: <https://github.com/samcat116/swift-ovn>
- OVN dynamic routing:
  <https://docs.ovn.org/en/latest/topics/dynamic-routing/architecture.html>
