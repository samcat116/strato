import Foundation
import SwiftProtobuf

/// Which kind of workload a reconcile work item, manifest entry, or wire-level
/// teardown record refers to (issue #417). The reconciler engine — diff,
/// per-key serial lanes, generation guard, attempt cap, failure classification
/// — is shared across kinds; only the actuation differs: VM items route to
/// hypervisor drivers, sandbox items to the sandbox runtime.
///
/// Lives in the shared package because it is also a wire discriminator
/// (STR-98): `DesiredWorkloadTombstone` and `UnrecognizedWorkload` are
/// kind-tagged, so the control plane names the same kinds the agent does
/// rather than mapping between two vocabularies.
///
/// `Codable` because the on-disk workload manifest tags each entry with its
/// kind; manifests written before sandboxes existed have no kind and decode
/// as `.vm`.
public typealias WorkloadKind = Strato_Agent_V1_WorkloadKind
extension Strato_Agent_V1_WorkloadKind: Codable {

    /// Whether this kind names a snapshot artifact rather than a live
    /// workload. Artifacts are frozen bytes with a parent — they never boot,
    /// never hold a runtime session, and are enumerated from what the capturing
    /// backend wrote rather than from the manifest.
    public var isSnapshotArtifact: Bool {
        switch self {
        case .vm, .sandbox, .volume: return false
        case .volumeSnapshot, .vmCheckpoint, .sandboxSnapshot: return true
        case .unspecified, .UNRECOGNIZED: return false
        }
    }

    public var protocolValue: String {
        switch self {
        case .vm: return "vm"
        case .sandbox: return "sandbox"
        case .volume: return "volume"
        case .volumeSnapshot: return "volume_snapshot"
        case .vmCheckpoint: return "vm_checkpoint"
        case .sandboxSnapshot: return "sandbox_snapshot"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "vm": self = .vm
        case "sandbox": self = .sandbox
        case "volume": self = .volume
        case "volume_snapshot": self = .volumeSnapshot
        case "vm_checkpoint": self = .vmCheckpoint
        case "sandbox_snapshot": self = .sandboxSnapshot
        default: return nil
        }
    }

    public static var knownCases: [Self] { [.vm, .sandbox, .volume, .volumeSnapshot, .vmCheckpoint, .sandboxSnapshot] }

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
