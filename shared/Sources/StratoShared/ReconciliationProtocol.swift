import Foundation
import SwiftProtobuf

// MARK: - Desired VM State

/// The state the control plane wants a VM to be in. Distinct from `VMStatus`,
/// which is purely *observed*: desired state is a goal ("be running"), never a
/// report ("is starting"), so it has no transitional or diagnostic cases.
///
/// Decoding is deliberately strict (no tolerant fallback like `VMStatus`):
/// misinterpreting a desired status could stop or delete a running VM, so an
/// unknown value fails the whole sync and the agent keeps its current state.
/// Adding an instruction requires a negotiated capability before it is sent.
public typealias DesiredVMStatus = Strato_Agent_V1_DesiredVMStatus
extension Strato_Agent_V1_DesiredVMStatus: Codable {

    /// Whether an observed status already satisfies this goal, i.e. the
    /// reconciler has nothing to do. `.created` satisfies `.shutdown` because
    /// a defined-but-never-booted VM and a shut-down VM are the same resting
    /// state ("exists, not running") — they differ only in history.
    public func isSatisfied(by observed: VMStatus) -> Bool {
        switch self {
        case .running:
            return observed == .running
        case .paused:
            return observed == .paused
        case .shutdown:
            return observed == .shutdown || observed == .created
        case .absent:
            return false  // absence is confirmed by omission from the observed set, never by a status
        case .unspecified, .UNRECOGNIZED:
            return false
        }
    }

    public var protocolValue: String {
        switch self {
        case .running: return "Running"
        case .shutdown: return "Shutdown"
        case .paused: return "Paused"
        case .absent: return "Absent"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "Running": self = .running
        case "Shutdown": self = .shutdown
        case "Paused": self = .paused
        case "Absent": self = .absent
        default: return nil
        }
    }

    public static var knownCases: [Self] { [.running, .shutdown, .paused, .absent] }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown enum value")
        }
        self = value
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        guard !protocolValue.isEmpty else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Unknown enum value"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(protocolValue)
    }
}

// MARK: - Edge nonces

/// The restore the control plane wants a workload to have performed, carried on
/// its desired entry as a monotonic nonce (ADR 0001 stage 9, STR-151).
///
/// A restore is an *edge*, not a state: "the VM should be at checkpoint C" is
/// not something an agent can re-converge on, because the guest starts writing
/// the moment it resumes. The `kubectl rollout restart` answer to that shape is
/// to put **how many times it was asked** in the desired state — the edge
/// becomes a state the moment it is counted. The agent keeps a durable record of
/// the last nonce it applied per workload and acts only when this one outranks
/// it, so a replayed or re-driven sync cannot rewind a live guest a second time.
///
/// Absent means "no restore has ever been asked for", never "undo one".
public typealias DesiredRestore = Strato_Agent_V1_DesiredRestore
extension Strato_Agent_V1_DesiredRestore: Codable {

    public init(
        generation: Int64,
        snapshotId: UUID,
        artifacts: [SandboxSnapshotArtifactDescriptor]? = nil
    ) {
        self.init()
        self._jsonGeneration = generation
        self._jsonSnapshotId = snapshotId
        self._jsonArtifacts = artifacts
    }

    private enum CodingKeys: String, CodingKey { case generation; case snapshotId; case artifacts }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonGeneration = try container.decode(Int64.self, forKey: .generation)
        self._jsonSnapshotId = try container.decode(UUID.self, forKey: .snapshotId)
        self._jsonArtifacts = try container.decodeIfPresent(
            [SandboxSnapshotArtifactDescriptor].self, forKey: .artifacts)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonGeneration, forKey: .generation)
        try container.encode(_jsonSnapshotId, forKey: .snapshotId)
        try container.encodeIfPresent(_jsonArtifacts, forKey: .artifacts)
    }

}

/// One VM's authoritative desired state, as assembled by the control plane.
public typealias DesiredVMState = Strato_Agent_V1_DesiredVMState
extension Strato_Agent_V1_DesiredVMState: Codable {

    public init(
        vmId: UUID,
        hypervisorType: HypervisorType,
        spec: VMSpec,
        desiredStatus: DesiredVMStatus,
        generation: Int64,
        imageInfo: ImageInfo? = nil,
        metadata: InstanceMetadata? = nil,
        rebootGeneration: Int64? = nil,
        restore: DesiredRestore? = nil,
        guestConfig: GuestConfig? = nil,
        guestConfigFailedGeneration: Int64? = nil
    ) {
        self.init()
        self._jsonVmId = vmId
        self._jsonHypervisorType = hypervisorType
        self._jsonSpec = spec
        self._jsonDesiredStatus = desiredStatus
        self._jsonGeneration = generation
        self._jsonImageInfo = imageInfo
        self._jsonMetadata = metadata
        self._jsonRebootGeneration = rebootGeneration
        self._jsonRestore = restore
        self._jsonGuestConfig = guestConfig
        self._jsonGuestConfigFailedGeneration = guestConfigFailedGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case vmId; case hypervisorType; case spec; case desiredStatus; case generation; case imageInfo; case metadata;
        case rebootGeneration; case restore; case guestConfig; case guestConfigFailedGeneration
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonVmId = try container.decode(UUID.self, forKey: .vmId)
        self._jsonHypervisorType = try container.decode(HypervisorType.self, forKey: .hypervisorType)
        self._jsonSpec = try container.decode(VMSpec.self, forKey: .spec)
        self._jsonDesiredStatus = try container.decode(DesiredVMStatus.self, forKey: .desiredStatus)
        self._jsonGeneration = try container.decode(Int64.self, forKey: .generation)
        self._jsonImageInfo = try container.decodeIfPresent(ImageInfo.self, forKey: .imageInfo)
        self._jsonMetadata = try container.decodeIfPresent(InstanceMetadata.self, forKey: .metadata)
        self._jsonRebootGeneration = try container.decodeIfPresent(Int64.self, forKey: .rebootGeneration)
        self._jsonRestore = try container.decodeIfPresent(DesiredRestore.self, forKey: .restore)
        self._jsonGuestConfig = try container.decodeIfPresent(GuestConfig.self, forKey: .guestConfig)
        self._jsonGuestConfigFailedGeneration = try container.decodeIfPresent(
            Int64.self, forKey: .guestConfigFailedGeneration)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonVmId, forKey: .vmId)
        try container.encode(_jsonHypervisorType, forKey: .hypervisorType)
        try container.encode(_jsonSpec, forKey: .spec)
        try container.encode(_jsonDesiredStatus, forKey: .desiredStatus)
        try container.encode(_jsonGeneration, forKey: .generation)
        try container.encodeIfPresent(_jsonImageInfo, forKey: .imageInfo)
        try container.encodeIfPresent(_jsonMetadata, forKey: .metadata)
        try container.encodeIfPresent(_jsonRebootGeneration, forKey: .rebootGeneration)
        try container.encodeIfPresent(_jsonRestore, forKey: .restore)
        try container.encodeIfPresent(_jsonGuestConfig, forKey: .guestConfig)
        try container.encodeIfPresent(_jsonGuestConfigFailedGeneration, forKey: .guestConfigFailedGeneration)
    }

}

// MARK: - Desired Sandbox State

/// One sandbox's authoritative desired state, as assembled by the control
/// plane. Mirrors `DesiredVMState` semantics exactly: level-triggered,
/// generation-guarded, safe to drop or replay.
public typealias DesiredSandboxState = Strato_Agent_V1_DesiredSandboxState
extension Strato_Agent_V1_DesiredSandboxState: Codable {

    public init(
        sandboxId: UUID,
        spec: SandboxSpec,
        desiredStatus: DesiredSandboxStatus,
        generation: Int64,
        registryCredential: RegistryCredential? = nil,
        restore: DesiredRestore? = nil,
        suspensionStorageBudgetBytes: Int64? = nil,
        suspensionAfterSnapshotId: UUID? = nil,
        suspensionCheckpointId: UUID? = nil,
        automaticSuspensionFence: SandboxAutomaticSuspensionFence? = nil,
        idleControlPlaneRevision: Int64? = nil,
        idlePendingCommandCount: Int? = nil
    ) {
        self.init()
        self._jsonSandboxId = sandboxId
        self._jsonSpec = spec
        self._jsonDesiredStatus = desiredStatus
        self._jsonGeneration = generation
        self._jsonRegistryCredential = registryCredential
        self._jsonRestore = restore
        self._jsonSuspensionStorageBudgetBytes = suspensionStorageBudgetBytes
        self._jsonSuspensionAfterSnapshotId = suspensionAfterSnapshotId
        self._jsonSuspensionCheckpointId = suspensionCheckpointId
        self._jsonAutomaticSuspensionFence = automaticSuspensionFence
        self._jsonIdleControlPlaneRevision = idleControlPlaneRevision
        self._jsonIdlePendingCommandCount = idlePendingCommandCount
    }

    private enum CodingKeys: String, CodingKey {
        case sandboxId; case spec; case desiredStatus; case generation; case registryCredential; case restore;
        case suspensionStorageBudgetBytes; case suspensionAfterSnapshotId; case suspensionCheckpointId;
        case automaticSuspensionFence; case idleControlPlaneRevision; case idlePendingCommandCount
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonSandboxId = try container.decode(UUID.self, forKey: .sandboxId)
        self._jsonSpec = try container.decode(SandboxSpec.self, forKey: .spec)
        self._jsonDesiredStatus = try container.decode(DesiredSandboxStatus.self, forKey: .desiredStatus)
        self._jsonGeneration = try container.decode(Int64.self, forKey: .generation)
        self._jsonRegistryCredential = try container.decodeIfPresent(
            RegistryCredential.self, forKey: .registryCredential)
        self._jsonRestore = try container.decodeIfPresent(DesiredRestore.self, forKey: .restore)
        self._jsonSuspensionStorageBudgetBytes = try container.decodeIfPresent(
            Int64.self, forKey: .suspensionStorageBudgetBytes)
        self._jsonSuspensionAfterSnapshotId = try container.decodeIfPresent(
            UUID.self, forKey: .suspensionAfterSnapshotId)
        self._jsonSuspensionCheckpointId = try container.decodeIfPresent(UUID.self, forKey: .suspensionCheckpointId)
        self._jsonAutomaticSuspensionFence = try container.decodeIfPresent(
            SandboxAutomaticSuspensionFence.self, forKey: .automaticSuspensionFence)
        self._jsonIdleControlPlaneRevision = try container.decodeIfPresent(
            Int64.self, forKey: .idleControlPlaneRevision)
        self._jsonIdlePendingCommandCount = try container.decodeIfPresent(Int.self, forKey: .idlePendingCommandCount)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonSandboxId, forKey: .sandboxId)
        try container.encode(_jsonSpec, forKey: .spec)
        try container.encode(_jsonDesiredStatus, forKey: .desiredStatus)
        try container.encode(_jsonGeneration, forKey: .generation)
        try container.encodeIfPresent(_jsonRegistryCredential, forKey: .registryCredential)
        try container.encodeIfPresent(_jsonRestore, forKey: .restore)
        try container.encodeIfPresent(_jsonSuspensionStorageBudgetBytes, forKey: .suspensionStorageBudgetBytes)
        try container.encodeIfPresent(_jsonSuspensionAfterSnapshotId, forKey: .suspensionAfterSnapshotId)
        try container.encodeIfPresent(_jsonSuspensionCheckpointId, forKey: .suspensionCheckpointId)
        try container.encodeIfPresent(_jsonAutomaticSuspensionFence, forKey: .automaticSuspensionFence)
        try container.encodeIfPresent(_jsonIdleControlPlaneRevision, forKey: .idleControlPlaneRevision)
        try container.encodeIfPresent(_jsonIdlePendingCommandCount, forKey: .idlePendingCommandCount)
    }

}

// MARK: - Desired Volume State

/// The state the control plane wants a volume's *data* to be in.
///
/// Two cases, deliberately: a volume has no run state, so attachment is a
/// *field* of the entry rather than a status. Modelling attach as a status
/// would make "present, but the attach failed" unrepresentable, and it would
/// collide with size, which moves independently of where the volume is
/// plugged in.
///
/// Decoded strictly, like `DesiredVMStatus` and for a sharper version of the
/// same reason: misreading a desired volume status destroys the only copy of
/// user data. An unknown value fails the whole sync and the agent keeps what
/// it has.
public typealias DesiredVolumeStatus = Strato_Agent_V1_DesiredVolumeStatus
extension Strato_Agent_V1_DesiredVolumeStatus: Codable {

    public var protocolValue: String {
        switch self {
        case .present: return "Present"
        case .absent: return "Absent"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "Present": self = .present
        case "Absent": self = .absent
        default: return nil
        }
    }

