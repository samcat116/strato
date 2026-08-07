import Foundation

/// Versioning and the canonical JSON coders for the control-plane ↔ agent wire
/// protocol.
///
/// Both codebases build against this package, but they deploy independently
/// (agents run on hypervisor nodes and reconnect on their own schedule), so the
/// two sides can run different builds at the same time. Two things make that
/// safe:
///
/// * A single pinned coder pair. Every message is encoded and decoded through
///   `makeEncoder()`/`makeDecoder()` so both sides agree — from one definition —
///   on the `Date` representation. Previously each call site constructed a bare
///   `JSONEncoder()`/`JSONDecoder()`, which left dates on Foundation's
///   `deferredToDate` default; any future divergence in date strategy across the
///   two codebases would silently break decoding of every message.
/// * A version stamped on every `MessageEnvelope` and negotiated at
///   registration (see `AgentRegisterMessage.protocolVersion`), so a peer can
///   detect and log skew instead of failing opaquely.
///
/// ## Date encoding: a two-phase migration
///
/// The eventual goal is self-describing ISO-8601 timestamps, but flipping the
/// *encoder* is a breaking change: a binary that predates this work decodes
/// payloads with a bare `JSONDecoder` (Foundation's `deferredToDate`), which
/// expects a numeric value and cannot read an ISO-8601 string. During any
/// rollout where one side is upgraded before the other, an upgraded sender
/// emitting ISO strings would break every timestamped message an old peer reads.
///
/// So this phase (`currentVersion == 1`) only widens what we *accept*:
///
/// * `makeEncoder()` still emits the legacy numeric `deferredToDate` form, byte
///   compatible with what old peers already read.
/// * `makeDecoder()` accepts *both* the numeric form and ISO-8601 strings.
///
/// Once every deployed peer is known to run a build that reads both forms (which
/// can be confirmed via the negotiated `protocolVersion`), a later version can
/// flip `makeEncoder()` to ISO-8601 with no compatibility window.
public enum WireProtocol {
    /// The wire/schema version this build speaks. Bump it whenever the on-wire
    /// representation changes in a way peers must be aware of (date strategy,
    /// envelope layout, field semantics). Carried on every `MessageEnvelope`
    /// and exchanged during agent registration.
    ///
    /// Version 1: decoder accepts both numeric and ISO-8601 dates; encoder still
    /// emits the legacy numeric form. See the type-level note on the migration.
    ///
    /// Version 2: reconciliation state sync. The peer understands
    /// `DesiredStateMessage`/`ObservedStateReport` and, for agents, runs a
    /// reconcile loop instead of the imperative VM lifecycle messages. The
    /// control plane keys dual-mode dispatch on this: agents registering with
    /// an older version keep receiving imperative messages. The date encoder is
    /// unchanged (still the legacy numeric form).
    ///
    /// Version 3: first-class network reconciliation. `DesiredStateMessage`
    /// carries a `networks: [DesiredNetworkState]` list so agents realize
    /// logical switches, per-project routers, and SNAT uplinks as level-triggered
    /// desired state. The change is additive and backward-tolerant: the field
    /// defaults to `[]` when absent, an older (v2) agent simply ignores it (and
    /// keeps realizing switches implicitly from `vms`), so state sync still works
    /// across the skew — hence `stateSyncMinimumVersion` stays at 2.
    ///
    /// Version 4: site topology authority (issue #343). `DesiredStateMessage`
    /// carries `networksAuthoritative`; a `false` value with an empty `networks`
    /// list means "another agent authors your site's shared NB — leave topology
    /// alone". A v3 agent doesn't know the field and would read that same sync
    /// as an authoritative teardown of all its L3, so the control plane must
    /// never send the non-authoritative shape to agents that registered with an
    /// older version: sync assembly keys on the registered version and keeps
    /// pre-v4 agents on the legacy per-node scoping (own networks,
    /// authoritative) even when they are assigned to a site.
    ///
    /// Version 5: sandbox workloads (issue #411). `DesiredStateMessage` carries
    /// `sandboxes: [DesiredSandboxState]` and `ObservedStateReport` carries
    /// `sandboxes: [ObservedSandboxState]`. Additive and backward-tolerant
    /// (absent lists decode to `[]`), with the same asymmetric hazard as
    /// networks in v3: an agent must not read the decoded-empty list from a
    /// pre-v5 control plane as "tear down all sandboxes" — it gates sandbox
    /// reconciliation on `supportsSandboxSync(envelope.senderVersion)`. In the
    /// other direction, speaking v5 is necessary but NOT sufficient for
    /// sandbox placement: an agent built against v5 understands the fields but
    /// may predate the sandbox runtime (issue #421), and would silently ignore
    /// desired entries and report none back. Agents therefore advertise the
    /// capability explicitly (`AgentRegisterMessage.sandboxCapable`, set only
    /// once the runtime exists), and the scheduler keys placement on that
    /// signal — never on the registered version alone.
    ///
    /// Version 6: operator-triggered agent self-update (issue #432). Adds the
    /// `agentUpdate` action message and OS reporting at registration
    /// (`AgentRegisterMessage.operatingSystem`, used to resolve per-OS/arch
    /// release artifacts). The gate is load-bearing on the send side: an older
    /// agent has no `agent_update` case in its `MessageType` enum, so the
    /// envelope decode fails silently and no reply is ever sent — the control
    /// plane would see only a timeout. The update endpoint therefore refused
    /// agents that registered with a pre-v6 version instead of sending and
    /// hoping. (The message itself is gone as of v28; only the OS reporting
    /// remains from this version.)
    ///
    /// Version 7: declarative agent auto-update (issue #434).
    /// `DesiredStateMessage` carries an optional `desiredAgentUpdate` and
    /// `ObservedStateReport` carries an optional `agentUpdateStatus`. Both are
    /// additive and backward-tolerant (absent decodes to nil, nil means "no
    /// opinion"/"nothing to report"), and unlike the `networks` lists there is
    /// no asymmetric-hazard reading of absence — nil can never mean
    /// "downgrade" or "tear down". The gate matters on the control-plane side
    /// instead: a pre-v7 agent silently ignores the field it cannot decode a
    /// struct into, so the fleet rollout must never *assign* an update to one
    /// — it would wait out its whole health budget against silence and halt
    /// the rollout for no reason (see `supportsDesiredAgentUpdate(_:)`).
    ///
    /// Version 8: sandbox exec/attach and workload logs (issue #423). Adds the
    /// `sandboxExec*` stream messages and `sandboxLog`. Like `agentUpdate` in
    /// v6, the gate is load-bearing on the send side: a pre-v8 agent has no
    /// `sandbox_exec_start` case in its `MessageType` enum, so the envelope
    /// decode fails silently and the exec session would hang against silence —
    /// the control plane must refuse exec requests for agents that registered
    /// with an older version (see `supportsSandboxExec(_:)`). `sandboxLog` is
    /// agent→control-plane only and harmless across skew: a pre-v8 control
    /// plane never receives one because a pre-v8 agent never sends one.
    /// Version 9: sandbox snapshots / checkpoint-resume (issue #426). Adds the
    /// `sandboxSnapshotCreate`/`sandboxSnapshotDelete`/`sandboxRestore`
    /// request/response pairs. Like `agentUpdate` in v6, the gate is
    /// load-bearing on the send side: a pre-v9 agent has no
    /// `sandbox_snapshot_create` case in its `MessageType` enum, so the
    /// envelope decode fails silently and the request would burn its full
    /// timeout against silence. Belt and braces, agents that handle these
    /// messages also advertise `sandbox_snapshot_create` in their registration
    /// `capabilities` (the `volumeSnapshotDelete` pattern), and the control
    /// plane checks the capability before sending.
    ///
    /// Version 10: removes the pre-state-sync imperative VM lifecycle message
    /// cases. This is intentionally breaking for version 0/1 peers: both sides
    /// gate registration on `supportsStateSync(_:)`, so an incompatible peer is
    /// rejected before it can emit a message type this build no longer decodes.
    ///
    /// Version 11: removes `AgentRegisterResponseMessage.reconnectToken` along
    /// with token-based agent enrollment. Agents authenticate solely with a
    /// SPIRE-issued X.509 SVID over mTLS, so there is no bearer credential left
    /// to rotate. Breaking only for agents that dial with a token, and those are
    /// already refused at the socket — the control plane no longer has a token
    /// auth path to fall back to.
    ///
    /// Version 12 adds sandbox forks (issue #427) and floating IPs (issue
    /// #344). `SandboxSpec` and `DesiredSandboxState` carry an optional
    /// `restoreFrom` checkpoint reference. A pre-v12 agent would silently
    /// ignore it and cold-create the target, so fork placement is gated on
    /// `supportsSandboxFork(_:)`.
    ///
    /// `DesiredNetworkState` also gains the
    /// optional `floatingIPs` list, realized as `dnat_and_snat` rules by the
    /// topology-authority agent. Additive and tolerant on the wire — a pre-v12
    /// agent decodes the message and ignores the field — which is exactly the
    /// hazard: the API would report an address as attached while its NAT rule
    /// is never realized. The gate is load-bearing on the control-plane side:
    /// attaches are refused when the realizing agent registered pre-v12, and
    /// sync assembly omits the field for such agents (see
    /// `supportsFloatingIPs(_:)`).
    ///
    /// Version 13: image/artifact downloads authenticate with the agent's
    /// SPIFFE SVID over mTLS instead of HMAC-signed URLs (issue #493).
    /// `ImageInfo.downloadURL` and `ArtifactInfo.downloadURL` are now
    /// control-plane-relative paths (`/api/projects/.../download`) that the
    /// agent resolves against the base URL it already dials — the Envoy mTLS
    /// listener — and fetches with its SVID-backed TLS client. The `expiresAt`
    /// fields are gone: an mTLS-authenticated URL never expires, which also
    /// ends the re-signing churn at sync assembly. Breaking for pre-v13
    /// agents in effect, not in shape: they decode the sync fine but fetch the
    /// relative URL with a plain HTTP client and no credential, which the
    /// control plane refuses — the fix is upgrading the agent, so there is no
    /// send-side gate to soften it.
    ///
    /// Version 14: sandbox snapshot mobility (issue #428). Adds the
    /// `sandboxSnapshotExport` request/response pair (a new `MessageType`
    /// case, so like v6/v9 the send-side gate is load-bearing: a pre-v14
    /// agent drops the undecodable envelope and the request would burn its
    /// timeout against silence), optional `artifacts` transfer descriptors on
    /// `SandboxRestoreMessage` and `SandboxSnapshotRef` — control-plane-
    /// relative paths fetched over SVID mTLS, the v13 image-download model
    /// (a pre-v14 agent ignores them and would fail the restore with
    /// "snapshot not found", so cross-agent restore/fork placement is refused
    /// for such agents) — and `SandboxSpec.cpuTemplate` (silently ignored by
    /// a pre-v14 agent: the sandbox would boot un-templated while the API
    /// reports a template, so templated creates are gated too; see
    /// `supportsSandboxSnapshotMobility(_:)`).
    ///
    /// Version 15: QEMU guest agent (qga) integration (issue #563). Purely
    /// additive and nil-tolerant in both directions, so there is no gate — an
    /// older peer degrades to today's behavior on its own:
    /// - `ObservedVMState.guestInfo` (optional `GuestInfo`) carries the guest's
    ///   observed hostname and per-MAC configured addresses back on the
    ///   observed-state report. An older control plane ignores the key; an
    ///   older agent never sends it (a nil an old control plane and a new one
    ///   read identically), so nothing keys convergence on it.
    /// - `VolumeSnapshotMessage.attachedVMId` (optional) lets a new control
    ///   plane tell the agent which VM holds the volume so it can fs-freeze the
    ///   guest around the overlay. A nil (older control plane, or a detached
    ///   volume) simply yields the crash-consistent snapshot taken before.
    /// Neither field can mean a destructive action when absent, which is why
    /// v15 — unlike v13/v14's shape-breaking changes — needs no send-side gate.
    ///
    /// Version 16: virtio-balloon guest memory stats (issue #567).
    /// `ObservedVMState.memoryStats` (optional `VMMemoryStats`) carries the
    /// guest's balloon-reported memory usage back on the observed-state report.
    /// Additive and nil-tolerant in both directions with the exact contract of
    /// v15's `guestInfo` — an older control plane ignores the key, an older
    /// agent never sends it, absence can never mean a destructive action — so
    /// there is no gate.
    ///
    /// Version 17: CPU/memory hot-add (issue #568). Adds
    /// `VMSpec.maxMemoryBytes` (optional, defaulting to `memoryBytes`) and,
    /// on the agent side, a reconciler step that resizes a *running* VM when
    /// a new generation's spec changes `cpus`/`memoryBytes`. The spec field
    /// is additive and nil-tolerant, but the convergence behavior is not: a
    /// pre-v17 agent sees no status change, plans no work, and reports the
    /// new generation as converged — so the resize would silently succeed
    /// having changed nothing. The control plane therefore refuses an
    /// online resize for agents below this version and tells the caller to
    /// restart the VM instead (see `supportsVMResize(_:)`); resizing a
    /// stopped VM needs no gate, since the next boot uses the new spec.
    ///
    /// Version 18: Windows guest support (issue #565). `VMSpec.machine`
    /// (optional `MachineProfile`) carries `secureBoot`/`tpm`, and
    /// `AgentRegisterMessage.tpmCapable` reports whether the host has swtpm.
    /// The shape is additive and tolerant — a pre-v18 agent decodes the sync
    /// and ignores the key — which is exactly the hazard, and it is the
    /// *silent* kind: a Windows VM whose Secure Boot and vTPM were dropped
    /// boots to a setup screen that refuses to proceed, with nothing in the
    /// API saying why. So placement is gated on both signals
    /// (`supportsMachineProfile(_:)` plus the explicit `tpmCapable` flag,
    /// the `sandboxCapable` pattern from v5) rather than sent and hoped for.
    ///
    /// Version 19: operator balloon targets (issue #567 phase 2). Adds
    /// `VMSpec.balloonTargetBytes` (optional; nil means "no target, balloon
    /// deflated") and `VMMemoryStats.balloonActualBytes` on the way back. The
    /// observed field is additive and nil-tolerant with v16's contract and
    /// needs no gate. The spec field has v17's hazard rather than v15's: a
    /// pre-v19 agent decodes the sync, ignores the key, plans no work, and
    /// reports the bumped generation as converged — so setting a target on a
    /// running VM would report success having reclaimed nothing. The control
    /// plane therefore refuses to set a target for agents below this version
    /// (see `supportsBalloonTarget(_:)`). Unlike v17 there is no
    /// "restart to apply" remedy to offer, because the target only exists on
    /// a running guest in the first place.
    ///
    /// Version 20: security groups (stateful NIC-level filtering as OVN ACLs
    /// on port groups). `DesiredStateMessage` gains an optional
    /// `securityGroups` list realized by the topology-authority agent as port
    /// groups + ACLs, and `NetworkSpec` gains optional `securityGroupIds` so
    /// every agent adds its own VMs' logical switch ports to the right port
    /// groups (plus the global drop group). Both fields are additive and
    /// nil-tolerant, which is exactly the floating-IP hazard from v12: a
    /// pre-v20 agent decodes the sync, ignores the fields, and the API would
    /// report filtering that no ACL ever enforces. The gate is load-bearing
    /// on the control-plane side — attach/detach on VMs whose realizing agent
    /// registered pre-v20 is refused, and sync assembly omits both fields for
    /// such agents (see `supportsSecurityGroups(_:)`). VM *create* is
    /// deliberately NOT gated: every NIC must join at least the project
    /// default group, so gating creates would make a pre-v20 fleet unable to
    /// create VMs at all. On such a fleet the NIC's port simply joins no
    /// groups — pre-security-group behavior — which the migration posture is
    /// designed around (migrated default groups carry an allow-all-ingress
    /// rule, so enforcement arriving with the agent upgrade changes nothing
    /// until an operator tightens rules). In the other direction, nil
    /// `securityGroups` (an older control plane) is "no opinion" — never
    /// "tear down all port groups" — and a nil per-NIC list marks the port
    /// unmanaged: it joins no groups, drop group included, so legacy traffic
    /// keeps flowing during a mixed-version rollout.
    ///
    /// Version 21: per-project network isolation (issue #765). Logical network
    /// names stop being globally unique — two projects may each own a network
    /// called `default`, on the same subnet — so `NetworkSpec.networkId`
    /// becomes **required** and the agent keys its managed `DHCP_Options` rows
    /// on a `network-id` external-id instead of `(network-name, cidr)`. The
    /// name survives on the wire as a human label for logs and external-ids
    /// only; nothing may match on it. Unlike v20's additive fields this is not
    /// nil-tolerant in either direction: a pre-#342 control plane that omits
    /// `networkId` now fails the spec decode outright (far outside supported
    /// skew), and a pre-v21 agent would silently merge two same-named
    /// networks' DHCP rows. That hazard is not confined to VM placement —
    /// topology convergence programs DHCP for *every* network the authority
    /// realizes — so the gate lives at network create, not at placement (see
    /// `supportsProjectNetworkIsolation(_:)`).
    ///
    /// Version 22: full-VM checkpoint / restore (issue #564). Adds the
    /// `vmCheckpoint` / `vmRestore` / `vmSnapshotDelete` request/response
    /// trio — new `MessageType` cases, so this has v6/v9/v14's shape rather
    /// than v15's: a pre-v22 agent cannot decode the envelope at all, drops
    /// the frame before any error response can be sent, and the request would
    /// burn its full timeout against silence. The send-side gate is therefore
    /// load-bearing, and (like the sandbox trio) is enforced by the
    /// registration capability rather than the version alone — a v22 agent on
    /// a host with no QEMU backend understands the messages but can never
    /// realize them.
    /// Version 23: the graphics console (issue #566). Adds
    /// `ConsoleSpec.graphics` outbound — which makes the QEMU driver spawn the
    /// guest with a display device and a `vnc.sock` in its VM directory —
    /// and `ConsoleConnectMessage.stream`, which picks that socket over the
    /// serial one for a console session.
    ///
    /// Both fields are optional and their absence encodes to nothing, so a
    /// pre-v23 agent receives byte-identical JSON to today's and decodes it
    /// fine. That tolerance is exactly the hazard, and it is v18's *silent*
    /// kind rather than v22's undecodable-envelope kind — there are no new
    /// `MessageType` cases here, so nothing ever fails loudly:
    ///
    /// * ignoring `graphics`, the agent boots the guest headless while the API
    ///   says it has a display — a Windows install that can never be driven,
    ///   with nothing explaining why. Gated at *placement*, like v18.
    /// * ignoring `stream`, the agent answers a VNC connect with the serial
    ///   socket. noVNC then reads kernel log text where it expects `RFB
    ///   003.008` and hangs on the handshake rather than reporting an error.
    ///   Gated again when a console session is minted, since an agent can be
    ///   downgraded after its VMs were placed.
    ///
    /// Unlike v18 this needs no registration capability flag beside the
    /// version. A vTPM needed one because `swtpm` may be missing from an
    /// otherwise-capable host; here placement already restricts to
    /// QEMU-capable agents, and a QEMU built `--disable-vnc` fails the create
    /// loudly at spawn rather than degrading.
    ///
    /// `GraphicsMode` decodes strictly, following `DesiredVMStatus` — a mode
    /// this build cannot realize must not quietly become "no display" on a VM
    /// the API says has one. Size that choice knowingly: a `DesiredStateMessage`
    /// is decoded in one shot, so a future unknown mode would fail the *whole*
    /// sync for that agent and stop it converging on everything, not just the
    /// VM that carried it. The version gate is what keeps that unreachable, and
    /// any future mode must ship with its own bump for exactly this reason.
    ///
    /// Version 24: per-rule security-group ACL logging (STR-34). Adds
    /// `DesiredSecurityGroupRule.log`, which the agent maps onto the OVN ACL's
    /// `log`/`severity`/`name` columns. Additive and nil-tolerant in both
    /// directions, and — unlike v20's fields, which this rides alongside —
    /// there is deliberately **no gate**. v20 needed one because the API would
    /// have claimed filtering that no ACL enforced; a `log` flag claims only
    /// that packets get logged. A pre-v24 agent builds the identical
    /// enforcing ACL and merely omits the log line, so the failure mode is a
    /// missing diagnostic rather than open traffic, and refusing the rule
    /// mutation would cost more than the missing logs. In the other direction
    /// a nil from an older control plane reads as "off", which is what every
    /// rule written before this version meant.
    /// Version 25: tombstone-confirmed teardown (STR-98). Until now, omission
    /// from a `DesiredStateMessage` *was* the destroy instruction: anything on
    /// a host the control plane did not list was force-stopped and
    /// de-registered, so every workload's safety rested on one assembler
    /// `WHERE` clause returning a complete list. A database restored from
    /// backup, an agent re-enrolled under a new row, or a project-delete
    /// cascade racing a create all produce a *short* list — not an error — and
    /// took the host down with it.
    ///
    /// The destructive path now needs an explicit instruction. Adds
    /// `DesiredStateMessage.tombstones` outbound and
    /// `ObservedStateReport.unrecognized` / `.teardownRefusal` inbound: the
    /// agent holds what a sync omits and reports it, the control plane
    /// confirms no row exists, and only then does a tombstone authorize the
    /// teardown — which the agent honors exactly as it honors any `.absent`
    /// entry.
    ///
    /// Deliberately **no gate**, in either direction, and for once that is the
    /// safe choice rather than the risky one. Every other version's tolerance
    /// hazard was "the peer ignores the field and something silently doesn't
    /// happen"; here the thing that doesn't happen is a teardown. A pre-v25
    /// control plane sends no tombstones, so a v25 agent holds strays forever
    /// instead of destroying live workloads — the failure mode is a leaked
    /// process an operator can see and remove. In the other direction a
    /// pre-v25 *agent* keeps the old destroy-on-omission behavior no matter
    /// what the control plane does, which is exactly what
    /// `supportsWorkloadTombstones(_:)` exists to make visible: registration
    /// logs such agents at `notice` so the fleet's remaining exposure is
    /// legible during a rollout, rather than the version silently meaning
    /// nothing.
    ///
    /// Version 26: instance metadata (STR-48). `DesiredVMState` gains an
    /// optional `metadata: InstanceMetadata` — hostname, placement, NICs, SSH
    /// keys, user/vendor data, tags, and a phase-3 identity policy — which the
    /// agent serves to the guest from the link-local metadata address instead
    /// of baking it into a boot-time seed ISO. Riding the sync is the whole
    /// point: the store inherits level-triggering, generation guards, and
    /// replay safety, so an operator's edit propagates on the next sync with
    /// no new control loop and nothing in the payload that can expire.
    ///
    /// Additive and tolerant on the wire — the key simply isn't there from an
    /// older control plane, and an older agent ignores one it can't decode a
    /// struct into — but absence is *asymmetric* in the `networks` (v3) /
    /// `sandboxes` (v5) sense rather than the harmless `desiredAgentUpdate`
    /// (v7) sense, so it needs a gate on each side for a different reason:
    ///
    /// - **Agent side**, `supportsInstanceMetadata(_:)` is what keeps nil from
    ///   being read as an instruction. From a v26+ control plane nil is
    ///   authoritative ("nothing to serve", drop what you hold); from an older
    ///   one it means the sender has never heard of metadata, and treating
    ///   that as authoritative would empty every VM's metadata store the
    ///   moment a control plane is rolled back.
    /// - **Control-plane side**, the same gate lets sync assembly omit the
    ///   field for pre-v26 agents (the v20 `securityGroups` pattern) rather
    ///   than serializing a payload the receiver provably discards.
    ///
    /// What the gate deliberately does NOT do is refuse placement, unlike
    /// v18/v23. A pre-v26 agent still provisions the guest from the seed ISO
    /// exactly as it does today — the metadata service is additive to that
    /// path, not yet a replacement for it — so a VM landing on an old agent
    /// loses mutability, not its ability to boot. That changes when the seed
    /// ISO is retired, and retiring it is what will make a placement gate
    /// load-bearing.
    ///
    /// Version 27: the metadata dataplane (STR-49). `DesiredNetworkState` gains
    /// `metadataEnabled`, and `NetworkSpec` gains the same flag per NIC. The
    /// two are not redundant — they feed the two halves of a feature with two
    /// different owners. The OVN `localport` that publishes
    /// `InstanceMetadataEndpoint`'s addresses on a logical switch is authored
    /// only by the site's network controller, from `networks`; the chassis-local
    /// namespace that terminates them must exist on *every* host running a NIC
    /// on that network, and a non-controller host receives an empty `networks`
    /// list by design (it may not author topology), so its only input is its own
    /// workloads' specs. Hence the flag on both.
    ///
    /// Absence is asymmetric in the v3/v5 sense on both fields, and on
    /// `DesiredNetworkState` the asymmetry is enforced in code, not by
    /// convention: network teardown is `observed − desired`, so
    /// `NetworkReconciler.metadataProtection(for:)` explicitly protects the
    /// ports of networks whose `metadataEnabled` is nil. Without it, rolling a
    /// control plane back to v26 would delete every live metadata port on the
    /// next sync. `false` remains an opinion and is honored, which is what makes
    /// turning the feature off work.
    ///
    /// Like v26 and unlike v18/v23, the gate does not refuse placement. A
    /// pre-v27 agent simply doesn't publish the address; its guests fall back to
    /// the seed ISO exactly as today.
    ///
    /// Version 28: the imperative `agent_update` message is removed (ADR 0001
    /// stage 6). An agent's build is a durable fact about the host, not an
    /// action, so it belongs in the sync — where `desiredAgentUpdate` has
    /// carried it since v7. The operator's "update now" endpoint now assigns
    /// that field and nudges a sync instead of dispatching a command, which
    /// leaves the message with no sender.
    ///
    /// Removing a `MessageType` case is breaking in exactly one direction, and
    /// only across a skew that upgrades backwards: a *pre-v28 control plane*
    /// driving a v28 agent would send `agent_update` (from its own manual
    /// endpoint) into an envelope the agent can no longer decode, and the
    /// request would burn its 300s timeout against silence. Nothing else
    /// regresses — a v28 control plane never sends the message to any agent,
    /// old or new, and the declarative path it uses instead has been
    /// understood by every agent since v7. Upgrade the control plane first,
    /// which is the deployment order everywhere else in this document.
    ///
    /// Version 29: the control plane serves desired state over a long-poll
    /// `GET /agent/desired-state` on the Envoy SVID-mTLS listener, and the
    /// agent may fetch it there instead of waiting for a pushed
    /// `desired_state` frame (ADR 0001 stage 10). Nothing about the payload
    /// changes — the response body is the same `MessageEnvelope` wrapping the
    /// same `DesiredStateMessage` — so this version gates the *transport*, not
    /// the schema.
    ///
    /// Both directions of skew are safe, which is why this is a plain version
    /// bump rather than a break. A v29 agent against a pre-v29 control plane
    /// sees `protocolVersion < 29` in its registration response and never
    /// starts polling; the control plane keeps pushing. A pre-v29 agent
    /// against a v29 control plane never sends `pullsDesiredState`, so the
    /// control plane keeps pushing to it specifically while newer agents on
    /// the same fleet pull. The two modes coexist per agent, not per fleet.
    ///
    /// Speaking v29 is deliberately *not* sufficient to be driven by pull:
    /// `AgentRegisterMessage.pullsDesiredState` is a separate explicit signal,
    /// for the same reason `sandboxCapable` is. A v29 build understands the
    /// endpoint, but an operator can pin it back to push mode with one config
    /// key, and the control plane has its own kill switch — neither of which a
    /// version number can express.
    ///
    /// Version 30: the agent can say "I don't know what is on this host"
    /// (STR-138). Adds `ObservedStateReport.manifestStatus` inbound.
    ///
    /// Until now an agent whose durable workload manifest failed to decode
    /// reported the same thing as a freshly imaged host: no workloads. Every
    /// consumer of that answer treats it as fact — capacity accounting frees
    /// the whole machine, the reconciler plans `.create` for guests that are
    /// still running, and the full-list `vms`/`sandboxes` semantics confirm
    /// deletions that never happened. One undecodable byte on a node running
    /// 40 VMs is indistinguishable from an empty node.
    ///
    /// `manifestStatus.inventoryComplete == false` marks a report whose
    /// workload lists are *not* an inventory: the control plane must apply
    /// nothing from it — no absences, no claims — beyond the resource snapshot
    /// and the condition itself. Non-nil with `inventoryComplete == true` is
    /// the partial case: the manifest decoded, but some entries did not, and
    /// those workloads are unroutable (see `quarantinedEntries`).
    ///
    /// No gate, and no placement refusal, for the same reason as v25: the
    /// field only ever *withholds* action. A pre-v30 control plane ignores it
    /// and reads the empty lists as it always did — which is the bug this
    /// fixes, not a regression it introduces — while the agent half of the fix
    /// (zero advertised capacity, no `.create` against an unreadable manifest)
    /// works against any control plane, because it never needs permission to
    /// refuse. Upgrade the control plane first to get the operator-visible
    /// half.
    /// Version 31: volumes become desired state (ADR 0001 stage 5, STR-148).
    /// `DesiredStateMessage` gains `volumes: [DesiredVolumeState]?` and
    /// `ObservedStateReport` gains `volumes: [ObservedVolumeState]?`; the six
    /// imperative frames `volume_create`, `volume_delete`, `volume_attach`,
    /// `volume_detach`, `volume_resize` and `volume_clone` are removed.
    /// `volume_snapshot`, `volume_snapshot_delete` and `volume_info` survive —
    /// they convert in stages 8 and 7.
    ///
    /// This bump carries two of the hazard shapes in this changelog at once.
    ///
    /// The *removal* half is the v28 shape and breaks in one direction only: a
    /// pre-v31 control plane driving a v31 agent would send `volume_attach`
    /// into an envelope the agent can no longer decode and burn the request's
    /// timeout against silence. Upgrade the control plane first, as everywhere
    /// else in this document.
    ///
    /// The *addition* half is the v3/v5/v26/v27 asymmetric-absence shape, in
    /// its most expensive form: read wrong, silence deletes the only copy of a
    /// user's data. Both new fields are therefore `Optional` rather than
    /// `[]`-defaulted, so the payload describes itself and the reading is not
    /// contingent on a version lookup being right. A sync whose `volumes` is
    /// nil makes the agent skip its volume half entirely — it does not plan
    /// against an empty desired list, which would put every volume on the host
    /// into the unrecognized set. A report whose `volumes` is nil makes the
    /// control plane skip *its* volume half, rather than reading the absence as
    /// "every volume on this agent is gone" and reaping the rows.
    ///
    /// Unlike v26/v27 and like v18/v23, this gate **does** refuse placement:
    /// there is no imperative fallback left, so a volume placed on a pre-v31
    /// agent could never be created. `supportsVolumeSync` is consulted when
    /// selecting an agent to host a new volume, and volumes already sitting on
    /// a pre-v31 agent when the control plane upgrades simply freeze — their
    /// rows are never reaped, because that agent's reports say nothing about
    /// volumes — until the agent is upgraded. Deleting such a volume still
    /// works: the delete path force-clears the agent-absence finalizer for an
    /// agent that cannot confirm.
    ///
    /// Version 32: snapshots and checkpoints become desired artifacts (ADR 0001
    /// stage 8, STR-150). `DesiredStateMessage` gains
    /// `snapshots: [DesiredSnapshotState]?` and `ObservedStateReport` gains
    /// `snapshots: [ObservedSnapshotState]?`; the six imperative frames
    /// `volume_snapshot`, `volume_snapshot_delete`, `vm_checkpoint`,
    /// `vm_snapshot_delete`, `sandbox_snapshot_create` and
    /// `sandbox_snapshot_delete` are removed, and so is
    /// `sandbox_snapshot_export`. `vm_restore` and `sandbox_restore` survive —
    /// they are edges, and convert to nonces in STR-151.
    ///
    /// The bump carries the same two hazard shapes as v31, for the same
    /// reasons, and the *addition* half gets the same `Optional`-not-`[]`
    /// treatment: a nil `snapshots` is "the sender has no opinion", never
    /// "delete every checkpoint on this host". Read wrong, silence here
    /// destroys the point in time a user chose to keep, so the payload
    /// describes itself rather than depending on a `wireProtocolVersion` column
    /// being current.
    ///
    /// Where this differs from v31 is what the gate can protect. A volume is
    /// *placed* by the control plane, so v31 could simply refuse to schedule
    /// one onto an agent that could not converge it. An artifact's placement is
    /// its parent's, and the parent is already there — so `supportsSnapshotSync`
    /// gates **capture admission** instead: `POST .../snapshots` against a
    /// pre-v32 agent is refused with "upgrade the agent", which is exactly what
    /// the pre-v22/v9 capability preflights already did, one floor higher.
    /// Artifacts already sitting on such an agent freeze until it is upgraded,
    /// and deleting one still works because the delete path force-clears the
    /// agent-absence finalizer for an agent that cannot confirm.
    ///
    /// The *removal* half is the v28/v31 shape and breaks in one direction
    /// only: a pre-v32 control plane driving a v32 agent would send
    /// `vm_checkpoint` into an envelope the agent can no longer decode and burn
    /// the request's timeout against silence. Upgrade the control plane first.
    public static let currentVersion = 32

