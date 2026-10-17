# Single-NIC OVN setup: discovery and implementation plan

**Management-NIC migration is not implemented.** Installing the agent or setting
`[ovn_uplink]` does not safely move an existing management connection into OVS.
Do not run `ovs-vsctl add-port br-ex ens18` on a remotely managed host. A cutover
can interrupt SSH, DHCP and IPv6 even when its command succeeds. No zero-outage
claim is made.

## Install and establish compatibility first

Use the normal [agent enrollment and installer](agents.md#one-command-install).
The installer installs the host prerequisites and agent; it does not migrate
management networking. Linux hypervisors need KVM, QEMU/libvirt >= 11.5, swtpm,
OVS/OVN host tools, SPIRE and authenticated control-plane reachability. Published
main binaries are built with Swift 6.4 on Ubuntu 24.04 with a static Swift runtime
and probed on Ubuntu 26.04. They still require host system libraries, including
libcurl; this is not a fully static libc executable. Installing a main binary
requires an explicit `--version main-<12 lowercase hex>`; `latest` stays stable.

Download the exact commit's `agent-manifest.json`, agent archive and `.sha256`
sidecar from its GitHub prerelease. The archive contains `strato-agent` at its
root. The manifest records the full commit and workload wire version, alongside
the existing schema-v1 platform/checksum/member contract. Check `--version` and
review [update bridge and rollout ordering](../architecture/agent-updates.md)
before assigning an update. A newer artifact is not authorization to upgrade a
host. Keep a verified previous binary and its manifest/checksum for recovery.

## Collect current evidence

On the target host, after approving read-only discovery, use the reviewed tool
from the same source commit or release. It requires Python 3 and the existing
host commands; it installs nothing:

```bash
umask 077
sudo python3 single-nic-discover.py --interface ens18 > single-nic-evidence.json
```

This only queries state. It captures IPv4/IPv6 addresses, all route tables and
policy rules, detailed link state, networkd/DNS state, manager activity, Netplan's
merged configuration, persistent file hashes, and OVS bridge/port/interface IDs.
Treat the output as private host configuration; Netplan can contain secrets.
Missing commands, permission failures, timeouts, competing managers and symlinked
configuration are visible in `blockers`. Exit zero means collection finished,
never that a migration is safe: `migrationSupported` is always false. Evidence
can become stale immediately; a future transaction must rediscover under its
exclusive lock and compare the approved plan's hash before mutation. The collector
is not a supported-configuration validator and does not establish DHCP identity
or ownership merely because a command returned successfully.

Historical development-host evidence was Ubuntu 26.04.1, ens18 with DHCP
`192.168.3.85/24`, gateway/DNS `192.168.3.1`, IPv6 RA, MTU 1500, Netplan/networkd
and inactive NetworkManager. **None of these are current assertions.** No host
was queried or changed for this PR. The additional LAN address for OVN SNAT has
not been reserved; no example address here is an allocation.

## Intended topology

The management MAC and all management L3 behavior move from ens18 to an OVS
internal interface on the provider bridge (normally `br-ex`). ens18 becomes an
OVS port and carries the existing LAN. `physnet-strato:br-ex` connects the OVN
provider network. OVN's logical router owns a *distinct reserved LAN address*
for its gateway port and SNAT; it must never claim the management address.
`OVNUplinkConfig` already models the external CIDR/gateway, bridge and physnet,
including optional IPv6 uplink values. Bridge/mapping helpers are lower-level
reconciliation primitives, not a migration/recovery protocol. In particular the
current mapping merge can replace an existing physnet mapping; it is not an
ownership check and must not be used as one by a future coordinator.

The operator must reserve an unused address outside competing DHCP allocations,
verify its subnet/gateway and intended site ownership, and supply it explicitly.
Discovery must prove it is not assigned to this host; a negative ARP probe alone
does not prove that the address is available. DHCP management and IPv6 RA remain
independent of the router's dedicated SNAT identity.

## Follow-up A: persistent plan and discovery validator

Support a narrowly defined Netplan/networkd Ethernet case first. Refuse unknown
renderers, NetworkManager/ConnMan/dhcpcd competitors, overlapping networkd units,
unsupported bonds/VLANs/VRFs/bridges, alternate namespaces, unknown policy routing,
foreign OVS objects/dependencies, generated/cloud-init ownership that cannot be
preserved, and ambiguous configuration. Never silently reduce a config to its
IPv4 address and default route.

Capture original files (bytes, owner, mode, symlink status and hashes), generated
units, active leases and manager state in a private durable journal. Record both
physical and effective MAC, DHCPv4 client identifier, DHCPv6 DUID and IAID,
networkd matching/identity behavior, DHCP options/overrides, static routes,
route metrics/tables/rules, IPv6 RA/SLAAC/privacy/link-local settings, address
lifetimes, DNS/search domains/default-route policy and MTU. Prove that the chosen
persistent representation preserves these identities on the internal interface,
including across reboot. Reject configurations whose identity cannot be derived
and preserved. A new interface name must not accidentally produce a new IAID,
DHCP lease or IPv6 address.

Build a canonical approved plan hash covering the exact snapshot, proposed file
bytes, bridge/internal/physical names, reserved uplink, ownership IDs, deadline
and confirmation requirements. Validate generated configuration in an isolated
Netplan root with `netplan generate` before replacing persistent files. Validation
is necessary, not proof that live connectivity will survive.

## Follow-up B: independent recovery and transaction execution

Use an OS-held exclusive lock plus a durable transaction UUID/fencing generation.
Persist and fsync the original snapshot and each phase transition before issuing
its side effects. Journal owned OVS UUIDs/external IDs, file hashes, plan hash,
absolute recovery deadline and confirmation nonce. Reject a second transaction;
reapplying a completed matching plan verifies state, and a differing plan needs
a fresh review. Never treat uncertain writes as failed writes: read back files,
OVS UUIDs and actual links/routes before deciding to retry. All waits are bounded.

An independently installed recovery service and boot recovery path must exist
before cutover. Arm the absolute deadline and verify the worker is durably armed
before *any* network mutation. It must work after agent death, SSH loss and reboot,
without the agent, control plane, DNS or network. Expired/incomplete transactions
recover on boot; corrupt or ambiguous journals require console intervention.
Persist fencing state so stale workers cannot undo a newer transaction or race a
confirmation. Netplan try alone is insufficient for virtual-interface rollback.

Suggested phases are `prepared`, `recoveryArmed`, `persistentWritten`,
`managementMoved`, `validating`, `confirmed`, `rollingBack`, `restored` and
`needsConsole`. Each transition has durable preconditions and explicit recovery
behavior. Persist candidate files atomically with original metadata; then create
only owned OVS objects and migrate management. Check actual identities and
connectivity against the approved plan throughout. Do not introduce workload
connectivity or SNAT before management validation has succeeded.

Confirmation needs both a fresh inbound connection to the new management path
from an approved external verifier, carrying the transaction nonce, and fresh
authenticated control-plane health for the enrolled agent. Bind both to this
transaction, host, plan hash and validation interval; an old SSH session or an
outbound heartbeat is insufficient. If either proof is missing by the deadline,
recover. A confirmation uses the lock/fence, durably commits the result, then
retires the corresponding worker. An uncertain confirmation must be read back.

Rollback first restores management L3 and persistent configuration. Verify actual
addresses, DHCP identity, IPv6, routes and inbound access; command exit zero is
not recovery success. Remove only OVS rows proven owned by this transaction and
still matching its recorded IDs. Compare file hashes before restoring them.
Protect concurrent administrator edits and foreign ports/mappings; a conflicting
edit requires `needsConsole` and an actionable conflict report, never broad
bridge deletion or an unconditional file overwrite. Keep evidence until recovery
has been verified. DHCP failure must not leave the worker claiming `restored`.

## Follow-up C: teardown and acceptance tests

Teardown first drains workloads or durably blocks new placement. Refuse foreign
bridge ports, mappings, OVN dependencies or unresolved transactions. Restore and
prove the original persistent management path before detaching/removing owned OVS
state. Teardown has its own lock, deadline, journal and recovery path; it must be
safe to resume after process death or reboot.

Use disposable Linux VMs with console access and a separate inbound verifier.
Inject failures before and after every durable phase and every uncertain write;
kill the agent/worker, drop SSH, reboot, break DHCP/DNS/RA and expire readiness
budgets. Exercise stale workers, duplicate confirmation, partial file/OVS writes,
concurrent administrator edits, unsupported ownership, repeated apply and teardown,
foreign dependencies, unchanged DHCP/DUID/IAID and IPv6 behavior. Prove recovery
with actual inbound management and authenticated control-plane health. Fixture
unit tests and `netplan generate` alone cannot establish these properties.

## Console recovery requirements

Before any later live trial, verify an independent hypervisor/serial console,
a tested local recovery command and private originals on the host. Record the
transaction ID, original interface/MAC, active phase, journal location and backup
file hashes in the trial runbook. The recovery command must acquire/fence the
transaction, compare current files/OVS IDs, restore original Netplan/networkd
configuration, reestablish management and report remaining conflicts. Verify the
original path through a new inbound connection before cleanup. If ownership is
ambiguous, preserve state and resolve the specific conflict from the console.
There is currently no implemented automatic recovery command; therefore a live
management cutover remains blocked until those follow-ups pass their tests and
an exact action-time cutover is approved.