    public static var knownCases: [Self] { [.present, .absent] }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown enum value")
        }
        self = value
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        guard !protocolValue.isEmpty else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Unknown enum value"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(protocolValue)
    }
}

/// How a volume that does not yet exist on this host gets its initial bytes: a
/// create *strategy*, not an operation — the `SandboxSpec.restoreFrom`
/// pattern (issue #427) applied to what used to be `volume_clone`.
///
/// Consulted only when the volume is absent from the host. A volume that
/// already exists ignores this field forever, which is what makes a replayed
/// or re-driven sync unable to re-clone over live data.
///
/// A `String` discriminator rather than a Swift enum with associated values:
/// an unrecognized `kind` must fail *this volume* — surfacing as its
/// `lastError` — never the whole `DesiredStateMessage`.
public typealias DesiredVolumeSource = Strato_Agent_V1_DesiredVolumeSource
extension Strato_Agent_V1_DesiredVolumeSource: Codable {
    /// Allocate an empty disk of `DesiredVolumeState.sizeBytes`.
    public static let blank = "blank"
    /// Materialize from an image artifact; `imageInfo` carries the locator.
    public static let image = "image"
    /// Copy another volume on this same agent; `sourceVolumeId` names it.
    public static let clone = "clone"

    public init(
        kind: String,
        imageInfo: ImageInfo? = nil,
        artifactKind: ArtifactKind? = nil,
        sourceVolumeId: UUID? = nil,
        sourceVMId: UUID? = nil,
        sourceFormat: String? = nil
    ) {
        self.init()
        self._jsonKind = kind
        self._jsonImageInfo = imageInfo
        self._jsonArtifactKind = artifactKind
        self._jsonSourceVolumeId = sourceVolumeId
        self._jsonSourceVMId = sourceVMId
        self._jsonSourceFormat = sourceFormat
    }

    public static func image(_ info: ImageInfo, artifactKind: ArtifactKind) -> DesiredVolumeSource {
        DesiredVolumeSource(kind: Self.image, imageInfo: info, artifactKind: artifactKind)
    }

    public static func clone(
        from volumeId: UUID, sourceVMId: UUID? = nil, format: String? = nil
    ) -> DesiredVolumeSource {
        DesiredVolumeSource(
            kind: Self.clone, sourceVolumeId: volumeId, sourceVMId: sourceVMId,
            sourceFormat: format)
    }

    private enum CodingKeys: String, CodingKey {
        case kind; case imageInfo; case artifactKind; case sourceVolumeId; case sourceVMId; case sourceFormat
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonKind = try container.decode(String.self, forKey: .kind)
        self._jsonImageInfo = try container.decodeIfPresent(ImageInfo.self, forKey: .imageInfo)
        self._jsonArtifactKind = try container.decodeIfPresent(ArtifactKind.self, forKey: .artifactKind)
        self._jsonSourceVolumeId = try container.decodeIfPresent(UUID.self, forKey: .sourceVolumeId)
        self._jsonSourceVMId = try container.decodeIfPresent(UUID.self, forKey: .sourceVMId)
        self._jsonSourceFormat = try container.decodeIfPresent(String.self, forKey: .sourceFormat)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonKind, forKey: .kind)
        try container.encodeIfPresent(_jsonImageInfo, forKey: .imageInfo)
        try container.encodeIfPresent(_jsonArtifactKind, forKey: .artifactKind)
        try container.encodeIfPresent(_jsonSourceVolumeId, forKey: .sourceVolumeId)
        try container.encodeIfPresent(_jsonSourceVMId, forKey: .sourceVMId)
        try container.encodeIfPresent(_jsonSourceFormat, forKey: .sourceFormat)
    }

}

/// Absolute per-volume I/O ceilings (STR-19).
///
/// Total-only, deliberately. QEMU and libvirt can both express read/write
/// splits, burst allowances and bucket sizes; none of them has a caller here
/// yet, and one knob per dimension is the version that can be explained in a
/// UI. Optional members can be added later without a version bump.
///
/// **The all-nil value and `nil` are two spellings of one fact, and the two
/// sides of the wire resolve that ambiguity in opposite directions.** Get this
/// backwards and the bug is invisible until a mixed-version fleet:
///
/// - On a **desired** entry, always normalize: an all-nil value must travel as
///   an absent field, or an agent comparing present-but-empty against nil
///   re-plans a throttle that is already applied, forever. `normalized(_:_:)`
///   is the single door every desired producer goes through.
/// - On an **observed** entry, never normalize. Nil there means *"this agent
///   does not report applied limits"*; a present-but-empty value means
///   *"applied, and the answer is uncapped"*. Collapse the two and an agent
///   that has never heard of ceilings has its silence read as a deliberate
///   clear — which, with no capability gate on this feature, is the one
///   misreading that matters.
public typealias VolumeIOLimits = Strato_Agent_V1_VolumeIOLimits
extension Strato_Agent_V1_VolumeIOLimits: Codable {

    /// Whether this carries no cap at all. Equal *in effect* to nil, but not
    /// `==` to it, which is exactly why `normalized(_:_:)` exists.
    public var isEmpty: Bool { _jsonIopsTotal == nil && _jsonBpsTotal == nil }

    public init(iopsTotal: Int64? = nil, bpsTotal: Int64? = nil) {
        self.init()
        self._jsonIopsTotal = iopsTotal
        self._jsonBpsTotal = bpsTotal
    }

    /// Nil for an all-nil pair, so "uncapped" has exactly one spelling on the
    /// desired side. Every desired producer builds through this rather than
    /// calling the initializer directly.
    public static func normalized(iopsTotal: Int64?, bpsTotal: Int64?) -> VolumeIOLimits? {
        guard iopsTotal != nil || bpsTotal != nil else { return nil }
        return VolumeIOLimits(iopsTotal: iopsTotal, bpsTotal: bpsTotal)
    }

    private enum CodingKeys: String, CodingKey { case iopsTotal; case bpsTotal }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonIopsTotal = try container.decodeIfPresent(Int64.self, forKey: .iopsTotal)
        self._jsonBpsTotal = try container.decodeIfPresent(Int64.self, forKey: .bpsTotal)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(_jsonIopsTotal, forKey: .iopsTotal)
        try container.encodeIfPresent(_jsonBpsTotal, forKey: .bpsTotal)
    }

}

/// The measured aggregate I/O rate for one attached volume (STR-270).
///
/// This is deliberately a rate rather than raw libvirt counters. A QEMU
/// process resets those counters on every restart, while operators need a
/// directly comparable value beside the configured and applied ceilings.
/// Nil on `ObservedVolumeState` means no two live samples were available yet
/// (including a stopped or newly adopted domain), never zero activity.
public typealias VolumeIOObservedRate = Strato_Agent_V1_VolumeIOObservedRate
extension Strato_Agent_V1_VolumeIOObservedRate: Codable {

    public init(iops: Double, bytesPerSecond: Double) {
        self.init()
        self._jsonIops = iops
        self._jsonBytesPerSecond = bytesPerSecond
    }

    private enum CodingKeys: String, CodingKey { case iops; case bytesPerSecond }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonIops = try container.decode(Double.self, forKey: .iops)
        self._jsonBytesPerSecond = try container.decode(Double.self, forKey: .bytesPerSecond)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonIops, forKey: .iops)
        try container.encode(_jsonBytesPerSecond, forKey: .bytesPerSecond)
    }

}

/// Where a volume should be plugged in. Nil on the desired entry means
/// "detached"; a value means the agent should have this volume presented to
/// `vmId` as `deviceName`.
public typealias DesiredVolumeAttachment = Strato_Agent_V1_DesiredVolumeAttachment
extension Strato_Agent_V1_DesiredVolumeAttachment: Codable {

    public init(vmId: UUID, deviceName: VolumeDeviceName, readonly: Bool = false, bootOrder: Int? = nil) {
        self.init()
        self._jsonVmId = vmId
        self._jsonDeviceName = deviceName
        self._jsonReadonly = readonly
        self._jsonBootOrder = bootOrder
    }

    private enum CodingKeys: String, CodingKey { case vmId; case deviceName; case readonly; case bootOrder }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonVmId = try container.decode(UUID.self, forKey: .vmId)
        self._jsonDeviceName = try container.decode(VolumeDeviceName.self, forKey: .deviceName)
        self._jsonReadonly = try container.decode(Bool.self, forKey: .readonly)
        self._jsonBootOrder = try container.decodeIfPresent(Int.self, forKey: .bootOrder)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonVmId, forKey: .vmId)
        try container.encode(_jsonDeviceName, forKey: .deviceName)
        try container.encode(_jsonReadonly, forKey: .readonly)
        try container.encodeIfPresent(_jsonBootOrder, forKey: .bootOrder)
    }

}

/// One volume's authoritative desired state (ADR 0001 stage 5, STR-148).
/// Mirrors `DesiredVMState` semantics exactly: level-triggered,
/// generation-guarded, safe to drop or replay.
///
/// There is no `poolId`: an agent consumes the typed `storage` configuration,
/// not the control-plane pool row that produced it. There is no `storagePath`,
/// because the selected backend owns realization; its attachment travels the
/// other way on the observed report.
public typealias DesiredVolumeState = Strato_Agent_V1_DesiredVolumeState
extension Strato_Agent_V1_DesiredVolumeState: Codable {

    public init(
        volumeId: UUID,
        desiredStatus: DesiredVolumeStatus,
        generation: Int64,
        sizeBytes: Int64,
        format: String,
        storage: DesiredVolumeStorage = .local,
        source: DesiredVolumeSource? = nil,
        attachment: DesiredVolumeAttachment? = nil,
        ioLimits: VolumeIOLimits? = nil,
        blockMode: VolumeBlockMode = .conservative
    ) {
        self.init()
        self._jsonVolumeId = volumeId
        self._jsonDesiredStatus = desiredStatus
        self._jsonGeneration = generation
        self._jsonSizeBytes = sizeBytes
        self._jsonFormat = format
        self._jsonStorage = storage
        self._jsonSource = source
        self._jsonAttachment = attachment
        self._jsonIoLimits = ioLimits
        self._jsonBlockMode = blockMode
    }

    private enum CodingKeys: String, CodingKey {
        case volumeId, desiredStatus, generation, sizeBytes, format, storage
        case source, attachment, ioLimits, blockMode
    }

    /// Agent manifests written before wire v53 contain no storage field. They
    /// can only describe filesystem-backed volumes, so the one safe meaning is
    /// `.local`; every new wire producer emits the field explicitly.
    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            volumeId: try container.decode(UUID.self, forKey: .volumeId),
            desiredStatus: try container.decode(DesiredVolumeStatus.self, forKey: .desiredStatus),
            generation: try container.decode(Int64.self, forKey: .generation),
            sizeBytes: try container.decode(Int64.self, forKey: .sizeBytes),
            format: try container.decode(String.self, forKey: .format),
            storage: try container.decodeIfPresent(DesiredVolumeStorage.self, forKey: .storage)
                ?? .local,
            source: try container.decodeIfPresent(DesiredVolumeSource.self, forKey: .source),
            attachment: try container.decodeIfPresent(
                DesiredVolumeAttachment.self, forKey: .attachment),
            ioLimits: try container.decodeIfPresent(VolumeIOLimits.self, forKey: .ioLimits),
            blockMode: try container.decodeIfPresent(VolumeBlockMode.self, forKey: .blockMode)
                ?? .conservative)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonVolumeId, forKey: .volumeId)
        try container.encode(_jsonDesiredStatus, forKey: .desiredStatus)
        try container.encode(_jsonGeneration, forKey: .generation)
        try container.encode(_jsonSizeBytes, forKey: .sizeBytes)
        try container.encode(_jsonFormat, forKey: .format)
        try container.encode(_jsonStorage, forKey: .storage)
        try container.encodeIfPresent(_jsonSource, forKey: .source)
        try container.encodeIfPresent(_jsonAttachment, forKey: .attachment)
        try container.encodeIfPresent(_jsonIoLimits, forKey: .ioLimits)
        try container.encode(_jsonBlockMode, forKey: .blockMode)
    }

}

// MARK: - Workload tombstones

/// The control plane's explicit instruction to remove a workload an agent
/// holds but no database row describes (STR-98).
///
/// Absence from a sync is deliberately *not* this. The agent holds anything it
/// has that a sync omits and reports it back as an `UnrecognizedWorkload`; only
/// after the control plane confirms no row exists does a tombstone authorize
/// the teardown. That collapses the destructive path into the one that already
/// exists — a `.absent` desired entry — and makes every teardown traceable to a
/// control-plane decision rather than to a silence.
///
/// `generation` outranks whatever the agent last applied for the workload, so
/// the reconciler's staleness guard admits it exactly like any other desired
/// entry.
public typealias DesiredWorkloadTombstone = Strato_Agent_V1_DesiredWorkloadTombstone
extension Strato_Agent_V1_DesiredWorkloadTombstone: Codable {

