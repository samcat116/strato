# Networking Architecture &amp; Roadmap

> **Status:** Design / roadmap document. Describes the current state of Strato
> networking and the intended evolution toward L3, multi-node, and multi-site
> connectivity. Sections marked _(future)_ are not yet implemented.

Strato's networking is built on **OVN/OVS** on Linux (via
[SwiftOVN](https://github.com/samcat116/swift-ovn)) and QEMU user-mode SLIRP on
macOS (dev/test only). The control plane owns **IPAM** and network CRUD; agents
translate desired state into the OVN/OVS data plane on each hypervisor.

This document covers where we are, the target deployment topology (a SaaS
control plane orchestrating customer-run sites), the layered model we are
building toward, and a phased roadmap.

## Current state (as of this writing)

Strato does **L2-only, single-switch, single-node** networking:

- **Control plane** models a `LogicalNetwork` as a flat L2 segment: `subnet`,
  an optional `gateway` (used only as an excluded IP + DHCP `router` option),
  and DHCP config. Networks are global-by-name, optionally project-scoped for
  tenancy. IPAM (`IPAMService`) allocates non-overlapping IPs across the fleet
  for a given network name.
- **Networks are not first-class in reconciliation.** They are realized as a
  side effect of each VM's `VMSpec.networks` — the agent "finds or creates" the
  switch by name when a VM lands. `NetworkCreate`/`NetworkDelete` wire messages
  exist but are unused.
- **Agent** (`NetworkServiceLinux`) creates one OVN **logical switch** per
  network name, one **logical switch port** per NIC bound to a TAP on the
  `br-int` integration bridge, and optionally programs OVN-native DHCP. Nothing
  else — **no routers, NAT, ACLs, load balancers, or floating IPs**.
- **Deployment reality:** each agent image ships its _own_ `ovn-central`
  (northd + NB + SB) and talks to it over local Unix sockets. So the same
  network name on two agents is **two disconnected local segments** that merely
  share an IP pool. The geneve/chassis bootstrap (`OVNChassisBootstrap`, issue
  #328) is in place and `ovn-controller`'s southbound is repointable to
  `tcp:host:6642`, but nothing central exists to point it at.

### Consequences

- VMs cannot reach anything outside their own logical switch (no L3 router, no
  NAT/egress).
- A single logical network cannot span multiple hypervisors.
- There is no north-south story (no floating/public IPs).

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
  a default route. It requires an **operator-configured, dedicated external IP**
  (`[ovn_uplink] external_cidr` in the agent config) that the host does not own —
  the OVN router port claims that address, so auto-detecting and reusing the
  host's own IP would cause an ARP/address conflict. Without the uplink config,
  routers and east-west are realized but no SNAT (`externalAccess` has no effect).
  The operator connects the provider bridge to the external network out of band.
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
  registration token's `siteId` or the sites API) and carry the
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
  (`tcp:<central-host>:6641/6642`) in a multi-node site.
- **Per-site ovn-central deployment:** `deploy/ovn-central/` (compose +
  image: NB/SB/northd with plain-TCP listeners; TLS via `ovn-pki` is the
  operator upgrade path). Hypervisors run `ovn-controller` + OVS only.
- Underlay (Layer 0): LAN / customer-provided routability assumed, per plan.
- **Result:** one logical network spans a site's nodes over geneve.

Remaining in this phase: strip `ovn-central` from the agent image /
bootstrap script defaults, `ssl:` endpoint TLS configuration surface in the
agent config (SwiftOVN already supports it), and controller-failover UX
(re-designation is a manual `PUT /api/sites/:id` today; syncs handle the
handover level-triggered).

### Phase 3 — Floating IPs + north-south advertisement

- Control plane: external/floating **IP pool** in IPAM, `FloatingIP` model +
  association to a VM NIC, push `dnat_and_snat` into the site NB.
- Reachability: static routes first; then **OVN native dynamic routing + FRR**
  (needs OVN ≥ 25.03 on agents; SwiftOVN needs the `dynamic-routing*` fields on
  its router/router-port models).
- **Result:** customer-provided public IPs at a site, with BGP failover/ECMP.

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

- **SwiftOVN lacks models** for `Gateway_Chassis`, `HA_Chassis_Group`,
  `Logical_Router_Static_Route`, `Port_Group`, and the `dynamic-routing*`
  router/router-port fields. Additions needed for gateway HA, static routes,
  security groups, and native dynamic routing. (TCP/SSL transport landed —
  Phase 2 consumed it.)
- **Agent image** still ships `ovn-central` packages (harmless unless started);
  stripping them to `ovn-host`-only is Phase 2 cleanup.
- **OVN version floor** for dynamic routing (≥ 25.03, experimental).
- **IPv4-only IPAM** today; IPv6 is out of scope for this roadmap.

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