    /// The lowest protocol version that speaks reconciliation state sync
    /// (see `currentVersion` version 2 notes).
    public static let stateSyncMinimumVersion = 2

    /// Whether a peer registering with `version` should be driven with
    /// desired-state syncs rather than imperative VM lifecycle messages.
    public static func supportsStateSync(_ version: Int) -> Bool {
        version >= stateSyncMinimumVersion
    }

    /// The lowest protocol version whose `DesiredStateMessage` carries an
    /// authoritative `networks` list (see `currentVersion` version 3 notes).
    public static let networkSyncMinimumVersion = 3

    /// Whether a control plane at `version` sends a first-class network desired
    /// state. When false the `networks` field is merely absent (decoded to []),
    /// which must NOT be treated as "tear down all L3" — the agent skips network
    /// reconciliation and falls back to VM-only convergence.
    public static func supportsNetworkSync(_ version: Int) -> Bool {
        version >= networkSyncMinimumVersion
    }

    /// The lowest protocol version that understands `networksAuthoritative`
    /// (see `currentVersion` version 4 notes).
    public static let siteAuthorityMinimumVersion = 4

    /// Whether an agent registered with `version` can be sent a
    /// non-authoritative sync (`networks: []` + `networksAuthoritative: false`).
    /// An older agent ignores the flag and would misread that sync as an
    /// authoritative teardown of its whole L3 topology, so pre-v4 agents must
    /// stay on the legacy per-node scoping even when assigned to a site.
    public static func supportsSiteAuthority(_ version: Int) -> Bool {
        version >= siteAuthorityMinimumVersion
    }