    public init(kind: WorkloadKind, workloadId: UUID, generation: Int64) {
        self.init()
        self._jsonKind = kind
        self._jsonWorkloadId = workloadId
        self._jsonGeneration = generation
    }

    private enum CodingKeys: String, CodingKey { case kind; case workloadId; case generation }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonKind = try container.decode(WorkloadKind.self, forKey: .kind)
        self._jsonWorkloadId = try container.decode(UUID.self, forKey: .workloadId)
        self._jsonGeneration = try container.decode(Int64.self, forKey: .generation)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonKind, forKey: .kind)
        try container.encode(_jsonWorkloadId, forKey: .workloadId)
        try container.encode(_jsonGeneration, forKey: .generation)
    }

}

// MARK: - Desired Agent Update

/// The agent build the control plane wants this agent to be running, carried
/// on the desired-state sync (issue #434). Since v28 this is the *only* way an
/// agent is updated: the imperative `agent_update` message is gone and the
/// operator's "update now" assigns this field too (ADR 0001 stage 6). Artifact
/// URL and checksum are resolved fresh at sync assembly, so a long-desired
/// update never carries a stale link.
///
/// Level-triggered and idempotent: an agent already running `targetVersion`
/// diffs this to nothing, and absence of the field means "no opinion" — never
/// "downgrade". The agent converges through download/verify/swap/restart, but
/// only when its local preconditions hold (not containerized, no in-flight
/// reconcile work); otherwise it reports why via
/// `ObservedStateReport.agentUpdateStatus` and retries on later syncs.
public typealias DesiredAgentUpdate = Strato_Agent_V1_DesiredAgentUpdate
extension Strato_Agent_V1_DesiredAgentUpdate: Codable {

    public init(
        targetVersion: String,
        artifactURL: String,
        sha256: String,
        artifactKind: AgentUpdateArtifactKind,
        tarballMember: String? = nil
    ) {
        self.init()
        self._jsonTargetVersion = targetVersion
        self._jsonArtifactURL = artifactURL
        self._jsonSha256 = sha256
        self._jsonArtifactKind = artifactKind
        self._jsonTarballMember = tarballMember
    }

    /// `artifactURL` with query and userinfo stripped, safe for logs.
    public var redactedArtifactURL: String {
        Self.redactURL(_jsonArtifactURL)
    }

    /// Artifact URLs may carry credentials — presigned query tokens or
    /// userinfo are often the only way to authenticate a private mirror
    /// download. Log this form, never the raw value, on both sides of the
    /// wire.
    public static func redactURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return "<unparseable-url>" }
        let hadQuery = components.query != nil
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        guard let base = components.string else { return "<unparseable-url>" }
        return hadQuery ? base + "?[redacted]" : base
    }

    private enum CodingKeys: String, CodingKey {
        case targetVersion; case artifactURL; case sha256; case artifactKind; case tarballMember
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonTargetVersion = try container.decode(String.self, forKey: .targetVersion)
        self._jsonArtifactURL = try container.decode(String.self, forKey: .artifactURL)
        self._jsonSha256 = try container.decode(String.self, forKey: .sha256)
        self._jsonArtifactKind = try container.decode(AgentUpdateArtifactKind.self, forKey: .artifactKind)
        self._jsonTarballMember = try container.decodeIfPresent(String.self, forKey: .tarballMember)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonTargetVersion, forKey: .targetVersion)
        try container.encode(_jsonArtifactURL, forKey: .artifactURL)
        try container.encode(_jsonSha256, forKey: .sha256)
        try container.encode(_jsonArtifactKind, forKey: .artifactKind)
        try container.encodeIfPresent(_jsonTarballMember, forKey: .tarballMember)
    }

}

/// A permanent instruction to remove one retired Ceph runtime credential from
/// an agent. It is append-only and intentionally has no generation or expiry:
/// current, re-enrolled, and future clients in the cluster's site all receive
/// the same tombstone, making cleanup idempotent across outages and reinstalls.
public typealias DesiredCephCredentialRevocation = Strato_Agent_V1_DesiredCephCredentialRevocation
extension Strato_Agent_V1_DesiredCephCredentialRevocation: Codable {

    public init(clusterId: UUID, credentialId: UUID) {
        self.init()
        self._jsonClusterId = clusterId
        self._jsonCredentialId = credentialId
    }

    private enum CodingKeys: String, CodingKey { case clusterId; case credentialId }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonClusterId = try container.decode(UUID.self, forKey: .clusterId)
        self._jsonCredentialId = try container.decode(UUID.self, forKey: .credentialId)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonClusterId, forKey: .clusterId)
        try container.encode(_jsonCredentialId, forKey: .credentialId)
    }

}

/// Control plane → agent: the full authoritative set of VMs that should exist
/// on the receiving agent.
///
/// Full-list semantics make the message level-triggered and idempotent:
/// identical syncs diff to nothing, and the message is safe to drop, replay, or
/// reorder (per-VM `generation` guards handle reordering). Fetched on agent
/// registration, nudged on any desired-state change, and fetched
/// unconditionally on an agent-owned interval as the correctness backstop.
///
/// Omission is **not** teardown (STR-98). A workload the agent holds that this
/// message does not list is held, untouched, and reported back as an
/// `UnrecognizedWorkload`; it is removed only once the control plane answers
/// with a `DesiredWorkloadTombstone` (or an ordinary `.absent` entry). Before
/// that, the whole safety of a host's workloads rested on the assembler's
/// `WHERE` clause returning a complete list.
public typealias DesiredStateMessage = Strato_Agent_V1_DesiredStateMessage
extension Strato_Agent_V1_DesiredStateMessage: WebSocketMessage {
    public var type: MessageType { .desiredState }

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        syncId: String = UUID().uuidString,
        vms: [DesiredVMState],
        sandboxes: [DesiredSandboxState] = [],
        networks: [DesiredNetworkState] = [],
        networksAuthoritative: Bool = true,
        desiredAgentUpdate: DesiredAgentUpdate? = nil,
        securityGroups: [DesiredSecurityGroup]? = nil,
        tombstones: [DesiredWorkloadTombstone] = [],
        volumes: [DesiredVolumeState] = [],
        snapshots: [DesiredSnapshotState] = [],
        cephCredentialRevocations: [DesiredCephCredentialRevocation] = [],
        dnsZones: [DesiredDNSZone]? = nil
    ) {
        self.init()
        self._jsonRequestId = requestId
        self._jsonTimestamp = timestamp
        self._jsonSyncId = syncId
        self._jsonVms = vms
        self._jsonSandboxes = sandboxes
        self._jsonNetworks = networks
        self._jsonNetworksAuthoritative = networksAuthoritative
        self._jsonDesiredAgentUpdate = desiredAgentUpdate
        self._jsonSecurityGroups = securityGroups
        self._jsonTombstones = tombstones
        self._jsonVolumes = volumes
        self._jsonSnapshots = snapshots
        self._jsonCephCredentialRevocations = cephCredentialRevocations
        self._jsonDnsZones = dnsZones
    }

    private enum CodingKeys: String, CodingKey {
        case requestId; case timestamp; case syncId; case vms; case sandboxes; case networks;
        case networksAuthoritative; case desiredAgentUpdate; case securityGroups; case tombstones; case volumes;
        case snapshots; case cephCredentialRevocations; case dnsZones
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonRequestId = try container.decode(String.self, forKey: .requestId)
        self._jsonTimestamp = try container.decode(Date.self, forKey: .timestamp)
        self._jsonSyncId = try container.decode(String.self, forKey: .syncId)
        self._jsonVms = try container.decode([DesiredVMState].self, forKey: .vms)
        self._jsonSandboxes = try container.decode([DesiredSandboxState].self, forKey: .sandboxes)
        self._jsonNetworks = try container.decode([DesiredNetworkState].self, forKey: .networks)
        self._jsonNetworksAuthoritative = try container.decode(Bool.self, forKey: .networksAuthoritative)
        self._jsonDesiredAgentUpdate = try container.decodeIfPresent(
            DesiredAgentUpdate.self, forKey: .desiredAgentUpdate)
        self._jsonSecurityGroups = try container.decodeIfPresent([DesiredSecurityGroup].self, forKey: .securityGroups)
        self._jsonTombstones = try container.decode([DesiredWorkloadTombstone].self, forKey: .tombstones)
        self._jsonVolumes = try container.decode([DesiredVolumeState].self, forKey: .volumes)
        self._jsonSnapshots = try container.decode([DesiredSnapshotState].self, forKey: .snapshots)
        self._jsonCephCredentialRevocations = try container.decode(
            [DesiredCephCredentialRevocation].self, forKey: .cephCredentialRevocations)
        self._jsonDnsZones = try container.decodeIfPresent([DesiredDNSZone].self, forKey: .dnsZones)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonRequestId, forKey: .requestId)
        try container.encode(_jsonTimestamp, forKey: .timestamp)
        try container.encode(_jsonSyncId, forKey: .syncId)
        try container.encode(_jsonVms, forKey: .vms)
        try container.encode(_jsonSandboxes, forKey: .sandboxes)
        try container.encode(_jsonNetworks, forKey: .networks)
        try container.encode(_jsonNetworksAuthoritative, forKey: .networksAuthoritative)
        try container.encodeIfPresent(_jsonDesiredAgentUpdate, forKey: .desiredAgentUpdate)
        try container.encodeIfPresent(_jsonSecurityGroups, forKey: .securityGroups)
        try container.encode(_jsonTombstones, forKey: .tombstones)
        try container.encode(_jsonVolumes, forKey: .volumes)
        try container.encode(_jsonSnapshots, forKey: .snapshots)
        try container.encode(_jsonCephCredentialRevocations, forKey: .cephCredentialRevocations)
        try container.encodeIfPresent(_jsonDnsZones, forKey: .dnsZones)
    }

}

// MARK: - Desired Security Groups

/// One rule of a security group, realized by the topology-authority agent as
/// a single OVN ACL on the group's port group (issue: security groups).
///
/// The peer is at most one of `remoteCIDR` / `remoteGroupId`; both nil means
/// "any". A group peer is carried as the group's id — the agent derives the
/// port-group name (and thus the OVN-generated `$<pg>_ip4`/`_ip6` address-set
/// reference) itself via `OVNNaming`, so naming stays a single-owner concern
/// exactly like floating-IP port names.
public typealias DesiredSecurityGroupRule = Strato_Agent_V1_DesiredSecurityGroupRule
extension Strato_Agent_V1_DesiredSecurityGroupRule: Codable {

    public init(
        id: UUID,
        direction: String,
        ethertype: String,
        protocolName: String? = nil,
        portRangeMin: Int? = nil,
        portRangeMax: Int? = nil,
        remoteCIDR: String? = nil,
        remoteGroupId: UUID? = nil,
        log: Bool = false
    ) {
        self.init()
        self._jsonId = id
        self._jsonDirection = direction
        self._jsonEthertype = ethertype
        self._jsonProtocolName = protocolName
        self._jsonPortRangeMin = portRangeMin
        self._jsonPortRangeMax = portRangeMax
        self._jsonRemoteCIDR = remoteCIDR
        self._jsonRemoteGroupId = remoteGroupId
        self._jsonLog = log
    }

    private enum CodingKeys: String, CodingKey {
        case id; case direction; case ethertype; case protocolName; case portRangeMin; case portRangeMax;
        case remoteCIDR; case remoteGroupId; case log
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonId = try container.decode(UUID.self, forKey: .id)
        self._jsonDirection = try container.decode(String.self, forKey: .direction)
        self._jsonEthertype = try container.decode(String.self, forKey: .ethertype)
        self._jsonProtocolName = try container.decodeIfPresent(String.self, forKey: .protocolName)
        self._jsonPortRangeMin = try container.decodeIfPresent(Int.self, forKey: .portRangeMin)
        self._jsonPortRangeMax = try container.decodeIfPresent(Int.self, forKey: .portRangeMax)
        self._jsonRemoteCIDR = try container.decodeIfPresent(String.self, forKey: .remoteCIDR)
        self._jsonRemoteGroupId = try container.decodeIfPresent(UUID.self, forKey: .remoteGroupId)
        self._jsonLog = try container.decode(Bool.self, forKey: .log)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonId, forKey: .id)
        try container.encode(_jsonDirection, forKey: .direction)
        try container.encode(_jsonEthertype, forKey: .ethertype)
        try container.encodeIfPresent(_jsonProtocolName, forKey: .protocolName)
        try container.encodeIfPresent(_jsonPortRangeMin, forKey: .portRangeMin)
        try container.encodeIfPresent(_jsonPortRangeMax, forKey: .portRangeMax)
        try container.encodeIfPresent(_jsonRemoteCIDR, forKey: .remoteCIDR)
        try container.encodeIfPresent(_jsonRemoteGroupId, forKey: .remoteGroupId)
        try container.encode(_jsonLog, forKey: .log)
    }

}

