import Foundation
import Testing
import StratoShared

@Suite("Desired volume storage wire format")
struct DesiredVolumeStorageTests {
    private let clusterID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let credentialID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    private var cephConfiguration: CephVolumeStorage {
        CephVolumeStorage(
            clusterId: clusterID,
            fsid: "c9cf6308-7d40-4f86-871b-37106754d7c4",
            pool: "strato-volumes",
            namespace: "project-1",
            clientName: "client.strato-project-1",
            monEndpoints: ["v2:10.0.0.10:3300", "v2:10.0.0.11:3300"],
            credentialId: credentialID,
            keyring: "[client.strato-project-1]\nkey = AQB-example-only",
            messengerMode: .secure)
    }

    @Test("Local storage has a payload-free tagged representation")
    func localWireShape() throws {
        let storage = DesiredVolumeStorage.local
        #expect(try roundTrip(storage) == storage)

        let object = try #require(
            JSONSerialization.jsonObject(with: try encodeJSON(storage)) as? [String: Any])
        #expect(Set(object.keys) == ["local"])
        #expect((object["local"] as? [String: Any])?.isEmpty == true)
    }

    @Test("Ceph storage carries the complete scoped client configuration")
    func cephWireShape() throws {
        let storage = DesiredVolumeStorage.ceph(cephConfiguration)
        #expect(try roundTrip(storage) == storage)

        let object = try #require(
            JSONSerialization.jsonObject(with: try encodeJSON(storage)) as? [String: Any])
        #expect(Set(object.keys) == ["ceph"])
        let ceph = try #require(object["ceph"] as? [String: Any])
        #expect(ceph["_0"] == nil)
        #expect(ceph["clusterId"] as? String == clusterID.uuidString)
        #expect(ceph["fsid"] as? String == "c9cf6308-7d40-4f86-871b-37106754d7c4")
        #expect(ceph["pool"] as? String == "strato-volumes")
        #expect(ceph["namespace"] as? String == "project-1")
        #expect(ceph["clientName"] as? String == "client.strato-project-1")
        #expect(
            ceph["monEndpoints"] as? [String]
                == ["v2:10.0.0.10:3300", "v2:10.0.0.11:3300"])
        #expect(ceph["credentialId"] as? String == credentialID.uuidString)
        #expect(
            ceph["keyring"] as? String
                == "[client.strato-project-1]\nkey = AQB-example-only")
        #expect(ceph["messengerMode"] as? String == "secure")
    }

    @Test("Desired volume state emits its storage selection")
    func desiredVolumeCarriesStorage() throws {
        let desired = DesiredVolumeState(
            volumeId: UUID(),
            desiredStatus: .present,
            generation: 7,
            sizeBytes: 10 << 30,
            format: "raw",
            storage: .ceph(cephConfiguration))

        #expect(try encodedKeys(desired).contains("storage"))
        #expect(try roundTrip(desired).storage == .ceph(cephConfiguration))
    }

    @Test("A persisted pre-v53 desired volume defaults to local storage")
    func missingStorageDefaultsToLocal() throws {
        let json = """
            {
              "volumeId": "\(UUID().uuidString)",
              "desiredStatus": "Present",
              "generation": 3,
              "sizeBytes": 10737418240,
              "format": "qcow2"
            }
            """

        #expect(try decodeJSON(DesiredVolumeState.self, from: json).storage == .local)
    }

    @Test("The contract has no plaintext Ceph messenger mode")
    func insecureMessengerModeIsRejected() throws {
        let data = try encodeJSON(DesiredVolumeStorage.ceph(cephConfiguration))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var ceph = try #require(object["ceph"] as? [String: Any])
        ceph["messengerMode"] = "crc"

        #expect(throws: DecodingError.self) {
            try decodeJSON(DesiredVolumeStorage.self, from: ["ceph": ceph].jsonData())
        }
    }
}

private extension Dictionary where Key == String, Value == Any {
    func jsonData() throws -> Data {
        try JSONSerialization.data(withJSONObject: self)
    }
}