    /// The lowest protocol version that speaks sandbox workloads
    /// (see `currentVersion` version 5 notes).
    public static let sandboxSyncMinimumVersion = 5

    /// Whether a peer at `version` understands sandbox desired-state sync.
    /// Agent-side: a pre-v5 control plane merely omits `sandboxes` (decoded to
    /// []), which must NOT be treated as "tear down all sandboxes" — the agent
    /// skips sandbox reconciliation entirely. Control-plane-side this is a
    /// necessary-but-insufficient placement precondition: eligibility
    /// additionally requires the agent to have advertised
    /// `AgentRegisterMessage.sandboxCapable`, because a v5 agent may
    /// understand the fields without running the sandbox runtime (see the
    /// version 5 notes on `currentVersion`).
    public static func supportsSandboxSync(_ version: Int) -> Bool {
        version >= sandboxSyncMinimumVersion
    }

    /// The lowest protocol version that restores a sandbox checkpoint into a
    /// new identity rather than treating the desired entry as a cold create.
    public static let sandboxForkMinimumVersion = 12

    public static func supportsSandboxFork(_ version: Int) -> Bool {
        version >= sandboxForkMinimumVersion
    }

    /// The lowest protocol version that acts on
    /// `DesiredStateMessage.desiredAgentUpdate` (see `currentVersion` version 7
    /// notes).
    public static let desiredAgentUpdateMinimumVersion = 7