/// The state the control plane wants one security group to be in: an OVN port
/// group carrying one ACL per rule. `generation` is bumped on every rule
/// mutation; the agent replaces the port group's ACL set only when the stored
/// generation differs, so replayed or reordered syncs can never resurrect old
/// rules (the `LogicalNetwork.generation` pattern).
public typealias DesiredSecurityGroup = Strato_Agent_V1_DesiredSecurityGroup
extension Strato_Agent_V1_DesiredSecurityGroup: Codable {

    public init(id: UUID, generation: Int64, rules: [DesiredSecurityGroupRule]) {
        self.init()
        self._jsonId = id
        self._jsonGeneration = generation
        self._jsonRules = rules
    }

    private enum CodingKeys: String, CodingKey { case id; case generation; case rules }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonId = try container.decode(UUID.self, forKey: .id)
        self._jsonGeneration = try container.decode(Int64.self, forKey: .generation)
        self._jsonRules = try container.decode([DesiredSecurityGroupRule].self, forKey: .rules)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonId, forKey: .id)
        try container.encode(_jsonGeneration, forKey: .generation)
        try container.encode(_jsonRules, forKey: .rules)
    }

}

// MARK: - Desired Network ACLs

/// One ordered, stateless rule in a network-level ACL (STR-33).
///
/// Rules are evaluated independently for ingress and egress in ascending
/// `ruleNumber` order. The topology-authority agent owns the mapping from that
/// stable API ordering to OVN tiers and priorities; the wire deliberately does
/// not expose backend-specific priority values.
public typealias DesiredNetworkACLRule = Strato_Agent_V1_DesiredNetworkACLRule
extension Strato_Agent_V1_DesiredNetworkACLRule: Codable {

    public init(
        id: UUID,
        ruleNumber: Int,
        direction: String,
        ethertype: String,
        action: String,
        protocolName: String? = nil,
        portRangeMin: Int? = nil,
        portRangeMax: Int? = nil,
        remoteCIDR: String
    ) {
        self.init()
        self._jsonId = id
        self._jsonRuleNumber = ruleNumber
        self._jsonDirection = direction
        self._jsonEthertype = ethertype
        self._jsonAction = action
        self._jsonProtocolName = protocolName
        self._jsonPortRangeMin = portRangeMin
        self._jsonPortRangeMax = portRangeMax
        self._jsonRemoteCIDR = remoteCIDR
    }

    private enum CodingKeys: String, CodingKey {
        case id; case ruleNumber; case direction; case ethertype; case action; case protocolName; case portRangeMin;
        case portRangeMax; case remoteCIDR
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonId = try container.decode(UUID.self, forKey: .id)
        self._jsonRuleNumber = try container.decode(Int.self, forKey: .ruleNumber)
        self._jsonDirection = try container.decode(String.self, forKey: .direction)
        self._jsonEthertype = try container.decode(String.self, forKey: .ethertype)
        self._jsonAction = try container.decode(String.self, forKey: .action)
        self._jsonProtocolName = try container.decodeIfPresent(String.self, forKey: .protocolName)
        self._jsonPortRangeMin = try container.decodeIfPresent(Int.self, forKey: .portRangeMin)
        self._jsonPortRangeMax = try container.decodeIfPresent(Int.self, forKey: .portRangeMax)
        self._jsonRemoteCIDR = try container.decode(String.self, forKey: .remoteCIDR)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonId, forKey: .id)
        try container.encode(_jsonRuleNumber, forKey: .ruleNumber)
        try container.encode(_jsonDirection, forKey: .direction)
        try container.encode(_jsonEthertype, forKey: .ethertype)
        try container.encode(_jsonAction, forKey: .action)
        try container.encodeIfPresent(_jsonProtocolName, forKey: .protocolName)
        try container.encodeIfPresent(_jsonPortRangeMin, forKey: .portRangeMin)
        try container.encodeIfPresent(_jsonPortRangeMax, forKey: .portRangeMax)
        try container.encode(_jsonRemoteCIDR, forKey: .remoteCIDR)
    }

}

/// The one network ACL attached to a logical network.
///
/// The control plane bumps `generation` for every rule mutation. The agent
/// realizes the whole ordered rule set as one fail-closed replacement, never as
/// an imperative per-rule edit.
public typealias DesiredNetworkACL = Strato_Agent_V1_DesiredNetworkACL
extension Strato_Agent_V1_DesiredNetworkACL: Codable {

    public init(id: UUID, generation: Int64, rules: [DesiredNetworkACLRule]) {
        self.init()
        self._jsonId = id
        self._jsonGeneration = generation
        self._jsonRules = rules
    }

    private enum CodingKeys: String, CodingKey { case id; case generation; case rules }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonId = try container.decode(UUID.self, forKey: .id)
        self._jsonGeneration = try container.decode(Int64.self, forKey: .generation)
        self._jsonRules = try container.decode([DesiredNetworkACLRule].self, forKey: .rules)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonId, forKey: .id)
        try container.encode(_jsonGeneration, forKey: .generation)
        try container.encode(_jsonRules, forKey: .rules)
    }

}

// MARK: - Desired Network State

/// One floating IP the agent should realize as a `dnat_and_snat` NAT rule on
/// the network's logical router (issue #344): traffic to `externalIP` is
/// DNAT'd to the VM's fixed `logicalIP`, and the VM's outbound traffic is
/// SNAT'd to `externalIP` (overriding the router's subnet-wide SNAT).
///
/// `vmId`/`nicIndex` identify the NIC's logical switch port so the agent can
/// program *distributed* NAT (`logical_port` + `external_mac`): the FIP is
/// then handled on the chassis hosting the VM rather than hairpinning through
/// the gateway chassis. The port name is derived agent-side (`OVNNaming`), not
/// carried on the wire, so naming stays a single-owner concern.
public typealias DesiredFloatingIP = Strato_Agent_V1_DesiredFloatingIP
extension Strato_Agent_V1_DesiredFloatingIP: Codable {

    public init(
        externalIP: String, logicalIP: String, vmId: UUID? = nil, nicIndex: Int? = nil
    ) {
        self.init()
        self._jsonExternalIP = externalIP
        self._jsonLogicalIP = logicalIP
        self._jsonVmId = vmId
        self._jsonNicIndex = nicIndex
    }

    private enum CodingKeys: String, CodingKey { case externalIP; case logicalIP; case vmId; case nicIndex }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonExternalIP = try container.decode(String.self, forKey: .externalIP)
        self._jsonLogicalIP = try container.decode(String.self, forKey: .logicalIP)
        self._jsonVmId = try container.decodeIfPresent(UUID.self, forKey: .vmId)
        self._jsonNicIndex = try container.decodeIfPresent(Int.self, forKey: .nicIndex)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonExternalIP, forKey: .externalIP)
        try container.encode(_jsonLogicalIP, forKey: .logicalIP)
        try container.encodeIfPresent(_jsonVmId, forKey: .vmId)
        try container.encodeIfPresent(_jsonNicIndex, forKey: .nicIndex)
    }

}

/// One listener on an OVN-native L4 load balancer (STR-28). The control plane
/// keeps listeners separate so high-churn backend membership never requires a
/// read-modify-write of this stable port mapping.
public typealias DesiredLoadBalancerListener = Strato_Agent_V1_DesiredLoadBalancerListener
extension Strato_Agent_V1_DesiredLoadBalancerListener: Codable {

    public init(id: UUID, port: Int, backendPort: Int) {
        self.init()
        self._jsonId = id
        self._jsonPort = port
        self._jsonBackendPort = backendPort
    }

    private enum CodingKeys: String, CodingKey { case id; case port; case backendPort }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonId = try container.decode(UUID.self, forKey: .id)
        self._jsonPort = try container.decode(Int.self, forKey: .port)
        self._jsonBackendPort = try container.decode(Int.self, forKey: .backendPort)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonId, forKey: .id)
        try container.encode(_jsonPort, forKey: .port)
        try container.encode(_jsonBackendPort, forKey: .backendPort)
    }

}

/// One backend address for a desired load balancer. VM identity is carried
/// only for on-platform NICs, allowing the agent to derive the stable OVN LSP
/// name used by health-check `ip_port_mappings`. Off-platform targets have an
/// address but no VM, NIC, or member switch.
public typealias DesiredLoadBalancerBackend = Strato_Agent_V1_DesiredLoadBalancerBackend
extension Strato_Agent_V1_DesiredLoadBalancerBackend: Codable {

    public init(
        id: UUID,
        ipAddress: String,
        vmId: UUID? = nil,
        nicIndex: Int? = nil,
        networkId: UUID? = nil,
        healthCheckSourceIP: String? = nil
    ) {
        self.init()
        self._jsonId = id
        self._jsonIpAddress = ipAddress
        self._jsonVmId = vmId
        self._jsonNicIndex = nicIndex
        self._jsonNetworkId = networkId
        self._jsonHealthCheckSourceIP = healthCheckSourceIP
    }

    private enum CodingKeys: String, CodingKey {
        case id; case ipAddress; case vmId; case nicIndex; case networkId; case healthCheckSourceIP
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonId = try container.decode(UUID.self, forKey: .id)
        self._jsonIpAddress = try container.decode(String.self, forKey: .ipAddress)
        self._jsonVmId = try container.decodeIfPresent(UUID.self, forKey: .vmId)
        self._jsonNicIndex = try container.decodeIfPresent(Int.self, forKey: .nicIndex)
        self._jsonNetworkId = try container.decodeIfPresent(UUID.self, forKey: .networkId)
        self._jsonHealthCheckSourceIP = try container.decodeIfPresent(String.self, forKey: .healthCheckSourceIP)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonId, forKey: .id)
        try container.encode(_jsonIpAddress, forKey: .ipAddress)
        try container.encodeIfPresent(_jsonVmId, forKey: .vmId)
        try container.encodeIfPresent(_jsonNicIndex, forKey: .nicIndex)
        try container.encodeIfPresent(_jsonNetworkId, forKey: .networkId)
        try container.encodeIfPresent(_jsonHealthCheckSourceIP, forKey: .healthCheckSourceIP)
    }

}

public typealias DesiredLoadBalancerHealthCheck = Strato_Agent_V1_DesiredLoadBalancerHealthCheck
extension Strato_Agent_V1_DesiredLoadBalancerHealthCheck: Codable {

    public init(
        enabled: Bool,
        intervalSeconds: Int,
        timeoutSeconds: Int,
        successThreshold: Int,
        failureThreshold: Int
    ) {
        self.init()
        self._jsonEnabled = enabled
        self._jsonIntervalSeconds = intervalSeconds
        self._jsonTimeoutSeconds = timeoutSeconds
        self._jsonSuccessThreshold = successThreshold
        self._jsonFailureThreshold = failureThreshold
    }

    private enum CodingKeys: String, CodingKey {
        case enabled; case intervalSeconds; case timeoutSeconds; case successThreshold; case failureThreshold
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonEnabled = try container.decode(Bool.self, forKey: .enabled)
        self._jsonIntervalSeconds = try container.decode(Int.self, forKey: .intervalSeconds)
        self._jsonTimeoutSeconds = try container.decode(Int.self, forKey: .timeoutSeconds)
        self._jsonSuccessThreshold = try container.decode(Int.self, forKey: .successThreshold)
        self._jsonFailureThreshold = try container.decode(Int.self, forKey: .failureThreshold)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonEnabled, forKey: .enabled)
        try container.encode(_jsonIntervalSeconds, forKey: .intervalSeconds)
        try container.encode(_jsonTimeoutSeconds, forKey: .timeoutSeconds)
        try container.encode(_jsonSuccessThreshold, forKey: .successThreshold)
        try container.encode(_jsonFailureThreshold, forKey: .failureThreshold)
    }

}

/// A first-class Strato L4 load balancer, keyed by its resource UUID rather
/// than its mutable display name. Omission from an authoritative network sync
/// means the owner-tagged OVN row must be removed.
public typealias DesiredLoadBalancer = Strato_Agent_V1_DesiredLoadBalancer
extension Strato_Agent_V1_DesiredLoadBalancer: Codable {

