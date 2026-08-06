# ADR 0003: One network namespace per network per chassis for IMDS

- **Status**: Accepted
- **Date**: 2026-08-05
- **Deciders**: Sam Schmitt
- **Scope**: agent-side instance metadata dataplane (STR-49), and the listener
  design it constrains (STR-56)

## Summary

The chassis-local half of the instance metadata service terminates each
network's OVN `localport` in its **own** network namespace,
`strato-md-<network-uuid>`, holding an OVS internal interface addressed
`169.254.169.254/32` and `fd00:ec2::254/128`. One namespace per network per
chassis — not one shared namespace, and not a VRF in the host namespace.

This is recorded because it is a decision STR-56 has to live with rather than
revisit: it is what makes the listener per-namespace, and per-namespace
listening does not compose cheaply with a single-process Swift agent.

## Context

An instance metadata service answers "who am I?" for the guest that asked. It
has no credential to check and no session to trace: **the source address of the
request is the entire identification mechanism**, and everything the service
returns — hostname, placement, SSH keys, user data, and eventually a SPIFFE
identity document — is scoped by that one inference.

Strato supports overlapping tenant subnets by design. Logical routers are scoped
per project (`LogicalNetwork.routerKey`), which is exactly what makes it safe
for two projects to both use `10.0.0.0/24`. So two guests on two networks can
both legitimately be `10.0.0.5`.

An OVN `localport` is instantiated on every chassis and never forwarded across
geneve tunnels, so the traffic always arrives on the guest's own host — but it
arrives on a *per-network* interface, one per network the chassis runs a NIC on.
Something has to keep those interfaces apart.

### The load-bearing precondition

Source-IP identification is only sound because **VM logical switch ports are
created with `port_security`** (`NetworkServiceLinux.portSecurityEntry`), which
pins each port to its allocated MAC and addresses. Without it a guest could
source-spoof a neighbour's tenant address on its own switch and be served that
instance's metadata — hostname, SSH keys, user data, and eventually a SPIFFE
identity document.

This is written down because nothing in the metadata code references it, so a
future change that relaxes port security on VM ports would break the metadata
service's identity guarantee with no test failing anywhere near it. If port
security is ever loosened, this design needs revisiting, not just that change.

## Decision

One network namespace per (chassis, network), named
`strato-md-<network-uuid>`, mirroring `SandboxJail`'s `strato-sbx-<id>`. The OVS
internal port is created on `br-int` with
`external_ids:iface-id=lsp-<uuid>-metadata`, moved into the namespace, given the
localport's MAC and both metadata addresses, and a default route per family so
replies to the guest's tenant address have somewhere to go.

This matches OpenStack's `ovnmeta-<network>` namespaces, which exist for the
same reason.

## Alternatives considered

### A single shared namespace for all metadata interfaces

Rejected, and the reason is attribution, not addressing.

The tempting argument against sharing is that two interfaces cannot both hold
`169.254.169.254/32` in one namespace. That argument is **wrong** and should not
be repeated: `inet_insert_ifa`'s duplicate check is scoped to a single
`in_dev`, and `fib_magic` inserts local routes with `NLM_F_APPEND`, so the same
`/32` on two devices in one namespace is the ordinary anycast pattern.

The real objections survive without any kernel trivia:

- **Attribution.** With overlapping subnets, a listener in a shared namespace
  sees identical `(source, destination, port)` tuples for guests on different
  networks and cannot decide which instance to answer. Handing instance A's SSH
  keys and identity to instance B is the failure mode, and it is silent.
- **Reply routing.** A shared namespace has one route to `10.0.0.0/24`, so at
  most one of the two networks works, and which one depends on insertion order.

`SO_BINDTODEVICE` would recover attribution but not routing, and it would put
the correctness of the whole service on every socket in the listener remembering
to set it.

### A VRF per network in the host namespace

`ip link add mdvrf-<n> type vrf table N`, enslave the metadata interface, one
`SO_BINDTODEVICE` socket per VRF. This gives both attribution and per-network
routing tables without leaving the host namespace, and it is *strictly friendlier
to a single-process Swift agent*: `setns(2)` is per-thread and does not compose
with Swift's concurrency runtime, which schedules continuations across a shared
thread pool, so a namespace-entering listener realistically means a helper
process per namespace (OpenStack runs an haproxy per `ovnmeta-*` namespace for
precisely this reason).

Rejected anyway, on three counts:

- It leaves every metadata interface in the host namespace, where a bug in
  route or rule programming leaks tenant traffic into the host's own routing
  rather than into an empty namespace. The blast radius of getting a namespace
  wrong is one network; the blast radius of getting a VRF rule wrong is the
  host.
- It has no precedent in this codebase, whereas namespaces do
  (`SandboxJail`, `SandboxNetnsAttachmentPlan`, `FirecrackerSandboxRuntime`),
  including the `ip`-command plan shape and its exact-argv tests.
- It has no precedent upstream either, so operators debugging it have nothing
  to pattern-match against.

The cost is real and lands on STR-56, which now has to pick between a helper
process per namespace and some form of namespace-entering listener. That is the
right place to pay it: the alternative is choosing the listener architecture
here, with no listener in hand.

## Consequences

- **STR-56 inherits a per-namespace listener requirement.** Whatever it picks,
  it cannot assume one socket serves every network on the host.
- **Namespace count scales with networks-per-chassis, not VMs.** Each is a
  namespace, one veth-less internal port, and two addresses — cheap, but not
  free, and they are torn down when the last local NIC on the network goes away.
- **The IPv6 address is added with `nodad`.** Duplicate Address Detection leaves
  an address `tentative` for roughly a second, during which `bind()` fails with
  `EADDRNOTAVAIL`. Per-namespace uniqueness is guaranteed by construction, so
  DAD buys nothing and would cost the listener a startup race on every agent
  restart.
- **No `rp_filter` or `disable_ipv6` sysctls are set**, though both looked
  necessary. Network sysctls are per-namespace and a fresh namespace starts at
  the kernel defaults rather than inheriting the host's; and even under strict
  reverse-path filtering a guest's request passes, because the reverse lookup
  for its tenant address hits the namespace's default route and resolves to the
  interface the packet arrived on.
- **Observation cannot key on the OVS row alone.** The interface row and the
  namespace have different lifetimes: `conf.db` is on disk, `/var/run/netns` is
  tmpfs. After a host reboot the row returns, `ovs-vswitchd` recreates the
  netdev, and `ovn-controller` rebinds the localport and answers guest ARP for
  the metadata address — with no namespace, no addresses, and no routes behind
  it, so guests hang instead of failing fast. `ObservedMetadataPort` therefore
  probes the namespace path alongside the row, and a setup that fails partway
  rolls the namespace back so the next pass observes an honest "not built".
- **No MTU is set on the namespace interface**, unlike the sandbox NIC path.
  Deliberate rather than an oversight: OVS derives an internal port's MTU from
  the bridge minimum, and the guest negotiates TCP MSS from its own side, so
  there is no path here that a smaller-than-default MTU would fix. The sandbox
  path sets one because a veth pair defaults to 1500 regardless of the fabric.
- **Moving an OVS internal port into a namespace is safe**, unlike moving a TAP
  (STR-99, where the OVS port dies silently while the OVSDB rows survive). An
  internal port is a datapath port owned by `ovs-vswitchd`, and relocating one
  is the standard OpenStack pattern. The scar is close enough that the agent
  verifies `ofport` and `error` after the move rather than trusting the rows.