    /// Whether an agent registered with `version` converges on a
    /// `desiredAgentUpdate` carried by the sync. An older agent decodes the
    /// sync fine but never acts on the field, so neither assigner may select
    /// such an agent — the fleet rollout's health budget would expire against
    /// silence and halt, and an operator's "update now" would report an
    /// assignment that never converges. Since v28 this is the *only* way an
    /// agent is updated, so it is also the update endpoint's floor.
    public static func supportsDesiredAgentUpdate(_ version: Int) -> Bool {
        version >= desiredAgentUpdateMinimumVersion
    }

    /// The lowest protocol version that speaks sandbox exec/attach and
    /// workload logs (see `currentVersion` version 8 notes).
    public static let sandboxExecMinimumVersion = 8

    /// Whether an agent registered with `version` can be sent
    /// `sandboxExec*` messages. A pre-v8 agent cannot decode the envelope
    /// (unknown `MessageType` case) and never replies, so the control plane
    /// must refuse the exec request up front rather than let the session hang
    /// against silence.
    public static func supportsSandboxExec(_ version: Int) -> Bool {
        version >= sandboxExecMinimumVersion
    }

    /// The lowest protocol version that speaks sandbox snapshot operations
    /// (see `currentVersion` version 9 notes).
    public static let sandboxSnapshotMinimumVersion = 9

