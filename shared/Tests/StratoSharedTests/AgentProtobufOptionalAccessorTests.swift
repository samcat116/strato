import Foundation
import StratoShared
import SwiftProtobuf
import Testing

@Suite("Native Protobuf optional accessors")
struct AgentProtobufOptionalAccessorTests {
    @Test("Absent scalars remain distinct from explicitly supplied defaults")
    func scalarPresence() throws {
        var value = VMSpec()
        #expect(value.optionalCpus == nil)
        #expect(value.optionalGuestAgentEnabled == nil)
        #expect(value.optionalUserData == nil)
        value.optionalCpus = 0
        value.optionalGuestAgentEnabled = false
        value.optionalUserData = ""
        let restored = try VMSpec(serializedBytes: value.serializedData())
        #expect(restored.optionalCpus == 0)
        #expect(restored.optionalGuestAgentEnabled == false)
        #expect(restored.optionalUserData == "")
        value.optionalCpus = nil
        value.optionalGuestAgentEnabled = nil
        value.optionalUserData = nil
        #expect(!value.hasCpus && !value.hasGuestAgentEnabled && !value.hasUserData)
    }

    @Test("Present empty wrappers stay authoritative until explicitly cleared")
    func collectionPresence() throws {
        var value = DesiredStateMessage()
        #expect(value.optionalSecurityGroups == nil)
        value.optionalSecurityGroups = .init()
        let restored = try DesiredStateMessage(serializedBytes: value.serializedData())
        #expect(restored.optionalSecurityGroups?.values == [])
        value.optionalSecurityGroups = nil
        #expect(!value.hasSecurityGroups)
    }

    @Test("Native message accessors retain unknown fields when read modified and reassigned")
    func unknownNestedFields() throws {
        let futureField = Data([0xc0, 0x0c, 0x01])  // field 200, varint 1
        let nested = try VMSpec(serializedBytes: futureField)
        var value = DesiredVMState()
        value.optionalSpec = nested
        var read = try #require(value.optionalSpec)
        read.optionalCpus = 2
        value.optionalSpec = read
        let restored = try DesiredVMState(serializedBytes: value.serializedData())
        #expect(restored.optionalSpec?.unknownFields == nested.unknownFields)
        #expect(restored.optionalSpec?.optionalCpus == 2)
        value.optionalSpec = nil
        #expect(!value.hasSpec)
    }
}