    public init(
        id: UUID,
        name: String,
        vip: String,
        protocolName: String,
        generation: Int64,
        healthCheck: DesiredLoadBalancerHealthCheck,
        listeners: [DesiredLoadBalancerListener],
        backends: [DesiredLoadBalancerBackend]
    ) {
        self.init()
        self._jsonId = id
        self._jsonName = name
        self._jsonVip = vip
        self._jsonProtocolName = protocolName
        self._jsonGeneration = generation
        self._jsonHealthCheck = healthCheck
        self._jsonListeners = listeners
        self._jsonBackends = backends
    }

    private enum CodingKeys: String, CodingKey {
        case id; case name; case vip; case protocolName; case generation; case healthCheck; case listeners;
        case backends
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonId = try container.decode(UUID.self, forKey: .id)
        self._jsonName = try container.decode(String.self, forKey: .name)
        self._jsonVip = try container.decode(String.self, forKey: .vip)
        self._jsonProtocolName = try container.decode(String.self, forKey: .protocolName)
        self._jsonGeneration = try container.decode(Int64.self, forKey: .generation)
        self._jsonHealthCheck = try container.decode(DesiredLoadBalancerHealthCheck.self, forKey: .healthCheck)
        self._jsonListeners = try container.decode([DesiredLoadBalancerListener].self, forKey: .listeners)
        self._jsonBackends = try container.decode([DesiredLoadBalancerBackend].self, forKey: .backends)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonId, forKey: .id)
        try container.encode(_jsonName, forKey: .name)
        try container.encode(_jsonVip, forKey: .vip)
        try container.encode(_jsonProtocolName, forKey: .protocolName)
        try container.encode(_jsonGeneration, forKey: .generation)
        try container.encode(_jsonHealthCheck, forKey: .healthCheck)
        try container.encode(_jsonListeners, forKey: .listeners)
        try container.encode(_jsonBackends, forKey: .backends)
    }

}

/// The state the control plane wants a logical network to be in on an agent.
///
/// Networking used to reach the agent only as a side effect of `VMSpec.networks`
/// during VM create, so routers/NAT had nowhere to live. This makes the network
/// (and its L3 router + uplink) a first-class entry in the desired-state sync,
/// reconciled level-triggered just like VMs: a network omitted from the list
/// should not exist on the agent.
///
/// Router scope is per-project: every network in the same project shares one
/// logical router (giving cross-switch east-west), keyed by `routerKey`. Two
/// projects never share a router, which is what makes it safe for them to use
/// the same subnet (issue #765).
public typealias DesiredNetworkState = Strato_Agent_V1_DesiredNetworkState
extension Strato_Agent_V1_DesiredNetworkState: Codable {

    public init(
        networkId: UUID,
        name: String,
        subnet: String,
        gateway: String?,
        subnet6: String? = nil,
        gateway6: String? = nil,
        routerKey: String,
        externalAccess: Bool,
        dhcpEnabled: Bool = false,
        dnsServers: [String] = [],
        domainName: String? = nil,
        leaseTime: Int? = nil,
        metadataEnabled: Bool = false,
        resolverEnabled: Bool? = nil,
        resolverAddresses: [String]? = nil,
        generation: Int64,
        floatingIPs: [DesiredFloatingIP] = [],
        loadBalancers: [DesiredLoadBalancer] = [],
        networkACLs: [DesiredNetworkACL]? = nil
    ) {
        self.init()
        self._jsonNetworkId = networkId
        self._jsonName = name
        self._jsonSubnet = subnet
        self._jsonGateway = gateway
        self._jsonSubnet6 = subnet6
        self._jsonGateway6 = gateway6
        self._jsonRouterKey = routerKey
        self._jsonExternalAccess = externalAccess
        self._jsonDhcpEnabled = dhcpEnabled
        self._jsonDnsServers = dnsServers
        self._jsonDomainName = domainName
        self._jsonLeaseTime = leaseTime
        self._jsonMetadataEnabled = metadataEnabled
        self._jsonResolverEnabled = resolverEnabled
        self._jsonResolverAddresses = resolverAddresses
        self._jsonGeneration = generation
        self._jsonFloatingIPs = floatingIPs
        self._jsonLoadBalancers = loadBalancers
        self._jsonNetworkACLs = networkACLs
    }

    private enum CodingKeys: String, CodingKey {
        case networkId; case name; case subnet; case gateway; case subnet6; case gateway6; case routerKey;
        case externalAccess; case dhcpEnabled; case dnsServers; case domainName; case leaseTime; case metadataEnabled;
        case resolverEnabled; case resolverAddresses; case generation; case floatingIPs; case loadBalancers;
        case networkACLs
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonNetworkId = try container.decode(UUID.self, forKey: .networkId)
        self._jsonName = try container.decode(String.self, forKey: .name)
        self._jsonSubnet = try container.decode(String.self, forKey: .subnet)
        self._jsonGateway = try container.decodeIfPresent(String.self, forKey: .gateway)
        self._jsonSubnet6 = try container.decodeIfPresent(String.self, forKey: .subnet6)
        self._jsonGateway6 = try container.decodeIfPresent(String.self, forKey: .gateway6)
        self._jsonRouterKey = try container.decode(String.self, forKey: .routerKey)
        self._jsonExternalAccess = try container.decode(Bool.self, forKey: .externalAccess)
        self._jsonDhcpEnabled = try container.decode(Bool.self, forKey: .dhcpEnabled)
        self._jsonDnsServers = try container.decode([String].self, forKey: .dnsServers)
        self._jsonDomainName = try container.decodeIfPresent(String.self, forKey: .domainName)
        self._jsonLeaseTime = try container.decodeIfPresent(Int.self, forKey: .leaseTime)
        self._jsonMetadataEnabled = try container.decode(Bool.self, forKey: .metadataEnabled)
        self._jsonResolverEnabled = try container.decodeIfPresent(Bool.self, forKey: .resolverEnabled)
        self._jsonResolverAddresses = try container.decodeIfPresent([String].self, forKey: .resolverAddresses)
        self._jsonGeneration = try container.decode(Int64.self, forKey: .generation)
        self._jsonFloatingIPs = try container.decode([DesiredFloatingIP].self, forKey: .floatingIPs)
        self._jsonLoadBalancers = try container.decode([DesiredLoadBalancer].self, forKey: .loadBalancers)
        self._jsonNetworkACLs = try container.decodeIfPresent([DesiredNetworkACL].self, forKey: .networkACLs)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonNetworkId, forKey: .networkId)
        try container.encode(_jsonName, forKey: .name)
        try container.encode(_jsonSubnet, forKey: .subnet)
        try container.encodeIfPresent(_jsonGateway, forKey: .gateway)
        try container.encodeIfPresent(_jsonSubnet6, forKey: .subnet6)
        try container.encodeIfPresent(_jsonGateway6, forKey: .gateway6)
        try container.encode(_jsonRouterKey, forKey: .routerKey)
        try container.encode(_jsonExternalAccess, forKey: .externalAccess)
        try container.encode(_jsonDhcpEnabled, forKey: .dhcpEnabled)
        try container.encode(_jsonDnsServers, forKey: .dnsServers)
        try container.encodeIfPresent(_jsonDomainName, forKey: .domainName)
        try container.encodeIfPresent(_jsonLeaseTime, forKey: .leaseTime)
        try container.encode(_jsonMetadataEnabled, forKey: .metadataEnabled)
        try container.encodeIfPresent(_jsonResolverEnabled, forKey: .resolverEnabled)
        try container.encodeIfPresent(_jsonResolverAddresses, forKey: .resolverAddresses)
        try container.encode(_jsonGeneration, forKey: .generation)
        try container.encode(_jsonFloatingIPs, forKey: .floatingIPs)
        try container.encode(_jsonLoadBalancers, forKey: .loadBalancers)
        try container.encodeIfPresent(_jsonNetworkACLs, forKey: .networkACLs)
    }

}

// MARK: - Desired DNS zones

/// One resource record set inside a zone: an owner name, a type, and every
/// value published at that name for that type (STR-39).
///
/// Typed rather than pre-flattened into the `name → addresses` map OVN's `DNS`
/// table takes, for two reasons. Realization is meant to be a swappable driver
/// — the OVN writer joins a name's A and AAAA values into one space-separated
/// string, while a zone file keeps them apart — and only the *receiver* can say
/// which types its backend can express, which is what lets the agent report the
/// ones it had to skip instead of the control plane silently dropping them.
///
/// `type` is a string, not an enum, on the `DesiredSecurityGroupRule.direction`
/// precedent: a record type from a newer control plane must decode into an
/// entry this agent ignores, never fail the whole sync.
public typealias DesiredDNSRecord = Strato_Agent_V1_DesiredDNSRecord
extension Strato_Agent_V1_DesiredDNSRecord: Codable {

    public init(name: String, type: String, values: [String], ttl: Int = 300) {
        self.init()
        self._jsonName = name
        self._jsonType = type
        self._jsonValues = values
        self._jsonTtl = ttl
    }

    private enum CodingKeys: String, CodingKey { case name; case type; case values; case ttl }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonName = try container.decode(String.self, forKey: .name)
        self._jsonType = try container.decode(String.self, forKey: .type)
        self._jsonValues = try container.decode([String].self, forKey: .values)
        self._jsonTtl = try container.decode(Int.self, forKey: .ttl)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonName, forKey: .name)
        try container.encode(_jsonType, forKey: .type)
        try container.encode(_jsonValues, forKey: .values)
        try container.encode(_jsonTtl, forKey: .ttl)
    }

}

/// A DNS zone the receiving agent should realize (STR-39, roadmap #769).
///
/// This rides the **network-level carrier, not `NetworkSpec`**: DNS and DHCP
/// edits deliberately don't bump VM generations, so a converged VM never
/// re-realizes its NICs and would never see a record change. The
/// level-triggered network reconcile is what converges these rows, exactly as
/// it does `DHCP_Options`.
///
/// A zone's contents span every VM on every attached network across *all*
/// agents, so `records` is assembled from the whole fleet rather than from the
/// receiving agent's own workloads. That has been true since v36 and is what
/// makes the two realizations below able to share one payload.
///
/// ## Two backends, two audiences
///
/// The **OVN `DNS` table** (v36) is switch-scoped topology written into the
/// shared northbound database, so only the site's topology authority may write
/// it — two level-triggered writers would fight over one row. `networkIds`
/// carries the networks that agent authors.
///
/// The **per-network resolver** (v37, STR-40) is not topology: a CoreDNS runs
/// in the host namespace of every host with a local NIC on the network, serving
/// the zones attached to that network from a server block bound to its own
/// address pair (ADR 0008). So from v37 a zone is sent
/// to any agent that either authors an attached network *or* runs a workload
/// on one, and `networkIds` is the union of both. An agent realizes the OVN
/// half only for the networks it actually authors, which it already knows from
/// `DesiredStateMessage.networksAuthoritative`.
public typealias DesiredDNSZone = Strato_Agent_V1_DesiredDNSZone
extension Strato_Agent_V1_DesiredDNSZone: Codable {

    public init(
        zoneId: UUID, zoneName: String, networkIds: [UUID], records: [DesiredDNSRecord],
        recordsHash: String
    ) {
        self.init()
        self._jsonZoneId = zoneId
        self._jsonZoneName = zoneName
        self._jsonNetworkIds = networkIds
        self._jsonRecords = records
        self._jsonRecordsHash = recordsHash
    }

    private enum CodingKeys: String, CodingKey {
        case zoneId; case zoneName; case networkIds; case records; case recordsHash
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonZoneId = try container.decode(UUID.self, forKey: .zoneId)
        self._jsonZoneName = try container.decode(String.self, forKey: .zoneName)
        self._jsonNetworkIds = try container.decode([UUID].self, forKey: .networkIds)
        self._jsonRecords = try container.decode([DesiredDNSRecord].self, forKey: .records)
        self._jsonRecordsHash = try container.decode(String.self, forKey: .recordsHash)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonZoneId, forKey: .zoneId)
        try container.encode(_jsonZoneName, forKey: .zoneName)
        try container.encode(_jsonNetworkIds, forKey: .networkIds)
        try container.encode(_jsonRecords, forKey: .records)
        try container.encode(_jsonRecordsHash, forKey: .recordsHash)
    }

}

// MARK: - Observed VM State

/// How the agent will treat a reported convergence failure on later syncs.
///
/// Optional on observed resource entries for wire compatibility: an older
/// agent does not send it, and the control plane must keep its historical
/// terminal-failure behavior in that case. `waitingOnDependency` never reaches
/// an observed error at all, so it has no wire case.
public typealias ObservedFailureClassification = Strato_Agent_V1_ObservedFailureClassification
extension Strato_Agent_V1_ObservedFailureClassification: Codable {