    /// Whether an agent registered with `version` can be sent a
    /// `sandbox_restore`. A pre-v9 agent cannot decode the envelope (unknown
    /// `MessageType` case) and never replies, so the control plane must refuse
    /// the request up front rather than time out against silence. Since v32
    /// this covers restore alone: capture, delete and export are desired state
    /// and gate on `supportsSnapshotSync`.
    public static func supportsSandboxSnapshots(_ version: Int) -> Bool {
        version >= sandboxSnapshotMinimumVersion
    }

    /// The lowest protocol version that speaks sandbox snapshot mobility —
    /// export to object storage, artifact transfer descriptors on restore and
    /// fork, and CPU templates on sandbox specs (see `currentVersion` version
    /// 14 notes).
    public static let sandboxSnapshotMobilityMinimumVersion = 14

    /// Whether an agent registered with `version` can be sent an export
    /// instruction, an `artifacts`-carrying restore/fork, or a templated
    /// `SandboxSpec`. A pre-v14 agent silently ignores the field and
    /// mis-converges, so the control plane must refuse all three up front. (The
    /// export half now travels on the desired entry, where the stricter
    /// `supportsSnapshotSync` floor applies anyway; this gate survives for
    /// restore artifacts and CPU templates.)
    public static func supportsSandboxSnapshotMobility(_ version: Int) -> Bool {
        version >= sandboxSnapshotMobilityMinimumVersion
    }

