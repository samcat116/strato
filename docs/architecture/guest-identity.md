# Guest Identity (Proposal)

**Status: design proposal.** The node-side attestation mechanism has been proven
against a real SPIRE 1.9.6 server and agent with a spike
(`strato-agent spiffe-delegated-probe` — see
[What the spike proved](#what-the-spike-proved)); nothing else here is
implemented. Issue [#496](https://github.com/samcat116/strato/issues/496)
(STR-16) is the umbrella.

## What this is

Strato already runs a SPIRE agent on every hypervisor node, but only for one
workload: strato-agent itself, which presents its X.509 SVID to authenticate the
control-plane WebSocket. The identity infrastructure is on every node in the
fleet and serves exactly one process per node.

The proposal is to point that infrastructure at the workloads Strato hosts.
A customer's VMs and sandboxes get their own SVIDs — rotating, bundle-backed,
delivered through a standard SPIFFE Workload API socket inside the guest — for
**their** service-to-service mTLS. Not Strato consuming SPIFFE, but Strato *being*
the SPIFFE provider for what it runs.

That is a product surface, not internal plumbing. The distinction that matters
to a customer is between "we hand you a certificate" and "your workloads speak
SPIFFE and it just works": the first means writing Strato-specific rotation
handling into every service, the second means Envoy, go-spiffe, java-spiffe, and
spiffe-helper work unmodified.

## The invariant this inherits

From [iam](./iam.md): **identity names the principal; it never carries
authorization.** A guest SVID grants nothing in Strato. It is a lookup key and
nothing else — what a workload may do comes from `role_bindings` against a
registered principal, which is what
[#789](https://github.com/samcat116/strato/issues/789) (per-VM
`WorkloadRegistration`) and [#492](https://github.com/samcat116/strato/issues/492)
are for. Those are independent of this document: this one produces identities;
those make them principals.

The corollary is a non-goal. No role, scope, project, or claim is ever encoded
into a guest's SPIFFE ID or into the SVID's extensions. The path carries a UUID
and nothing else.

## What the guest actually gets

A Unix domain socket inside the guest, at a conventional path
(`/run/spire/sockets/agent.sock`), speaking the standard SPIFFE Workload API:

- `FetchX509SVID` — the guest's own SVID and key, re-delivered on every rotation
  for as long as the stream is held.
- `FetchX509Bundles` — the trust domain's X.509 authorities, plus the roots of
  any domain the guest's entry federates with.

Set `SPIFFE_ENDPOINT_SOCKET` and every SPIFFE-aware library finds it. Nothing in
the guest needs to know Strato exists.

JWT-SVIDs (`FetchJWTSVID`, `FetchJWTBundles`) are deliberately out of the first
cut: they are bearer tokens, which is a wider credential surface than mTLS, and
they are only useful once something is prepared to accept them. See
[#495](https://github.com/samcat116/strato/issues/495) for the shape that would
take on the control-plane side.

## The attestation model

The problem SPIRE cannot solve on its own: **workload attestation inspects a
local process**. The `unix` attestor reads `/proc`; the `docker` and `k8s`
attestors ask a container runtime. A guest inside a microVM is none of these —
from the host's point of view there is a `qemu-system` or `firecracker` process,
and everything interesting is on the other side of a hardware boundary. There is
no attestor plugin that can see into it, and writing one would mean
reconstructing facts the hypervisor already knows.

Which is the whole argument: **Strato does not need a SPIRE attestor plugin for
guests, because Strato created the guests.**

So the chain runs like this:

1. **The control plane creates the registration entry.** It knows the guest
   exists and knows which node hosts it, because it placed it there:

   ```
   spiffeID  = spiffe://<org-trust-domain>/vm/<vm-uuid>
   parentID  = spiffe://<trust-domain>/node/<node-name>
   selectors = [ strato:instance:<vm-uuid>, strato:kind:vm ]
   ```

   This is the same `BatchCreateEntry` call
   `SPIRERegistrationService.provisionAgent` already makes for node identities
   (`control-plane/Sources/App/Services/SPIFFE/SPIRERegistrationService.swift`).

2. **SPIRE syncs that entry only to the node it is parented to.** This property
   is load-bearing and easy to undersell: the node scoping Strato would
   otherwise have to implement — and remember to keep implementing — as an
   explicit "is this VM actually placed here?" check falls out of SPIRE's entry
   distribution for free. A node that does not host a guest never receives that
   guest's entry, so it cannot obtain that guest's SVID even if strato-agent on
   it is fully compromised.

3. **strato-agent subscribes as an authorized delegate.** SPIRE's
   [Delegated Identity API](https://spiffe.io/docs/latest/deploying/spire_agent/#delegated-identity-api),
   served on the agent's admin socket, exists for exactly this case: a process
   that supplies "the selectors that would normally be obtained during workload
   attestation" on another workload's behalf. The local SPIRE agent attests
   strato-agent through its ordinary `unix` attestor and checks the resulting
   SPIFFE ID against `authorized_delegates` — re-checked on **every** stream
   update, so revoking a delegate takes effect without restarting anything.

4. **strato-agent decides which guest receives it.** It can do this soundly
   because the host↔guest channel is per-guest and kernel-mediated: a
   Firecracker vsock socket path belongs to exactly one sandbox; a vhost-vsock
   peer CID belongs to exactly one VM. There is no credential to check and none
   to steal. **The transport is the attestation.**

### Proven, not assumed

Step 3 was the one genuinely uncertain link, so it was spiked before anything
else was designed around it. `strato-agent spiffe-delegated-probe` (added by
STR-16) dials the admin socket, subscribes with a guest's selectors, and reports
one of four outcomes. See [the appendix](#appendix-verifying-this-on-a-node) for
the recipe and [What the spike proved](#what-the-spike-proved) for the results.

One finding is worth pulling forward, because a prior issue
([#784](https://github.com/samcat116/strato/issues/784)) recorded the opposite:
**SPIRE does not restrict delegated selectors to known attestor plugin names.**
`SubscribeToX509SVIDs` parses them with `api.SelectorsFromProto` and hands them
straight to `manager.SubscribeToCacheChanges`, with no plugin lookup anywhere in
the path. A synthetic `strato:instance:<uuid>` selector works exactly as well as
`unix:uid:0`, which makes sense once you notice that the delegate — not a
plugin — is what vouched for the workload.

## Naming

| Path | Names | Status |
|---|---|---|
| `spiffe://<td>/node/<name>` | a hypervisor node (join-token attestation) | existing |
| `spiffe://<td>/agent/<name>` | the strato-agent workload on that node | existing, reserved |
| `spiffe://<td>/control-plane` | the control plane | existing |
| `spiffe://<org-td>/vm/<vm-uuid>` | **a guest VM** | to reserve |
| `spiffe://<org-td>/sandbox/<sandbox-uuid>` | **a guest sandbox** | to reserve |

`/vm/` is fixed by [#789](https://github.com/samcat116/strato/issues/789) and
adopted verbatim rather than re-litigated. `/sandbox/` is its twin.

Two prefixes rather than a shared `/instance/`: `resource_kind` is already
`virtual_machine | sandbox` throughout the codebase (see `CONTEXT.md`), and
collapsing the distinction in the identity namespace would be the one place it
does not hold.

**UUIDs, never names.** A VM's name is mutable and reusable; a SPIFFE ID that can
be re-pointed at a different resource is a lookup key that lies, and every
consumer of it — role bindings, audit logs, a peer's authorization policy —
would silently follow the rename.

**The organization's trust domain, not the platform's.** Guest identities belong
in `org-<16 hex>.<platform td>` (`control-plane/Sources/App/Models/OrgTrustDomain.swift`),
so a customer's workloads mTLS with each other without ever chaining to the
platform CA that also signs Strato's own infrastructure. When
`SPIRE_ORG_TRUST_DOMAINS_ENABLED` is off, guests fall back to the platform
domain — that is a **degraded** mode, not an equivalent one, and the feature
should say so rather than quietly cross-signing tenants under one root.

Both prefixes must be reserved in `WorkloadRegistry.validateRegistrable` exactly
as `/agent/` is today, so a system administrator cannot hand-register a URI that
a VM will later be minted into.

## Selectors, and the subset hazard

Every guest entry carries two selectors:

```
strato:instance:<uuid>     # the uniqueness carrier — mandatory
strato:kind:vm|sandbox     # makes a cross-kind match structurally impossible
```

SPIRE matches an entry when the **entry's** selector set is a subset of the
**requested** set. Requesting more selectors therefore matches *more* entries,
not fewer, which is the opposite of the intuition most people bring to a filter.
Two rules follow, and both are security properties rather than style:

1. The agent subscribes with a guest's **exact** selector set. Never a superset,
   never a catch-all.
2. **No entry may carry only non-unique selectors.** An entry with just
   `strato:kind:vm` would be matched by every per-instance subscription on the
   node. `strato:instance:<uuid>` is mandatory on every guest entry, and
   `strato:kind` never appears alone.

Selector values may themselves contain colons, so parsing splits on the **first**
colon only — matching SPIRE's own `api.SelectorsFromProto`. `DelegatedSelector`
in `agent/Sources/StratoAgentSPIFFE/DelegatedIdentityClient.swift` does this.

## Delivery: vsock, terminating in a Workload API socket

strato-agent becomes a **per-node guest Workload API gateway**. For each guest it
hosts it holds one delegated-identity subscription and serves a minimal Workload
API over that guest's vsock channel, **one identity per connection** — a guest
cannot enumerate, request, or even name any identity but its own. Inside the
guest, a small forwarder pipes vsock ↔ `/run/spire/sockets/agent.sock`.

Why this shape:

- **vsock is the only channel that generalizes.** Sandboxes have no guest network
  at all today (`SandboxSpecBuilder.guestNetworkingSupported = false`), which
  eliminates every IP-based option outright. Firecracker has no virtio-serial,
  which eliminates the channel QEMU VMs already have. vsock is the one transport
  both hypervisors can carry.
- **Attestation is free** — see step 4 above.
- **It is a stream, so rotation is a push.** No polling, no re-provisioning, no
  restart, and no "certificate expired at 3am" class of incident.
- **The guest runs unmodified software**, which is the product claim.

### Per-hypervisor status

- **Sandboxes: ready.** vsock already carries the control protocol
  (`shared/Sources/StratoShared/SandboxGuestControlProtocol.swift`,
  `currentVersion = 3`), guest PID 1 is ours (`sandbox-guest/init/`, Rust), and
  `supportsReidentify(_:)` is the established precedent for version-gating a new
  capability. Adding a v4 identity port plus the forwarder is a contained change.
- **VMs: one device short.** `QEMUService` attaches `virtio-serial-pci` (console
  and QGA) but no vsock. Adding `vhost-vsock-pci` with per-VM CID allocation is
  the single blocker for parity, and it drags in CID collision handling across
  re-adoption and checkpoint/restore — its own issue, and the largest one.
- **The guest daemon for VMs** is installed once by cloud-init
  (`CloudInitProvisioner.makeNoCloudISO`, `write_files`/`runcmd`). Cloud-init is
  a legitimate **bootstrap** channel: it installs the daemon and **never carries
  an SVID**. That distinction is the difference between a one-shot channel used
  correctly and one used as a credential store, and it should survive any later
  round of simplification.

## Rotation, revocation, migration, and forks

- **Rotation**: SPIRE pushes each new SVID down the delegated stream; the agent
  forwards it; the guest's own Workload API stream delivers it. Lifetime is the
  entry's `x509SVIDTTLSeconds` (`SPIRERegistrationConfig.svidTTLSeconds`,
  default one hour).
- **Revocation is entry deletion.** Deleting the entry makes SPIRE push an
  **empty** SVID set — the identity is torn down within seconds rather than
  outliving the decision by up to a full TTL. This is a capability a
  centrally-minted SVID cannot offer at all, and the spike verifies it directly.
- **Migration means re-parenting the entry** to the destination node before the
  guest resumes there; the source node's stream then empties on its own. This is
  the one piece with real distributed-systems risk — ordering against the resume
  — and it gets its own issue rather than a footnote.
- **Forks and clones**: a checkpoint-forked sandbox is a *new* principal and must
  not inherit its parent's key. Because identity is pushed over a live channel
  rather than baked into a config drive or an image, this composes with the
  existing `reidentify` machinery
  ([#427](https://github.com/samcat116/strato/issues/427), and the clone-safety
  policy in [sandboxes](./sandboxes.md)) instead of fighting it. Every rejected
  alternative below fails this case, most of them silently.

## Trust and blast radius

State this without softening, because it is the real cost of the design:

> A SPIRE delegate is **unconstrained**. It may subscribe with any selectors and
> receives any SVID in that node's cache. SPIRE 1.9.6 has no per-delegate
> selector scoping — `pkg/agent/api/delegatedidentity/v1/service.go` checks only
> that the caller's SPIFFE ID appears in `authorized_delegates`.

Why that is nonetheless acceptable here:

- **The cache is node-scoped.** It holds only entries parented to that node: the
  agent's own, plus the guests it hosts. So the delegate grant's reach is exactly
  *"the guests running on this node"* — which is already strato-agent's reach. It
  spawns those processes, owns their disks, and can read their memory through the
  hypervisor. **The grant adds no capability the agent did not already have**, and
  a node compromise remains a node-scoped incident.
- **The invariant that must keep holding**, stated so it can be checked: *nothing
  other than the agent's own entry and guest entries may ever be parented to a
  node's SPIFFE ID.* If a future colocated component is parented there, it
  immediately becomes reachable by the delegate. This is exactly the kind of
  thing that gets violated by accident two years later, so it belongs in review
  checklists, not just in prose.
- **Key custody.** SPIRE mints the key and hands it to the delegate, so a guest's
  private key transits strato-agent's memory and the vsock channel. This is
  inherent to any host-mediated delivery. The only design that avoids it is
  in-guest CSR generation, and that is a genuine advantage of the rejected
  `MintX509SVID` route — which buys nothing against a threat model in which the
  host can read guest RAM anyway.
- **Socket hygiene**: `/var/run/spire/admin.sock`, root-owned, in a 0700
  directory, never bind-mounted into a container and never reachable from a
  Firecracker jail (`SandboxJailPlan` must not gain a path to it).
- **Off by default.** The admin socket and `authorized_delegates` ship behind an
  explicit installer opt-in, mirroring #789's "opt-in per VM, default off" one
  layer down. Enabling identity for a VM means anything inside it can act as that
  principal; enabling the delegate grant means every guest on a node *could*, if
  the agent were compromised. Both are operator decisions.

## Rejected alternatives

Each is killed by a specific fact about Strato, not by taste.

**1. A nested SPIRE agent inside the guest, `x509pop` node attestation.**
The most SPIFFE-idiomatic option, and the one that deserves the most careful
rebuttal. Killed three times over: (a) the guest must reach the SPIRE *server*
over the network, and sandboxes have no network; (b) the per-guest x509pop
keypair is itself a secret that must be delivered into the guest, so this does
not solve the delivery problem — it relocates it into a *one-shot, at-rest* form
that survives cloning; (c) it makes every guest an attested **node**, turning a
fleet-sized workload population into a fleet-sized node table with node-eviction
semantics and per-guest attestation state on the platform's SPIRE server.

**2. `tpm_devid` node attestation.** Superficially attractive because Strato does
run swtpm for VMs. Killed by Firecracker having no TPM (so it cannot generalize
to sandboxes) and by per-guest DevID certificates requiring a device-identity CA
— a larger project than this one.

**3. Firecracker MMDS.** Already wrapped and ready
(`SwiftFirecracker/Sources/SwiftFirecracker/Models/MMDS.swift`,
`FirecrackerManager.configureMMDS`) and called by nothing. Killed by needing
guest networking; by being sandbox-only with no QEMU counterpart; and by being a
pull-only metadata store readable by anything in the guest that can reach the
link-local address — no stream, so no rotation and no revocation.

**4. cloud-init `write_files`.** The NoCloud ISO is built once during `createVM`
and attached read-only — structurally a one-shot bootstrap channel. It cannot
rotate an hour-lived credential, and it is VM-only. **Kept for what it is good
at**: installing the guest daemon.

**5. The sandbox config drive.** `SandboxConfigDrive.standardBlockImageBytes`
(256 KiB) is part of the warm-snapshot cache key, so growing the document
silently disables warm start. Worse, the drive is written before boot and its
contents are baked into snapshot device state — it is a *template* shared across
warm-started sandboxes, which is precisely the wrong place for a per-instance
secret, and a fork would clone it.

**6. Control-plane-minted SVIDs (`MintX509SVID` / `MintJWTSVID`).** Retained for
its own use case — see the next section — but rejected as the general guest
mechanism, because a minted SVID lives **outside SPIRE's entry model**: no entry
means no revocation by deletion (TTL-bounded only), no selector scoping, and no
rotation stream, so every renewal becomes a control-plane round trip over the
agent WebSocket, for every guest in the fleet, forever. Node scoping also has to
be re-implemented as an explicit placement check rather than falling out of entry
sync.

**7. Passing the SPIRE agent's Workload API socket into the guest** (virtiofs,
9p, or any passthrough). Killed by semantics rather than plumbing: the SPIRE
agent attests the *calling process*, so whatever the guest reached would be
attested as the host-side proxy. The guest would receive **strato-agent's**
identity, not its own.

## Relationship to the existing issue cluster

[#784](https://github.com/samcat116/strato/issues/784) / #789 / #791 / #792 /
#796 form a coherent, already-designed cluster, and #784 explicitly rejects
delegated identity. That rejection is not being overturned — it answers a
different question.

|  | #784's cluster | This document |
|---|---|---|
| Problem | a VM authenticating **to the Strato API** | the guest's **own** service-to-service mTLS |
| Credential | JWT-SVID, bearer | X.509 SVID + key + trust bundle |
| Lifecycle | minted centrally, one-shot | rotating stream, revocable by entry deletion |
| Consumer | Strato's own API | unmodified SPIFFE-aware software in the guest |

`MintJWTSVID` cannot serve the second row: there is no bundle, no rotation, and
nothing for a go-spiffe client to attach to. Both routes coexist.

Two of #784's three stated objections still stand and are answered above — it
does require `authorized_delegates` on every node (hence the opt-in installer
flag) and a new proto plus per-guest entries (both now done or scoped). The
third — *"a VM is not a local process, so there are no selectors to attest
against"* — is the one the spike disproves: delegated selectors are not
validated against attestor plugins, so a synthetic selector type is fine.

#789 remains exactly as filed: this document produces the identity, #789 makes it
a principal, and they can land in either order.

## What the spike proved

`strato-agent spiffe-delegated-probe` (in `agent/Sources/StratoAgent/`, with the
client and report types in `StratoAgentSPIFFE`) reports one of four outcomes:
`DELEGATED IDENTITY OK`, `REFUSED`, `UNAVAILABLE`, or `NO ENTRY MATCHED`. The
last is deliberately not a success: an empty SVID set is a normal, meaningful
answer from this API, and reporting it as OK would make the whole exercise
meaningless.

The runs below are against a real SPIRE 1.9.6 server and agent, join-token
attested, with a synthetic `strato:` selector type — not a fake.

**1. The mechanism works.** An entry parented to this node, with selectors no
attestor plugin produces, yields a guest SVID to the delegate:

```
SPIRE delegated identity probe
  admin socket   /tmp/spike/admin.sock (present)
  selectors      strato:instance:11111111-1111-1111-1111-111111111111  strato:kind:vm
  identities     1
    spiffe://strato.local/vm/11111111-1111-1111-1111-111111111111
      expires    2026-08-06T01:54:39Z (in 59m)
      chain      1 certificate(s)
      key        138-byte PKCS#8 private key received (not printed)
      federates  (none)
  trust bundles  strato.local: 1 X.509 authority

DELEGATED IDENTITY OK
```

That SPIFFE ID names a VM. No workload attestor on the host could have produced
it, because there is no such workload on the host.

**2. The delegate grant is what does the work.** With the agent's SPIFFE ID
swapped out of `authorized_delegates` and spire-agent restarted, the same call
fails closed:

```
  detail         SPIRE refused this process as a delegate (caller not configured as an
                 authorized delegate). Add this agent's SPIFFE ID to `authorized_delegates`
                 in the `agent { }` block of /etc/spire/agent.conf and restart spire-agent.

DELEGATED IDENTITY REFUSED — this agent's SPIFFE ID is not in authorized_delegates in the
agent { } block of /etc/spire/agent.conf
```

**3. Node scoping is real, not a convention.** An entry with the *exact* right
selectors but `-parentID spiffe://strato.local/node/other-node` is invisible
here — the server never synced it to this node, so the delegate cannot reach it
no matter what it asks for:

```
  selectors      strato:instance:22222222-2222-2222-2222-222222222222  strato:kind:vm
  identities     0

NO ENTRY MATCHED — no registration entry with these selectors has synced to this node;
check the entry's parentID is spiffe://<trust-domain>/node/<this-node>
```

This is the structural property the whole design leans on, and it holds without
Strato writing a placement check.

**4. Revocation propagates in seconds, not in a TTL.** With `--watch` held open
and `spire-server entry delete` run in another shell, the stream pushed an empty
set — the SVID had 59 minutes left:

```
    spiffe://strato.local/vm/11111111-1111-1111-1111-111111111111
      expires    2026-08-06T01:55:51Z (in 59m)
DELEGATED IDENTITY OK

  identities     0
NO ENTRY MATCHED — ...
```

This is the clearest separation from a centrally-minted SVID, which can only be
outlived.

### One thing the spike corrected

`delegatedidentity.proto` documents `ca_certificates` as "a map keyed by trust
domain name". SPIRE 1.9.6 actually writes `caCerts[td.IDString()]` — the trust
domain's SPIFFE ID, `spiffe://strato.local`. Written to the comment, the
conversion produced a bundle map whose keys nothing could look up; the real
agent is what surfaced it. `DelegatedIdentityConversion.makeTrustBundles` now
normalizes both forms, and the unit test is parameterized over the two.

That is a small bug, but it is the kind of thing only a real server finds, and
it is the argument for spiking before designing further layers on top.

## Appendix: verifying this on a node

Nothing in `deploy/` is changed by the spike — enabling the admin socket fleet-wide
is a trust change and belongs behind an opt-in installer flag, not in an upgrade
nobody asked for. The steps below are therefore manual.

**1. Enable the admin socket.** In `/etc/spire/agent.conf`, inside the existing
`agent { }` block:

```hcl
    admin_socket_path = "/var/run/spire/admin.sock"
    authorized_delegates = ["spiffe://strato.local/agent/<node-name>"]
```

Then `systemctl restart spire-agent`. Two things go wrong here first:

- The path must **not** be inside (or under) the directory holding the Workload
  API socket. `deploy/agent/install.sh` puts that at
  `/var/run/spire/sockets/workload.sock`, and spire-agent refuses to start with
  *"admin socket cannot be in the same directory or a subdirectory as that
  containing the Workload API socket."* `/var/run/spire/admin.sock` is correct;
  `/var/run/spire/sockets/admin.sock` is not.
- The delegate is the agent's **workload** SVID (`spiffe://<td>/agent/<name>`),
  not its node ID (`/node/<name>`). Confirm with
  `spire-agent api fetch x509 -socketPath /var/run/spire/sockets/workload.sock`,
  run as root so the `unix:uid:0` selector matches.

**2. Mint a guest entry** on the SPIRE server (compose:
`docker compose exec spire-server /opt/spire/bin/spire-server ...`):

```sh
spire-server entry create \
  -spiffeID spiffe://strato.local/vm/11111111-1111-1111-1111-111111111111 \
  -parentID spiffe://strato.local/node/<node-name> \
  -selector strato:instance:11111111-1111-1111-1111-111111111111 \
  -selector strato:kind:vm \
  -x509SVIDTTL 3600
```

Check it targets the right node with
`spire-server entry show -parentID spiffe://strato.local/node/<node-name>`.

**3. Probe**, as root on that node:

```sh
strato-agent spiffe-delegated-probe \
  --selector strato:instance:11111111-1111-1111-1111-111111111111 \
  --selector strato:kind:vm
```

**4. Run the negatives**, which are the actual evidence: remove the delegate
authorization and re-run (expect `REFUSED`); create an entry parented to a
different node and probe for it (expect `NO ENTRY MATCHED`); and with `--watch`
running, `spire-server entry delete -entryID <id>` (expect an empty update within
seconds). Outputs from all four are in
[What the spike proved](#what-the-spike-proved).

The whole recipe runs against a throwaway SPIRE server and agent on one host —
no VMs, no hypervisor, no control plane — which is how the results above were
produced.

## Staging

Filed under [#496](https://github.com/samcat116/strato/issues/496):

1. Enable the SPIRE agent admin socket behind an opt-in installer flag
   (`deploy/agent/install.sh`, `deploy/compose/spiffe/`, Helm).
2. Reserve `/vm/` and `/sandbox/` in `WorkloadRegistry.validateRegistrable`.
3. Per-sandbox `WorkloadRegistration` lifecycle — the sandbox twin of #789.
4. Guest SPIRE entry lifecycle parented to the hosting node, including
   re-parenting on placement change.
5. Agent: per-guest delegated-identity subscription manager.
6. Agent: minimal Workload API server, one identity per connection.
7. Sandbox guest control protocol v4 identity channel + in-guest forwarder.
8. QEMU `vhost-vsock-pci` with per-VM CID allocation.
9. `strato-guest-identity` daemon for VMs, installed by cloud-init.
10. Fork/clone identity safety.
11. Audit events and metrics for guest identity issuance and refusal.
12. Operator documentation.