    public var protocolValue: String {
        switch self {
        case .transient: return "transient"
        case .permanent: return "permanent"
        case .blocked: return "blocked"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "transient": self = .transient
        case "permanent": self = .permanent
        case "blocked": self = .blocked
        default: return nil
        }
    }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown enum value")
        }
        self = value
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        guard !protocolValue.isEmpty else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Unknown enum value"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(protocolValue)
    }
}

/// One VM's state as actually observed on an agent.
public typealias ObservedVMState = Strato_Agent_V1_ObservedVMState
extension Strato_Agent_V1_ObservedVMState: Codable {

    public init(
        vmId: UUID,
        status: VMStatus,
        observedGeneration: Int64,
        convergencePhase: String? = nil,
        lastError: String? = nil,
        failedGeneration: Int64? = nil,
        failureClassification: ObservedFailureClassification? = nil,
        guestInfo: GuestInfo? = nil,
        guestAgentObservation: GuestAgentObservation? = nil,
        guestConfigObservation: GuestConfigObservation? = nil,
        guestConfigFailedGeneration: Int64? = nil,
        memoryStats: VMMemoryStats? = nil,
        resourceTelemetry: WorkloadResourceTelemetry? = nil,
        appliedNetworkInterfaceIds: [UUID]? = nil
    ) {
        self.init()
        self._jsonVmId = vmId
        self._jsonStatus = status
        self._jsonObservedGeneration = observedGeneration
        self._jsonConvergencePhase = convergencePhase
        self._jsonLastError = lastError
        self._jsonFailedGeneration = failedGeneration
        self._jsonFailureClassification = failureClassification
        self._jsonGuestInfo = guestInfo
        self._jsonGuestAgentObservation = guestAgentObservation
        self._jsonGuestConfigObservation = guestConfigObservation
        self._jsonGuestConfigFailedGeneration = guestConfigFailedGeneration
        self._jsonMemoryStats = memoryStats
        self._jsonResourceTelemetry = resourceTelemetry
        self._jsonAppliedNetworkInterfaceIds = appliedNetworkInterfaceIds
    }

    private enum CodingKeys: String, CodingKey {
        case vmId; case status; case observedGeneration; case convergencePhase; case lastError; case failedGeneration;
        case failureClassification; case guestInfo; case guestAgentObservation; case guestConfigObservation;
        case guestConfigFailedGeneration; case memoryStats; case resourceTelemetry; case appliedNetworkInterfaceIds
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonVmId = try container.decode(UUID.self, forKey: .vmId)
        self._jsonStatus = try container.decode(VMStatus.self, forKey: .status)
        self._jsonObservedGeneration = try container.decode(Int64.self, forKey: .observedGeneration)
        self._jsonConvergencePhase = try container.decodeIfPresent(String.self, forKey: .convergencePhase)
        self._jsonLastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        self._jsonFailedGeneration = try container.decodeIfPresent(Int64.self, forKey: .failedGeneration)
        self._jsonFailureClassification = try container.decodeIfPresent(
            ObservedFailureClassification.self, forKey: .failureClassification)
        self._jsonGuestInfo = try container.decodeIfPresent(GuestInfo.self, forKey: .guestInfo)
        self._jsonGuestAgentObservation = try container.decodeIfPresent(
            GuestAgentObservation.self, forKey: .guestAgentObservation)
        self._jsonGuestConfigObservation = try container.decodeIfPresent(
            GuestConfigObservation.self, forKey: .guestConfigObservation)
        self._jsonGuestConfigFailedGeneration = try container.decodeIfPresent(
            Int64.self, forKey: .guestConfigFailedGeneration)
        self._jsonMemoryStats = try container.decodeIfPresent(VMMemoryStats.self, forKey: .memoryStats)
        self._jsonResourceTelemetry = try container.decodeIfPresent(
            WorkloadResourceTelemetry.self, forKey: .resourceTelemetry)
        self._jsonAppliedNetworkInterfaceIds = try container.decodeIfPresent(
            [UUID].self, forKey: .appliedNetworkInterfaceIds)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonVmId, forKey: .vmId)
        try container.encode(_jsonStatus, forKey: .status)
        try container.encode(_jsonObservedGeneration, forKey: .observedGeneration)
        try container.encodeIfPresent(_jsonConvergencePhase, forKey: .convergencePhase)
        try container.encodeIfPresent(_jsonLastError, forKey: .lastError)
        try container.encodeIfPresent(_jsonFailedGeneration, forKey: .failedGeneration)
        try container.encodeIfPresent(_jsonFailureClassification, forKey: .failureClassification)
        try container.encodeIfPresent(_jsonGuestInfo, forKey: .guestInfo)
        try container.encodeIfPresent(_jsonGuestAgentObservation, forKey: .guestAgentObservation)
        try container.encodeIfPresent(_jsonGuestConfigObservation, forKey: .guestConfigObservation)
        try container.encodeIfPresent(_jsonGuestConfigFailedGeneration, forKey: .guestConfigFailedGeneration)
        try container.encodeIfPresent(_jsonMemoryStats, forKey: .memoryStats)
        try container.encodeIfPresent(_jsonResourceTelemetry, forKey: .resourceTelemetry)
        try container.encodeIfPresent(_jsonAppliedNetworkInterfaceIds, forKey: .appliedNetworkInterfaceIds)
    }

}

// MARK: - Observed Sandbox State

/// One sandbox's state as actually observed on an agent. Field semantics match
/// `ObservedVMState` (see the doc comments there for the generation/error
/// contract); `exitCode` is the sandbox-specific addition.
public typealias ObservedSandboxState = Strato_Agent_V1_ObservedSandboxState
extension Strato_Agent_V1_ObservedSandboxState: Codable {

    public init(
        sandboxId: UUID,
        status: SandboxStatus,
        observedGeneration: Int64,
        convergencePhase: String? = nil,
        lastError: String? = nil,
        failedGeneration: Int64? = nil,
        failureClassification: ObservedFailureClassification? = nil,
        exitCode: Int? = nil,
        resourceTelemetry: WorkloadResourceTelemetry? = nil,
        idleActivity: SandboxIdleActivityReport? = nil,
        suspension: SandboxSuspensionEvidence? = nil,
        suspensionStorageReservedBytes: Int64? = nil,
        suspensionStorageEstimateBytes: Int64? = nil
    ) {
        self.init()
        self._jsonSandboxId = sandboxId
        self._jsonStatus = status
        self._jsonObservedGeneration = observedGeneration
        self._jsonConvergencePhase = convergencePhase
        self._jsonLastError = lastError
        self._jsonFailedGeneration = failedGeneration
        self._jsonFailureClassification = failureClassification
        self._jsonExitCode = exitCode
        self._jsonResourceTelemetry = resourceTelemetry
        self._jsonIdleActivity = idleActivity
        self._jsonSuspension = suspension
        self._jsonSuspensionStorageReservedBytes = suspensionStorageReservedBytes
        self._jsonSuspensionStorageEstimateBytes = suspensionStorageEstimateBytes
    }

    private enum CodingKeys: String, CodingKey {
        case sandboxId; case status; case observedGeneration; case convergencePhase; case lastError;
        case failedGeneration; case failureClassification; case exitCode; case resourceTelemetry; case idleActivity;
        case suspension; case suspensionStorageReservedBytes; case suspensionStorageEstimateBytes
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonSandboxId = try container.decode(UUID.self, forKey: .sandboxId)
        self._jsonStatus = try container.decode(SandboxStatus.self, forKey: .status)
        self._jsonObservedGeneration = try container.decode(Int64.self, forKey: .observedGeneration)
        self._jsonConvergencePhase = try container.decodeIfPresent(String.self, forKey: .convergencePhase)
        self._jsonLastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        self._jsonFailedGeneration = try container.decodeIfPresent(Int64.self, forKey: .failedGeneration)
        self._jsonFailureClassification = try container.decodeIfPresent(
            ObservedFailureClassification.self, forKey: .failureClassification)
        self._jsonExitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        self._jsonResourceTelemetry = try container.decodeIfPresent(
            WorkloadResourceTelemetry.self, forKey: .resourceTelemetry)
        self._jsonIdleActivity = try container.decodeIfPresent(SandboxIdleActivityReport.self, forKey: .idleActivity)
        self._jsonSuspension = try container.decodeIfPresent(SandboxSuspensionEvidence.self, forKey: .suspension)
        self._jsonSuspensionStorageReservedBytes = try container.decodeIfPresent(
            Int64.self, forKey: .suspensionStorageReservedBytes)
        self._jsonSuspensionStorageEstimateBytes = try container.decodeIfPresent(
            Int64.self, forKey: .suspensionStorageEstimateBytes)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonSandboxId, forKey: .sandboxId)
        try container.encode(_jsonStatus, forKey: .status)
        try container.encode(_jsonObservedGeneration, forKey: .observedGeneration)
        try container.encodeIfPresent(_jsonConvergencePhase, forKey: .convergencePhase)
        try container.encodeIfPresent(_jsonLastError, forKey: .lastError)
        try container.encodeIfPresent(_jsonFailedGeneration, forKey: .failedGeneration)
        try container.encodeIfPresent(_jsonFailureClassification, forKey: .failureClassification)
        try container.encodeIfPresent(_jsonExitCode, forKey: .exitCode)
        try container.encodeIfPresent(_jsonResourceTelemetry, forKey: .resourceTelemetry)
        try container.encodeIfPresent(_jsonIdleActivity, forKey: .idleActivity)
        try container.encodeIfPresent(_jsonSuspension, forKey: .suspension)
        try container.encodeIfPresent(_jsonSuspensionStorageReservedBytes, forKey: .suspensionStorageReservedBytes)
        try container.encodeIfPresent(_jsonSuspensionStorageEstimateBytes, forKey: .suspensionStorageEstimateBytes)
    }

}

// MARK: - Observed Volume State

/// One volume's state as actually observed on an agent (ADR 0001 stage 5,
/// STR-148). Field semantics for the convergence metadata match
/// `ObservedVMState` — see the doc comments there.
///
/// `sizeBytes` was deliberately absent until STR-199, on the grounds that
/// reading a volume's virtual size meant a `qemu-img info` subprocess per
/// volume per report. That cost is no longer hypothetical *or* avoidable: the
/// agent's planner needs the same number to decide whether a grow is
/// outstanding, so it already computes and caches one per volume — every write
/// path records the size it produced, and the probe fires only for a volume
/// this process has not seen written. Reporting it adds no work at all.
///
/// ADR stage 7 (STR-149) settled the same question for the rest of what
/// `volume_info` used to return, and settled it the same way: nothing was
/// added. Format, disk attachment and VM attachment were already here; allocated bytes, the
/// dirty flag and the encryption flag have no reader, and allocation in
/// particular moves with every guest write, so it cannot be cached the way
/// virtual size can and would cost a subprocess per volume per report. A
/// per-volume usage surface — sampled on its own cadence, off the convergence
/// path — is the right home for those if a reader ever appears.
public typealias ObservedVolumeState = Strato_Agent_V1_ObservedVolumeState
extension Strato_Agent_V1_ObservedVolumeState: Codable {

    public init(
        volumeId: UUID,
        present: Bool,
        attachment: DiskAttachment? = nil,
        sizeBytes: Int64? = nil,
        attachedVMId: UUID? = nil,
        observedGeneration: Int64,
        convergencePhase: String? = nil,
        lastError: String? = nil,
        failedGeneration: Int64? = nil,
        failureClassification: ObservedFailureClassification? = nil,
        ioLimits: VolumeIOLimits? = nil,
        blockPolicy: AppliedBlockDevicePolicy? = nil,
        ioObservedRate: VolumeIOObservedRate? = nil
    ) {
        self.init()
        self._jsonVolumeId = volumeId
        self._jsonPresent = present
        self._jsonAttachment = attachment
        self._jsonSizeBytes = sizeBytes
        self._jsonAttachedVMId = attachedVMId
        self._jsonObservedGeneration = observedGeneration
        self._jsonConvergencePhase = convergencePhase
        self._jsonLastError = lastError
        self._jsonFailedGeneration = failedGeneration
        self._jsonFailureClassification = failureClassification
        self._jsonIoLimits = ioLimits
        self._jsonBlockPolicy = blockPolicy
        self._jsonIoObservedRate = ioObservedRate
    }