    /// The lowest protocol version whose reconciler converges a running VM's
    /// vCPU/memory sizing (see `currentVersion` version 17 notes).
    public static let vmResizeMinimumVersion = 17

    /// Whether a VM on an agent registered with `version` can be resized
    /// while it runs. A pre-v17 agent reports the new generation as converged
    /// without touching the guest, so the control plane refuses the online
    /// resize rather than completing an operation that did nothing.
    public static func supportsVMResize(_ version: Int) -> Bool {
        version >= vmResizeMinimumVersion
    }

    /// The lowest protocol version whose network reconciler realizes
    /// `DesiredNetworkState.floatingIPs` (see `currentVersion` version 12
    /// notes).
    public static let floatingIPMinimumVersion = 12

    /// Whether an agent registered with `version` realizes floating IP NAT
    /// rules. A pre-v12 agent decodes the sync and silently ignores the field,
    /// so the control plane must refuse attaches whose realizing agent is too
    /// old — otherwise the API reports an attached address that no NAT rule
    /// ever backs.
    public static func supportsFloatingIPs(_ version: Int) -> Bool {
        version >= floatingIPMinimumVersion
    }

    /// The lowest protocol version that realizes `VMSpec.machine` — pflash
    /// firmware with a persistent variable store, Secure Boot, and a vTPM
    /// (see `currentVersion` version 18 notes).
    public static let machineProfileMinimumVersion = 18

