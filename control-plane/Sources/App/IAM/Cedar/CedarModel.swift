import Foundation

// IAM phase 3 (issue #480): the Cedar data model — entity type names, entity
// UIDs, and the JSON encodings the cedar-policy engine consumes. These types
// are engine-independent on purpose: the Swift↔Cedar binding
// (samcat116/swift-cedar) takes Cedar's standard JSON formats at its boundary,
// so everything here plugs in unchanged when the engine lands (#481).

/// The Cedar entity types. One per `IAMNodeType`, plus the two principal
/// types.
///
/// `organizational_unit` maps to `Folder`: the Cedar schema is new, so it uses
/// the target vocabulary from day one (docs/architecture/iam.md — the OU →
/// folder rename ships its API/database leg with cutover, but nothing is
/// gained by churning a brand-new schema through the old name).
enum CedarEntityType: String, CaseIterable, Sendable {
    case user = "User"
    case group = "Group"
    /// A directly registered SPIFFE workload identity (issue #491) — a
    /// principal-only type, like `User` and `Group`.
    case workload = "Workload"
    case organization = "Organization"
    case folder = "Folder"
    case project = "Project"
    case vm = "VM"
    case sandbox = "Sandbox"
    case image = "Image"
    case network = "Network"
    case floatingIP = "FloatingIP"
    case volume = "Volume"
    case volumeSnapshot = "VolumeSnapshot"
    case sandboxSnapshot = "SandboxSnapshot"
    case site = "Site"
    case agent = "Agent"
    /// Both a node type (a project-scoped resource with `serviceaccount:*`
    /// actions, including `impersonate`) and a principal type (issue #491).
    case serviceAccount = "ServiceAccount"

    /// The types a role binding or guardrail node can be — every entity type
    /// except the principals.
    static let nodeTypes: [CedarEntityType] = IAMNodeType.allCases.map(\.cedarEntityType)

    /// The tree-node type this entity type stands for, or nil for a
    /// principal-only type (`User`, `Group`, `Workload`) that names no place in
    /// the resource tree. `ServiceAccount` is both, and resolves to its node
    /// type here. The reverse of `IAMNodeType.cedarEntityType`; used to map an
    /// authored policy's resource scope back onto the tree for containment
    /// (issue #606).
    var nodeType: IAMNodeType? {
        IAMNodeType.allCases.first { $0.cedarEntityType == self }
    }
}

extension IAMNodeType {
    /// The Cedar entity type standing for this tree-node type.
    var cedarEntityType: CedarEntityType {
        switch self {
        case .organization: return .organization
        case .organizationalUnit: return .folder
        case .project: return .project
        case .virtualMachine: return .vm
        case .sandbox: return .sandbox
        case .image: return .image
        case .network: return .network
        case .floatingIP: return .floatingIP
        case .volume: return .volume
        case .volumeSnapshot: return .volumeSnapshot
        case .sandboxSnapshot: return .sandboxSnapshot
        case .site: return .site
        case .agent: return .agent
        case .serviceAccount: return .serviceAccount
        }
    }
}

extension IAMPrincipalType {
    /// The Cedar entity type standing for this principal type.
    var cedarEntityType: CedarEntityType {
        switch self {
        case .user: return .user
        case .group: return .group
        case .serviceAccount: return .serviceAccount
        case .workload: return .workload
        }
    }
}

/// A Cedar entity UID — `Type::"id"`.
///
/// Ids are lowercased UUID strings everywhere, made uniform here: UIDs appear
/// both in loaded entity data and embedded in compiled policy text (guardrail
/// forbids name their attach node), and Cedar compares them as opaque strings,
/// so one site with mixed case would silently never match.
struct CedarEntityUID: Hashable, Sendable, Encodable {
    let type: String
    let id: String

    init(type: CedarEntityType, id: UUID) {
        self.type = type.rawValue
        self.id = id.uuidString.lowercased()
    }

    /// The UID as it appears in policy text.
    var cedarLiteral: String {
        "\(type)::\(CedarText.stringLiteral(id))"
    }
}

extension IAMNode {
    var cedarUID: CedarEntityUID {
        CedarEntityUID(type: type.cedarEntityType, id: id)
    }
}

extension IAMPrincipal {
    var cedarUID: CedarEntityUID {
        CedarEntityUID(type: type.cedarEntityType, id: id)
    }
}

/// A Cedar attribute/context value, encoding to Cedar's JSON value format
/// (entity references use the explicit `__entity` escape).
indirect enum CedarValue: Equatable, Sendable, Encodable {
    case bool(Bool)
    case long(Int64)
    case string(String)
    case entity(CedarEntityUID)
    case set([CedarValue])
    case record([String: CedarValue])

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .long(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .entity(let uid):
            var container = encoder.container(keyedBy: EntityEscapeKey.self)
            try container.encode(uid, forKey: .entity)
        case .set(let values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case .record(let fields):
            var container = encoder.container(keyedBy: StringKey.self)
            for (key, value) in fields {
                try container.encode(value, forKey: StringKey(key))
            }
        }
    }

    private enum EntityEscapeKey: String, CodingKey {
        case entity = "__entity"
    }

    private struct StringKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { self.stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// One entity in Cedar's entities JSON format: `{ uid, attrs, parents }`.
struct CedarEntity: Equatable, Sendable, Encodable {
    let uid: CedarEntityUID
    let attrs: [String: CedarValue]
    let parents: [CedarEntityUID]
}

/// Shared text-rendering helpers for schema and policy generation.
enum CedarText {
    /// A Cedar string literal with the characters Cedar escapes.
    static func stringLiteral(_ value: String) -> String {
        var escaped = ""
        for character in value.unicodeScalars {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case "\0": escaped += "\\0"
            default: escaped.unicodeScalars.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    /// Deterministic JSON for entities and context values: stable key order so
    /// tests, logs, and shadow-eval diffs (#481) compare byte-for-byte.
    static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