    private enum CodingKeys: String, CodingKey {
        case volumeId; case present; case attachment; case sizeBytes; case attachedVMId; case observedGeneration;
        case convergencePhase; case lastError; case failedGeneration; case failureClassification; case ioLimits;
        case blockPolicy; case ioObservedRate
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonVolumeId = try container.decode(UUID.self, forKey: .volumeId)
        self._jsonPresent = try container.decode(Bool.self, forKey: .present)
        self._jsonAttachment = try container.decodeIfPresent(DiskAttachment.self, forKey: .attachment)
        self._jsonSizeBytes = try container.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        self._jsonAttachedVMId = try container.decodeIfPresent(UUID.self, forKey: .attachedVMId)
        self._jsonObservedGeneration = try container.decode(Int64.self, forKey: .observedGeneration)
        self._jsonConvergencePhase = try container.decodeIfPresent(String.self, forKey: .convergencePhase)
        self._jsonLastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        self._jsonFailedGeneration = try container.decodeIfPresent(Int64.self, forKey: .failedGeneration)
        self._jsonFailureClassification = try container.decodeIfPresent(
            ObservedFailureClassification.self, forKey: .failureClassification)
        self._jsonIoLimits = try container.decodeIfPresent(VolumeIOLimits.self, forKey: .ioLimits)
        self._jsonBlockPolicy = try container.decodeIfPresent(AppliedBlockDevicePolicy.self, forKey: .blockPolicy)
        self._jsonIoObservedRate = try container.decodeIfPresent(VolumeIOObservedRate.self, forKey: .ioObservedRate)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonVolumeId, forKey: .volumeId)
        try container.encode(_jsonPresent, forKey: .present)
        try container.encodeIfPresent(_jsonAttachment, forKey: .attachment)
        try container.encodeIfPresent(_jsonSizeBytes, forKey: .sizeBytes)
        try container.encodeIfPresent(_jsonAttachedVMId, forKey: .attachedVMId)
        try container.encode(_jsonObservedGeneration, forKey: .observedGeneration)
        try container.encodeIfPresent(_jsonConvergencePhase, forKey: .convergencePhase)
        try container.encodeIfPresent(_jsonLastError, forKey: .lastError)
        try container.encodeIfPresent(_jsonFailedGeneration, forKey: .failedGeneration)
        try container.encodeIfPresent(_jsonFailureClassification, forKey: .failureClassification)
        try container.encodeIfPresent(_jsonIoLimits, forKey: .ioLimits)
        try container.encodeIfPresent(_jsonBlockPolicy, forKey: .blockPolicy)
        try container.encodeIfPresent(_jsonIoObservedRate, forKey: .ioObservedRate)
    }

}

// MARK: - Observed Agent Update Status

/// Why an agent is not converging on the sync's `DesiredAgentUpdate`
/// (issue #434), reported back on the observed-state report so the control
/// plane's rollout can distinguish "waiting on a precondition" from "the
/// update itself failed" instead of timing both out identically.
public typealias ObservedAgentUpdateStatus = Strato_Agent_V1_ObservedAgentUpdateStatus
extension Strato_Agent_V1_ObservedAgentUpdateStatus: Codable {
    /// A precondition currently prevents the attempt (containerized install,
    /// in-flight reconcile work). Transient from the rollout's perspective:
    /// the agent re-evaluates on every sync.
    public static let dispositionBlocked = "blocked"
    /// The update was attempted and did not take (download, checksum, probe,
    /// or swap failure — or the installed artifact did not change the
    /// version). The agent will not retry this artifact within the current
    /// process lifetime, so the rollout should halt rather than wait.
    public static let dispositionFailed = "failed"

    public init(targetVersion: String, disposition: String, reason: String) {
        self.init()
        self._jsonTargetVersion = targetVersion
        self._jsonDisposition = disposition
        self._jsonReason = reason
    }

    private enum CodingKeys: String, CodingKey { case targetVersion; case disposition; case reason }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonTargetVersion = try container.decode(String.self, forKey: .targetVersion)
        self._jsonDisposition = try container.decode(String.self, forKey: .disposition)
        self._jsonReason = try container.decode(String.self, forKey: .reason)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonTargetVersion, forKey: .targetVersion)
        try container.encode(_jsonDisposition, forKey: .disposition)
        try container.encode(_jsonReason, forKey: .reason)
    }

}

// MARK: - Unrecognized workloads

/// A workload an agent holds that the last desired-state sync did not list
/// (STR-98).
///
/// The agent **holds** it — running, untouched, adopted into no desired
/// generation — and reports it here so the control plane can decide. A row
/// that still exists means an assembler or scoping bug and must never
/// authorize teardown; no row at all earns a `DesiredWorkloadTombstone` on a
/// later sync.
public typealias UnrecognizedWorkload = Strato_Agent_V1_UnrecognizedWorkload
extension Strato_Agent_V1_UnrecognizedWorkload: Codable {

    public init(kind: WorkloadKind, workloadId: UUID, observedGeneration: Int64, status: String? = nil) {
        self.init()
        self._jsonKind = kind
        self._jsonWorkloadId = workloadId
        self._jsonObservedGeneration = observedGeneration
        self._jsonStatus = status
    }

    private enum CodingKeys: String, CodingKey { case kind; case workloadId; case observedGeneration; case status }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonKind = try container.decode(WorkloadKind.self, forKey: .kind)
        self._jsonWorkloadId = try container.decode(UUID.self, forKey: .workloadId)
        self._jsonObservedGeneration = try container.decode(Int64.self, forKey: .observedGeneration)
        self._jsonStatus = try container.decodeIfPresent(String.self, forKey: .status)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonKind, forKey: .kind)
        try container.encode(_jsonWorkloadId, forKey: .workloadId)
        try container.encode(_jsonObservedGeneration, forKey: .observedGeneration)
        try container.encodeIfPresent(_jsonStatus, forKey: .status)
    }

}

/// Why an agent refused to converge the teardowns a sync authorized (STR-98
/// phase 2): the blast-radius guard tripped.
///
/// Reported so the refusal reaches operators through the plumbing that already
/// exists, rather than living only in an agent log nobody is watching. The
/// agent keeps converging everything else in the sync.
public typealias ObservedTeardownRefusal = Strato_Agent_V1_ObservedTeardownRefusal
extension Strato_Agent_V1_ObservedTeardownRefusal: Codable {

    public init(syncId: String, requestedTeardowns: Int, presentWorkloads: Int, reason: String) {
        self.init()
        self._jsonSyncId = syncId
        self._jsonRequestedTeardowns = requestedTeardowns
        self._jsonPresentWorkloads = presentWorkloads
        self._jsonReason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case syncId; case requestedTeardowns; case presentWorkloads; case reason
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonSyncId = try container.decode(String.self, forKey: .syncId)
        self._jsonRequestedTeardowns = try container.decode(Int.self, forKey: .requestedTeardowns)
        self._jsonPresentWorkloads = try container.decode(Int.self, forKey: .presentWorkloads)
        self._jsonReason = try container.decode(String.self, forKey: .reason)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonSyncId, forKey: .syncId)
        try container.encode(_jsonRequestedTeardowns, forKey: .requestedTeardowns)
        try container.encode(_jsonPresentWorkloads, forKey: .presentWorkloads)
        try container.encode(_jsonReason, forKey: .reason)
    }

}

/// Agent → control plane: what the agent's durable workload manifest — its
/// only memory of what it is running — was able to tell it at startup
/// (STR-138).
///
/// Sent only when there is something wrong to say; nil is the steady state.
public typealias ObservedManifestStatus = Strato_Agent_V1_ObservedManifestStatus
extension Strato_Agent_V1_ObservedManifestStatus: Codable {

    public init(
        inventoryComplete: Bool,
        quarantinedEntries: Int,
        reason: String
    ) {
        self.init()
        self._jsonInventoryComplete = inventoryComplete
        self._jsonQuarantinedEntries = quarantinedEntries
        self._jsonReason = reason
    }

    private enum CodingKeys: String, CodingKey { case inventoryComplete; case quarantinedEntries; case reason }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonInventoryComplete = try container.decode(Bool.self, forKey: .inventoryComplete)
        self._jsonQuarantinedEntries = try container.decode(Int.self, forKey: .quarantinedEntries)
        self._jsonReason = try container.decode(String.self, forKey: .reason)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonInventoryComplete, forKey: .inventoryComplete)
        try container.encode(_jsonQuarantinedEntries, forKey: .quarantinedEntries)
        try container.encode(_jsonReason, forKey: .reason)
    }

}

// MARK: - Observed Network Fabric State

/// Whether one desired network-fabric object was realized by the reporting
/// agent. Reports are statements about the agent's own OVSDB writes, not packet
/// probes: `.active` means the requested writes and the verification read
/// completed, while `.error` preserves a failed attempt for the control plane.
public typealias ObservedNetworkFabricStatus = Strato_Agent_V1_ObservedNetworkFabricStatus
extension Strato_Agent_V1_ObservedNetworkFabricStatus: Codable {

    public var protocolValue: String {
        switch self {
        case .active: return "active"
        case .error: return "error"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "active": self = .active
        case "error": self = .error
        default: return nil
        }
    }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown enum value")
        }
        self = value
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        guard !protocolValue.isEmpty else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Unknown enum value"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(protocolValue)
    }
}

/// What the site's OVN topology authority observed after reconciling one
/// logical network. Optional at the report level because a non-authority has no
/// opinion about shared topology; an empty list is an authoritative opinion
/// about an empty desired set.
public typealias ObservedNetworkState = Strato_Agent_V1_ObservedNetworkState
extension Strato_Agent_V1_ObservedNetworkState: Codable {

    public init(
        id: UUID,
        observedGeneration: Int64,
        status: ObservedNetworkFabricStatus,
        lastError: String? = nil,
        failedGeneration: Int64? = nil,
        failureClassification: ObservedFailureClassification? = nil
    ) {
        self.init()
        self._jsonId = id
        self._jsonObservedGeneration = observedGeneration
        self._jsonStatus = status
        self._jsonLastError = lastError
        self._jsonFailedGeneration = failedGeneration
        self._jsonFailureClassification = failureClassification
    }

    private enum CodingKeys: String, CodingKey {
        case id; case observedGeneration; case status; case lastError; case failedGeneration; case failureClassification
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonId = try container.decode(UUID.self, forKey: .id)
        self._jsonObservedGeneration = try container.decode(Int64.self, forKey: .observedGeneration)
        self._jsonStatus = try container.decode(ObservedNetworkFabricStatus.self, forKey: .status)
        self._jsonLastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        self._jsonFailedGeneration = try container.decodeIfPresent(Int64.self, forKey: .failedGeneration)
        self._jsonFailureClassification = try container.decodeIfPresent(
            ObservedFailureClassification.self, forKey: .failureClassification)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonId, forKey: .id)
        try container.encode(_jsonObservedGeneration, forKey: .observedGeneration)
        try container.encode(_jsonStatus, forKey: .status)
        try container.encodeIfPresent(_jsonLastError, forKey: .lastError)
        try container.encodeIfPresent(_jsonFailedGeneration, forKey: .failedGeneration)
        try container.encodeIfPresent(_jsonFailureClassification, forKey: .failureClassification)
    }

}

/// What the site's OVN topology authority observed after reconciling one
/// security group's port group and ACLs. A group can be realized by more than
/// one site; each report remains scoped to its reporting authority and the
/// control plane is responsible for combining those opinions.
public typealias ObservedSecurityGroupState = Strato_Agent_V1_ObservedSecurityGroupState
extension Strato_Agent_V1_ObservedSecurityGroupState: Codable {

    public init(
        id: UUID,
        observedGeneration: Int64,
        status: ObservedNetworkFabricStatus,
        lastError: String? = nil,
        failedGeneration: Int64? = nil,
        failureClassification: ObservedFailureClassification? = nil
    ) {
        self.init()
        self._jsonId = id
        self._jsonObservedGeneration = observedGeneration
        self._jsonStatus = status
        self._jsonLastError = lastError
        self._jsonFailedGeneration = failedGeneration
        self._jsonFailureClassification = failureClassification
    }

    private enum CodingKeys: String, CodingKey {
        case id; case observedGeneration; case status; case lastError; case failedGeneration; case failureClassification
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonId = try container.decode(UUID.self, forKey: .id)
        self._jsonObservedGeneration = try container.decode(Int64.self, forKey: .observedGeneration)
        self._jsonStatus = try container.decode(ObservedNetworkFabricStatus.self, forKey: .status)
        self._jsonLastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        self._jsonFailedGeneration = try container.decodeIfPresent(Int64.self, forKey: .failedGeneration)
        self._jsonFailureClassification = try container.decodeIfPresent(
            ObservedFailureClassification.self, forKey: .failureClassification)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonId, forKey: .id)
        try container.encode(_jsonObservedGeneration, forKey: .observedGeneration)
        try container.encode(_jsonStatus, forKey: .status)
        try container.encodeIfPresent(_jsonLastError, forKey: .lastError)
        try container.encodeIfPresent(_jsonFailedGeneration, forKey: .failedGeneration)
        try container.encodeIfPresent(_jsonFailureClassification, forKey: .failureClassification)
    }

}

