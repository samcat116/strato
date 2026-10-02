import Foundation
import Testing
@testable import StratoShared

@Suite("Guest configuration contract")
struct GuestConfigTests {
    private var config: GuestConfig {
        GuestConfig(
            packages: [GuestPackage(name: "curl", state: .present), GuestPackage(name: "telnet", state: .absent)],
            files: [GuestFile(path: "/etc/example.conf", content: "hello\n", mode: "0644")],
            services: [GuestService(name: "example.service", enabled: true)],
            sysctls: [GuestSysctl(key: "net.ipv4.ip_forward", value: "1")])
    }

    @Test func roundTripAndGeneration() throws {
        let desired = DesiredVMState(
            vmId: UUID(), hypervisorType: .qemu,
            spec: VMSpec(cpus: 2, memoryBytes: 1024, boot: .disk(firmware: nil)),
            desiredStatus: .running, generation: 19, guestConfig: config)
        let message = DesiredStateMessage(vms: [desired])
        let decoded = try MessageEnvelope(message: message).decode(as: DesiredStateMessage.self)
        #expect(decoded.vms[0].guestConfig == config)
        #expect(decoded.vms[0].generation == 19)
    }

    @Test func olderPayloadAndNullAreInert() throws {
        let desired = DesiredVMState(
            vmId: UUID(), hypervisorType: .qemu,
            spec: VMSpec(cpus: 2, memoryBytes: 1024, boot: .disk(firmware: nil)),
            desiredStatus: .running, generation: 3)
        let encoded = try WireProtocol.makeEncoder().encode(desired)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["guestConfig"] == nil)
        for null in [false, true] {
            if null { json["guestConfig"] = NSNull() }
            let data = try JSONSerialization.data(withJSONObject: json)
            let decoded = try WireProtocol.makeDecoder().decode(DesiredVMState.self, from: data)
            #expect(decoded.guestConfig == nil)
            #expect(decoded.generation == 3)
        }
    }

    @Test func requiredSectionsAndUnknownFields() throws {
        for payload in [
            #"{}"#,
            #"{"packages":[],"files":[],"services":[]}"#,
            #"{"packages":[],"files":[],"services":[],"sysctls":[],"commands":[]}"#,
            #"{"packages":[{"name":"curl","state":"latest"}],"files":[],"services":[],"sysctls":[]}"#,
            #"{"packages":[],"files":[],"services":[{"name":"x","enabled":true,"command":"secret"}],"sysctls":[]}"#,
        ] {
            #expect(throws: (any Error).self) {
                try WireProtocol.makeDecoder().decode(GuestConfig.self, from: Data(payload.utf8))
            }
        }
    }

    @Test func invalidIntentFailsBothBoundaries() throws {
        let invalid = [
            GuestConfig(packages: [GuestPackage(name: "-flag", state: .present)]),
            GuestConfig(packages: [GuestPackage(name: "a;id", state: .present)]),
            GuestConfig(packages: [GuestPackage(name: "x", state: .present), GuestPackage(name: "x", state: .absent)]),
            GuestConfig(files: [GuestFile(path: "/etc/../secret", content: "", mode: "0644")]),
            GuestConfig(files: [GuestFile(path: "relative", content: "", mode: "0644")]),
            GuestConfig(files: [GuestFile(path: "/etc//x", content: "", mode: "0644")]),
            GuestConfig(files: [GuestFile(path: "/", content: "", mode: "0644")]),
            GuestConfig(files: [GuestFile(path: "/etc/x", content: "", mode: "4755")]),
            GuestConfig(files: [GuestFile(path: "/etc/x", content: "\0", mode: "0644")]),
            GuestConfig(services: [GuestService(name: "x\nsecret", enabled: false)]),
            GuestConfig(sysctls: [GuestSysctl(key: "net..x", value: "1")]),
            GuestConfig(sysctls: [GuestSysctl(key: "net.x", value: "1\nsecret")]),
        ]
        for value in invalid {
            #expect(throws: GuestConfigValidationError.self) { try value.validate() }
            #expect(throws: GuestConfigValidationError.self) { try WireProtocol.makeEncoder().encode(value) }
        }
        let payload =
            #"{"packages":[],"files":[{"path":"/../secret","content":"private-content","mode":"0644"}],"services":[],"sysctls":[]}"#
        do {
            _ = try WireProtocol.makeDecoder().decode(GuestConfig.self, from: Data(payload.utf8))
            Issue.record("Invalid path was accepted")
        } catch {
            #expect(!String(describing: error).contains("private-content"))
            #expect(!String(describing: error).contains("/../secret"))
        }
    }

    @Test func boundariesAndEmptyIntent() throws {
        try GuestConfig().validate()
        let files = (0..<4).map {
            GuestFile(
                path: "/etc/test\($0)", content: String(repeating: "a", count: GuestConfig.maxFileBytes), mode: "0600")
        }
        try GuestConfig(files: files).validate()
        #expect(throws: GuestConfigValidationError.self) {
            try GuestConfig(files: files + [GuestFile(path: "/etc/extra", content: "a", mode: "0600")]).validate()
        }
        #expect(throws: GuestConfigValidationError.self) {
            try GuestConfig(files: [
                GuestFile(path: "/etc/x", content: String(repeating: "é", count: 32769), mode: "0600")
            ]).validate()
        }
        let packages = (0..<128).map { GuestPackage(name: "package\($0)", state: .present) }
        try GuestConfig(packages: packages).validate()
        #expect(throws: GuestConfigValidationError.self) {
            try GuestConfig(packages: packages + [GuestPackage(name: "extra", state: .present)]).validate()
        }
    }
}