    /// Whether an agent registered with `version` realizes a non-default
    /// `MachineProfile`. A pre-v18 agent decodes the sync and boots the guest
    /// without Secure Boot or a TPM, so a Windows VM placed there would fail
    /// setup with no signal in the API. Placement of such VMs is refused
    /// instead. Necessary but not sufficient for `tpm`: eligibility
    /// additionally requires the agent to have advertised
    /// `AgentRegisterMessage.tpmCapable`, since a v18 build on a host without
    /// swtpm understands the field but cannot realize it.
    public static func supportsMachineProfile(_ version: Int) -> Bool {
        version >= machineProfileMinimumVersion
    }

    /// The lowest protocol version that realizes `VMSpec.balloonTargetBytes`
    /// (see `currentVersion` version 19 notes).
    public static let balloonTargetMinimumVersion = 19

    /// Whether an agent registered with `version` inflates a VM's balloon to
    /// an operator's target. A pre-v19 agent ignores the spec field and
    /// reports the bumped generation as converged, so the control plane
    /// refuses to set a target there rather than completing an operation that
    /// reclaimed nothing.
    public static func supportsBalloonTarget(_ version: Int) -> Bool {
        version >= balloonTargetMinimumVersion
    }

    /// The lowest protocol version whose network reconciler realizes security
    /// groups — OVN port groups + ACLs from `DesiredStateMessage.securityGroups`
    /// and port membership from `NetworkSpec.securityGroupIds` (see
    /// `currentVersion` version 20 notes).
    public static let securityGroupsMinimumVersion = 20

    /// Whether an agent registered with `version` enforces security groups. A
    /// pre-v20 agent decodes the sync and silently ignores both fields, so
    /// the control plane must refuse attach/detach on VMs whose realizing
    /// agent is too old — otherwise the API reports filtering that no ACL
    /// ever enforces — and sync assembly omits the fields for such agents.
    /// VM create is deliberately ungated; see the version 20 notes on
    /// `currentVersion`.
    public static func supportsSecurityGroups(_ version: Int) -> Bool {
        version >= securityGroupsMinimumVersion
    }

    /// The lowest protocol version that identifies a logical network by id
    /// everywhere it matters — the OVN switch *and* the `DHCP_Options` rows
    /// (see `currentVersion` version 21 notes).
    public static let projectNetworkIsolationMinimumVersion = 21

    /// Whether an agent registered with `version` can safely realize two
    /// networks that share a name. A pre-v21 agent keys its managed
    /// `DHCP_Options` rows on `(network-name, cidr)`, so two same-named
    /// networks with the same subnet — exactly what per-project isolation
    /// makes legal — would share one row: DNS/lease edits on one would land on
    /// the other, and disabling DHCP on one would delete the other's row. The
    /// control plane must therefore refuse to *create* a colliding name at a
    /// site any of whose agents is pre-v21.
    public static func supportsProjectNetworkIsolation(_ version: Int) -> Bool {
        version >= projectNetworkIsolationMinimumVersion
    }

    /// The lowest protocol version that speaks the full-VM checkpoint message
    /// trio (see `currentVersion` version 22 notes).
    public static let vmCheckpointMinimumVersion = 22

    /// Whether an agent registered with `version` can decode a `vm_restore`
    /// request. Below this the envelope's `MessageType` does not decode, so the
    /// frame is dropped silently and the control plane would wait out the
    /// operation budget for a response that can never come — it refuses the
    /// request up front instead. Necessary but not sufficient: eligibility
    /// additionally requires the agent to advertise the `vm_restore`
    /// capability, since a v22 build on a QEMU-less host understands the frame
    /// but cannot realize it.
    ///
    /// Since v32 this covers restore alone: capture and delete are desired
    /// state and gate on `supportsSnapshotSync` instead.
    public static func supportsVMCheckpoint(_ version: Int) -> Bool {
        version >= vmCheckpointMinimumVersion
    }

    /// The lowest protocol version that realizes a graphics console
    /// (see `currentVersion` version 23 notes).
    public static let graphicsConsoleMinimumVersion = 23

    /// Whether an agent registered with `version` understands the graphics
    /// console — both halves of it, since they always ship together:
    /// `ConsoleSpec.graphics` (so the VM spawns with a display device and a VNC
    /// socket) and `ConsoleConnectMessage.stream` (so a console session can ask
    /// for that socket instead of the serial one).
    ///
    /// Load-bearing in two places, because both failures are silent. At
    /// placement: a pre-v23 agent decodes the spec, ignores `graphics`, and
    /// boots the guest headless while the API reports a display. At session
    /// mint: it ignores `stream` and hands back the *serial* socket, so noVNC
    /// would sit forever reading kernel log text where it expects an RFB
    /// version string.
    public static func supportsGraphicsConsole(_ version: Int) -> Bool {
        version >= graphicsConsoleMinimumVersion
    }