/// The result of converging one VM or sandbox port's security-group
/// membership. `securityGroupIds` is the desired set this result belongs to;
/// the control plane compares it with the current attachment rows before
/// applying the result so a delayed report cannot bless a newer membership.
public typealias ObservedPortMembershipState = Strato_Agent_V1_ObservedPortMembershipState
extension Strato_Agent_V1_ObservedPortMembershipState: Codable {

    public init(
        interfaceId: UUID,
        portName: String,
        securityGroupIds: [UUID],
        status: ObservedNetworkFabricStatus,
        lastError: String? = nil,
        failureClassification: ObservedFailureClassification? = nil
    ) {
        self.init()
        self._jsonInterfaceId = interfaceId
        self._jsonPortName = portName
        self._jsonSecurityGroupIds = securityGroupIds
        self._jsonStatus = status
        self._jsonLastError = lastError
        self._jsonFailureClassification = failureClassification
    }

    private enum CodingKeys: String, CodingKey {
        case interfaceId; case portName; case securityGroupIds; case status; case lastError; case failureClassification
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonInterfaceId = try container.decode(UUID.self, forKey: .interfaceId)
        self._jsonPortName = try container.decode(String.self, forKey: .portName)
        self._jsonSecurityGroupIds = try container.decode([UUID].self, forKey: .securityGroupIds)
        self._jsonStatus = try container.decode(ObservedNetworkFabricStatus.self, forKey: .status)
        self._jsonLastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        self._jsonFailureClassification = try container.decodeIfPresent(
            ObservedFailureClassification.self, forKey: .failureClassification)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonInterfaceId, forKey: .interfaceId)
        try container.encode(_jsonPortName, forKey: .portName)
        try container.encode(_jsonSecurityGroupIds, forKey: .securityGroupIds)
        try container.encode(_jsonStatus, forKey: .status)
        try container.encodeIfPresent(_jsonLastError, forKey: .lastError)
        try container.encodeIfPresent(_jsonFailureClassification, forKey: .failureClassification)
    }

}

// MARK: - Observed Load Balancer State

public typealias ObservedLoadBalancerStatus = Strato_Agent_V1_ObservedLoadBalancerStatus
extension Strato_Agent_V1_ObservedLoadBalancerStatus: Codable {

    public var protocolValue: String {
        switch self {
        case .pending: return "pending"
        case .active: return "active"
        case .error: return "error"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "pending": self = .pending
        case "active": self = .active
        case "error": self = .error
        default: return nil
        }
    }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown enum value")
        }
        self = value
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        guard !protocolValue.isEmpty else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Unknown enum value"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(protocolValue)
    }
}

public typealias ObservedLoadBalancerBackendHealth = Strato_Agent_V1_ObservedLoadBalancerBackendHealth
extension Strato_Agent_V1_ObservedLoadBalancerBackendHealth: Codable {

    public var protocolValue: String {
        switch self {
        case .unknown: return "unknown"
        case .online: return "online"
        case .offline: return "offline"
        case .error: return "error"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "unknown": self = .unknown
        case "online": self = .online
        case "offline": self = .offline
        case "error": self = .error
        default: return nil
        }
    }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown enum value")
        }
        self = value
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        guard !protocolValue.isEmpty else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Unknown enum value"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(protocolValue)
    }
}

public typealias ObservedLoadBalancerBackend = Strato_Agent_V1_ObservedLoadBalancerBackend
extension Strato_Agent_V1_ObservedLoadBalancerBackend: Codable {

    public init(
        id: UUID,
        healthStatus: ObservedLoadBalancerBackendHealth,
        lastCheckedAt: Date? = nil
    ) {
        self.init()
        self._jsonId = id
        self._jsonHealthStatus = healthStatus
        self._jsonLastCheckedAt = lastCheckedAt
    }

    private enum CodingKeys: String, CodingKey { case id; case healthStatus; case lastCheckedAt }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonId = try container.decode(UUID.self, forKey: .id)
        self._jsonHealthStatus = try container.decode(ObservedLoadBalancerBackendHealth.self, forKey: .healthStatus)
        self._jsonLastCheckedAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonId, forKey: .id)
        try container.encode(_jsonHealthStatus, forKey: .healthStatus)
        try container.encodeIfPresent(_jsonLastCheckedAt, forKey: .lastCheckedAt)
    }

}

/// What the site's single OVN author observed after reconciling one native
/// load balancer. Optional at the report level because non-authoritative and
/// pre-v43 agents have no opinion about these project-scoped rows.
public typealias ObservedLoadBalancerState = Strato_Agent_V1_ObservedLoadBalancerState
extension Strato_Agent_V1_ObservedLoadBalancerState: Codable {

    public init(
        id: UUID,
        observedGeneration: Int64,
        status: ObservedLoadBalancerStatus,
        lastError: String? = nil,
        backends: [ObservedLoadBalancerBackend] = []
    ) {
        self.init()
        self._jsonId = id
        self._jsonObservedGeneration = observedGeneration
        self._jsonStatus = status
        self._jsonLastError = lastError
        self._jsonBackends = backends
    }

    private enum CodingKeys: String, CodingKey {
        case id; case observedGeneration; case status; case lastError; case backends
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonId = try container.decode(UUID.self, forKey: .id)
        self._jsonObservedGeneration = try container.decode(Int64.self, forKey: .observedGeneration)
        self._jsonStatus = try container.decode(ObservedLoadBalancerStatus.self, forKey: .status)
        self._jsonLastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        self._jsonBackends = try container.decode([ObservedLoadBalancerBackend].self, forKey: .backends)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonId, forKey: .id)
        try container.encode(_jsonObservedGeneration, forKey: .observedGeneration)
        try container.encode(_jsonStatus, forKey: .status)
        try container.encodeIfPresent(_jsonLastError, forKey: .lastError)
        try container.encode(_jsonBackends, forKey: .backends)
    }

}

/// Agent → control plane: everything the agent actually has, with resources.
///
/// Full-list semantics mirror `DesiredStateMessage`: a VM missing from `vms`
/// does not exist on this agent, which is how deletions are confirmed. Sent
/// immediately after any convergence action and piggybacked on the heartbeat
/// cadence, so state converges quickly after changes but is also periodically
/// re-asserted.
///
/// `manifestStatus` is the one thing that suspends those semantics: an agent
/// that cannot read its manifest sends the report to carry the condition and
/// its resource snapshot, and the lists mean nothing (STR-138).
public typealias ObservedStateReport = Strato_Agent_V1_ObservedStateReport
extension Strato_Agent_V1_ObservedStateReport: WebSocketMessage {
    public var type: MessageType { .observedState }

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        agentId: String,
        vms: [ObservedVMState],
        sandboxes: [ObservedSandboxState] = [],
        resources: AgentResources,
        resourceEnforcement: ResourceEnforcementSnapshot? = nil,
        hostResourceTelemetry: HostResourceTelemetry? = nil,
        agentUpdateStatus: ObservedAgentUpdateStatus? = nil,
        unrecognized: [UnrecognizedWorkload] = [],
        teardownRefusal: ObservedTeardownRefusal? = nil,
        manifestStatus: ObservedManifestStatus? = nil,
        volumes: [ObservedVolumeState]? = nil,
        snapshots: [ObservedSnapshotState]? = nil,
        loadBalancers: [ObservedLoadBalancerState]? = nil,
        networks: [ObservedNetworkState]? = nil,
        securityGroups: [ObservedSecurityGroupState]? = nil,
        portMemberships: [ObservedPortMembershipState]? = nil,
        storageDevices: [ObservedStorageDevice]? = nil
    ) {
        self.init()
        self._jsonRequestId = requestId
        self._jsonTimestamp = timestamp
        self._jsonAgentId = agentId
        self._jsonVms = vms
        self._jsonSandboxes = sandboxes
        self._jsonResources = resources
        self._jsonResourceEnforcement = resourceEnforcement
        self._jsonHostResourceTelemetry = hostResourceTelemetry
        self._jsonAgentUpdateStatus = agentUpdateStatus
        self._jsonUnrecognized = unrecognized
        self._jsonTeardownRefusal = teardownRefusal
        self._jsonManifestStatus = manifestStatus
        self._jsonVolumes = volumes
        self._jsonSnapshots = snapshots
        self._jsonLoadBalancers = loadBalancers
        self._jsonNetworks = networks
        self._jsonSecurityGroups = securityGroups
        self._jsonPortMemberships = portMemberships
        self._jsonStorageDevices = storageDevices
    }

    private enum CodingKeys: String, CodingKey {
        case requestId; case timestamp; case agentId; case vms; case sandboxes; case resources;
        case resourceEnforcement; case hostResourceTelemetry; case agentUpdateStatus; case unrecognized;
        case teardownRefusal; case manifestStatus; case volumes; case snapshots; case loadBalancers; case networks;
        case securityGroups; case portMemberships; case storageDevices
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonRequestId = try container.decode(String.self, forKey: .requestId)
        self._jsonTimestamp = try container.decode(Date.self, forKey: .timestamp)
        self._jsonAgentId = try container.decode(String.self, forKey: .agentId)
        self._jsonVms = try container.decode([ObservedVMState].self, forKey: .vms)
        self._jsonSandboxes = try container.decode([ObservedSandboxState].self, forKey: .sandboxes)
        self._jsonResources = try container.decode(AgentResources.self, forKey: .resources)
        self._jsonResourceEnforcement = try container.decodeIfPresent(
            ResourceEnforcementSnapshot.self, forKey: .resourceEnforcement)
        self._jsonHostResourceTelemetry = try container.decodeIfPresent(
            HostResourceTelemetry.self, forKey: .hostResourceTelemetry)
        self._jsonAgentUpdateStatus = try container.decodeIfPresent(
            ObservedAgentUpdateStatus.self, forKey: .agentUpdateStatus)
        self._jsonUnrecognized = try container.decode([UnrecognizedWorkload].self, forKey: .unrecognized)
        self._jsonTeardownRefusal = try container.decodeIfPresent(
            ObservedTeardownRefusal.self, forKey: .teardownRefusal)
        self._jsonManifestStatus = try container.decodeIfPresent(ObservedManifestStatus.self, forKey: .manifestStatus)
        self._jsonVolumes = try container.decodeIfPresent([ObservedVolumeState].self, forKey: .volumes)
        self._jsonSnapshots = try container.decodeIfPresent([ObservedSnapshotState].self, forKey: .snapshots)
        self._jsonLoadBalancers = try container.decodeIfPresent(
            [ObservedLoadBalancerState].self, forKey: .loadBalancers)
        self._jsonNetworks = try container.decodeIfPresent([ObservedNetworkState].self, forKey: .networks)
        self._jsonSecurityGroups = try container.decodeIfPresent(
            [ObservedSecurityGroupState].self, forKey: .securityGroups)
        self._jsonPortMemberships = try container.decodeIfPresent(
            [ObservedPortMembershipState].self, forKey: .portMemberships)
        self._jsonStorageDevices = try container.decodeIfPresent([ObservedStorageDevice].self, forKey: .storageDevices)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonRequestId, forKey: .requestId)
        try container.encode(_jsonTimestamp, forKey: .timestamp)
        try container.encode(_jsonAgentId, forKey: .agentId)
        try container.encode(_jsonVms, forKey: .vms)
        try container.encode(_jsonSandboxes, forKey: .sandboxes)
        try container.encode(_jsonResources, forKey: .resources)
        try container.encodeIfPresent(_jsonResourceEnforcement, forKey: .resourceEnforcement)
        try container.encodeIfPresent(_jsonHostResourceTelemetry, forKey: .hostResourceTelemetry)
        try container.encodeIfPresent(_jsonAgentUpdateStatus, forKey: .agentUpdateStatus)
        try container.encode(_jsonUnrecognized, forKey: .unrecognized)
        try container.encodeIfPresent(_jsonTeardownRefusal, forKey: .teardownRefusal)
        try container.encodeIfPresent(_jsonManifestStatus, forKey: .manifestStatus)
        try container.encodeIfPresent(_jsonVolumes, forKey: .volumes)
        try container.encodeIfPresent(_jsonSnapshots, forKey: .snapshots)
        try container.encodeIfPresent(_jsonLoadBalancers, forKey: .loadBalancers)
        try container.encodeIfPresent(_jsonNetworks, forKey: .networks)
        try container.encodeIfPresent(_jsonSecurityGroups, forKey: .securityGroups)
        try container.encodeIfPresent(_jsonPortMemberships, forKey: .portMemberships)
        try container.encodeIfPresent(_jsonStorageDevices, forKey: .storageDevices)
    }

}
