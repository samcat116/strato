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
    /// plane would see only a timeout. The update endpoint therefore refuses
    /// agents that registered with a pre-v6 version instead of sending and
    /// hoping (see `supportsAgentUpdate(_:)`).
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
    public static let currentVersion = 16

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

    /// The lowest protocol version that understands the `agentUpdate` command
    /// (see `currentVersion` version 6 notes).
    public static let agentUpdateMinimumVersion = 6

    /// Whether an agent registered with `version` can be sent an
    /// `AgentUpdateMessage`. A pre-v6 agent cannot even decode the envelope
    /// (unknown `MessageType` case) and never replies, so the control plane
    /// must refuse the update up front rather than time out against silence.
    public static func supportsAgentUpdate(_ version: Int) -> Bool {
        version >= agentUpdateMinimumVersion
    }

    /// The lowest protocol version that acts on
    /// `DesiredStateMessage.desiredAgentUpdate` (see `currentVersion` version 7
    /// notes).
    public static let desiredAgentUpdateMinimumVersion = 7

    /// Whether an agent registered with `version` converges on a
    /// `desiredAgentUpdate` carried by the sync. An older agent decodes the
    /// sync fine but never acts on the field, so the fleet rollout must not
    /// select such an agent — its health budget would expire against silence
    /// and halt the rollout.
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

    /// Whether an agent registered with `version` can be sent sandbox
    /// snapshot/restore messages. A pre-v9 agent cannot decode the envelope
    /// (unknown `MessageType` case) and never replies, so the control plane
    /// must refuse the request up front rather than time out against silence.
    public static func supportsSandboxSnapshots(_ version: Int) -> Bool {
        version >= sandboxSnapshotMinimumVersion
    }

    /// The lowest protocol version that speaks sandbox snapshot mobility —
    /// export to object storage, artifact transfer descriptors on restore and
    /// fork, and CPU templates on sandbox specs (see `currentVersion` version
    /// 14 notes).
    public static let sandboxSnapshotMobilityMinimumVersion = 14

    /// Whether an agent registered with `version` can be sent a
    /// `SandboxSnapshotExportMessage`, an `artifacts`-carrying restore/fork,
    /// or a templated `SandboxSpec`. A pre-v14 agent either cannot decode the
    /// envelope (export) or silently ignores the field (artifacts,
    /// cpuTemplate) and mis-converges, so the control plane must refuse all
    /// three up front.
    public static func supportsSandboxSnapshotMobility(_ version: Int) -> Bool {
        version >= sandboxSnapshotMobilityMinimumVersion
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