    /// The lowest protocol version that holds unlisted workloads instead of
    /// destroying them (see `currentVersion` version 25 notes).
    public static let workloadTombstoneMinimumVersion = 25

    /// Whether an agent registered with `version` treats omission from a sync
    /// as "hold and report" rather than "destroy".
    ///
    /// Not a send-side gate — tombstones are additive and a pre-v25 agent
    /// ignoring them changes nothing it would otherwise do. It exists to make
    /// the *remaining* exposure legible: below this version, any sync that
    /// under-lists a host still force-stops every workload it omitted, and no
    /// control-plane behavior can prevent that. Registration says so out loud
    /// so an operator upgrading a fleet knows which hosts are still armed.
    public static func supportsWorkloadTombstones(_ version: Int) -> Bool {
        version >= workloadTombstoneMinimumVersion
    }

    /// The lowest protocol version that speaks `DesiredVMState.metadata`
    /// (see `currentVersion` version 26 notes).
    public static let instanceMetadataMinimumVersion = 26

    /// Whether a peer at `version` understands instance metadata on the sync.
    ///
    /// Agent-side this decides whether an absent `metadata` field *means*
    /// anything: from a v26+ control plane nil is authoritative (serve
    /// nothing), from an older one it is silence and the agent must leave the
    /// VM's metadata alone — the `supportsNetworkSync` reading of an absent
    /// list, for the same reason. Control-plane-side it lets sync assembly
    /// omit the field for agents that would discard it.
    public static func supportsInstanceMetadata(_ version: Int) -> Bool {
        version >= instanceMetadataMinimumVersion
    }

    /// The lowest protocol version that speaks `metadataEnabled` on
    /// `DesiredNetworkState` and `NetworkSpec` (see `currentVersion` version 27
    /// notes).
    public static let metadataPortMinimumVersion = 27

    /// Whether a peer at `version` understands the metadata port.
    ///
    /// Agent-side this decides whether a nil `metadataEnabled` *means* anything:
    /// from a v27+ control plane it is authoritative silence about a network the
    /// sender knows the field for, from an older one the sender has never heard
    /// of the feature and the agent must leave existing ports alone. Since
    /// network teardown is a set difference, that reading is enforced by
    /// `NetworkReconciler.metadataProtection(for:)` rather than left to each
    /// call site. Control-plane-side it lets sync assembly omit the field for
    /// agents that would discard it.
    public static func supportsMetadataPort(_ version: Int) -> Bool {
        version >= metadataPortMinimumVersion
    }

    /// The lowest protocol version that serves desired state over the
    /// long-poll `GET /agent/desired-state` endpoint (see `currentVersion`
    /// version 29 notes).
    public static let desiredStatePullMinimumVersion = 29

    /// Whether a peer at `version` speaks the desired-state pull transport.
    ///
    /// Read in both directions, and neither reading is sufficient on its own.
    /// Agent-side it answers "does this control plane serve the endpoint?" —
    /// the agent additionally needs its own `desired_state_pull` config to be
    /// on. Control-plane-side it answers "could this agent be polling?" — the
    /// control plane additionally needs the agent's explicit
    /// `pullsDesiredState` flag before it stops pushing, because an agent that
    /// merely *understands* the endpoint may have been pinned to push mode.
    public static func supportsDesiredStatePull(_ version: Int) -> Bool {
        version >= desiredStatePullMinimumVersion
    }

    /// The lowest protocol version that carries volumes on the reconciliation
    /// loop rather than through imperative RPCs (see `currentVersion` version
    /// 31 notes).
    public static let volumeSyncMinimumVersion = 31

    /// Whether a peer at `version` speaks declarative volumes.
    ///
    /// Read in three places, for three different reasons. Agent-side it is the
    /// belt to the `volumes`-is-nil braces: a sync from a pre-v31 control plane
    /// says nothing about volumes and must not be planned against. Sync
    /// assembly reads it to omit the field — and skip the query — for an agent
    /// that would discard it. And unlike most gates in this file, *placement*
    /// reads it: with the imperative frames gone there is no fallback path, so
    /// a volume must never be scheduled onto an agent that cannot converge it.
    public static func supportsVolumeSync(_ version: Int) -> Bool {
        version >= volumeSyncMinimumVersion
    }

    /// The lowest protocol version that carries snapshot artifacts on the
    /// reconciliation loop rather than through imperative RPCs (see
    /// `currentVersion` version 32 notes).
    public static let snapshotSyncMinimumVersion = 32

    /// Whether a peer at `version` speaks declarative snapshot artifacts.
    ///
    /// Read in three places, like `supportsVolumeSync` and for the same three
    /// reasons — agent-side as the belt to the `snapshots`-is-nil braces, at
    /// sync assembly to omit the field (and skip the query) for an agent that
    /// would discard it, and as a refusal.
    ///
    /// The refusal is where snapshots differ. A volume's gate is at
    /// *placement*, because the control plane chooses a volume's host; an
    /// artifact inherits its parent's host, so there is no placement decision
    /// to gate. This one sits at **capture admission** instead: with the
    /// imperative frames gone there is no fallback, so a checkpoint requested
    /// against a pre-v32 agent is refused with `409` rather than accepted into
    /// a state nothing can converge.
    public static func supportsSnapshotSync(_ version: Int) -> Bool {
        version >= snapshotSyncMinimumVersion
    }

    /// The JSON encoder for all wire messages. Dates are pinned — explicitly and
    /// from this single definition — to Foundation's `deferredToDate` numeric
    /// form, which is byte compatible with what pre-existing peers already
    /// decode. This is deliberately *not* ISO-8601 yet: see the type-level note
    /// on the two-phase date migration.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }

    /// The JSON decoder for all wire messages. Dates decode tolerantly: the
    /// current numeric `deferredToDate` form is accepted, and so is an ISO-8601
    /// string. Accepting ISO now — before any peer emits it — is what lets a
    /// future encoder flip to ISO-8601 be rolled out without a compatibility
    /// window.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()

            if let string = try? container.decode(String.self) {
                guard let date = try? iso8601Style.parse(string) else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Expected an ISO-8601 date string, got \"\(string)\""
                    )
                }
                return date
            }

            // `deferredToDate` encoding: seconds since the reference date
            // (2001-01-01) as a JSON number.
            let seconds = try container.decode(Double.self)
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
        return decoder
    }

    /// Matches `JSONEncoder.DateEncodingStrategy.iso8601` (internet date-time,
    /// no fractional seconds). Value-typed and `Sendable`, so it can back the
    /// decoder's tolerant string branch without a shared mutable formatter.
    private static let iso8601Style = Date.ISO8601FormatStyle()
}
