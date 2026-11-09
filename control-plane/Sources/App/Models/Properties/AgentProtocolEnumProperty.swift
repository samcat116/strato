import Fluent
import Foundation
import StratoShared

/// Protobuf uses numeric tags, while existing PostgreSQL enums and API JSON
/// retain their published string spellings. Only the persistence boundary
/// translates those spellings; model values remain generated enums.
protocol AgentProtocolEnumValue: Codable, Sendable {
    var protocolValue: String { get }
    init?(rawValue: String)
}

extension Fields {
    typealias ProtocolEnum<Value: AgentProtocolEnumValue> = AgentProtocolEnumProperty<Self, Value>
}

@propertyWrapper
final class AgentProtocolEnumProperty<Model: Fields, Value: AgentProtocolEnumValue> {
    let field: FieldProperty<Model, String>

    init(key: FieldKey) { field = .init(key: key) }

    var projectedValue: AgentProtocolEnumProperty<Model, Value> { self }
    var wrappedValue: Value {
        get {
            guard let value else { preconditionFailure("Protocol enum field is not initialized: \(field.key)") }
            return value
        }
        set { value = newValue }
    }
}

extension AgentProtocolEnumProperty: AnyProperty, Property {
    var value: Value? {
        get { field.value.flatMap(Value.init(rawValue:)) }
        set { field.value = newValue?.protocolValue }
    }
}

extension AgentProtocolEnumProperty: AnyQueryableProperty, QueryableProperty {
    var path: [FieldKey] { field.path }
    static func queryValue(_ value: Value) -> DatabaseQuery.Value { .enumCase(value.protocolValue) }
}

extension AgentProtocolEnumProperty: AnyQueryAddressableProperty, QueryAddressableProperty {
    var anyQueryableProperty: any AnyQueryableProperty { self }
    var queryablePath: [FieldKey] { path }
    var queryableProperty: AgentProtocolEnumProperty<Model, Value> { self }
}

extension AgentProtocolEnumProperty: AnyDatabaseProperty {
    var keys: [FieldKey] { field.keys }

    func input(to input: any DatabaseInput) {
        field.input(to: ProtocolEnumInput(base: input))
    }

    private struct ProtocolEnumInput: DatabaseInput {
        let base: any DatabaseInput
        var wantsUnmodifiedKeys: Bool { base.wantsUnmodifiedKeys }
        func set(_ value: DatabaseQuery.Value, at key: FieldKey) {
            if case .bind(let spelling as String) = value {
                base.set(.enumCase(spelling), at: key)
            } else {
                base.set(value, at: key)
            }
        }
    }

    func output(from output: any DatabaseOutput) throws {
        try field.output(from: output)
        if let spelling = field.value, Value(rawValue: spelling) == nil {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Unknown persisted protocol enum at \(field.key)"))
        }
    }
}

extension AgentProtocolEnumProperty: AnyCodableProperty {
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }

    func decode(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try container.decode(Value.self)
    }
}

extension ArtifactKind: AgentProtocolEnumValue {}

extension CPUArchitecture: AgentProtocolEnumValue {}

extension DesiredSandboxStatus: AgentProtocolEnumValue {}

extension DesiredSnapshotStatus: AgentProtocolEnumValue {}

extension DesiredVMStatus: AgentProtocolEnumValue {}

extension DesiredVolumeStatus: AgentProtocolEnumValue {}

extension HypervisorType: AgentProtocolEnumValue {}

extension MetadataSource: AgentProtocolEnumValue {}

extension SandboxSnapshotMode: AgentProtocolEnumValue {}

extension SandboxStatus: AgentProtocolEnumValue {}

extension StorageDeviceState: AgentProtocolEnumValue {}

extension VMStatus: AgentProtocolEnumValue {}

extension VolumeBlockMode: AgentProtocolEnumValue {}
