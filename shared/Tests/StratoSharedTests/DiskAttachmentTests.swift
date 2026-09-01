import Foundation
import Testing
import StratoShared

@Suite("Disk attachment wire format")
struct DiskAttachmentTests {
    @Test("File attachment carries the path and declared format")
    func fileRoundTrip() throws {
        let attachment = DiskAttachment.file(path: "/var/lib/strato/volumes/v/volume.raw", format: .raw)

        #expect(try roundTrip(attachment) == attachment)
        let object = try #require(
            JSONSerialization.jsonObject(with: try encodeJSON(attachment)) as? [String: Any])
        let file = try #require(object["file"] as? [String: Any])
        #expect(file["path"] as? String == "/var/lib/strato/volumes/v/volume.raw")
        #expect(file["format"] as? String == "raw")
    }

    @Test("Block-device attachment carries no invented disk format")
    func blockDeviceRoundTrip() throws {
        let attachment = DiskAttachment.blockDevice(path: "/dev/mapper/strato-volume")

        #expect(try roundTrip(attachment) == attachment)
        let object = try #require(
            JSONSerialization.jsonObject(with: try encodeJSON(attachment)) as? [String: Any])
        let block = try #require(object["blockDevice"] as? [String: Any])
        #expect(block["path"] as? String == "/dev/mapper/strato-volume")
        #expect(block["format"] == nil)
    }

    @Test("RBD attachment carries every coordinate without a path field")
    func rbdRoundTrip() throws {
        let clusterID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let credentialID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let configPath =
            "/var/lib/strato/ceph/11111111-2222-3333-4444-555555555555/"
            + "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/ceph.conf"
        let attachment = DiskAttachment.rbd(
            pool: "volumes",
            image: "volume-1",
            namespace: "project-1",
            user: "client.project-1",
            monEndpoints: ["v2:10.0.0.10:3300", "v2:10.0.0.11:3300"],
            clusterId: clusterID,
            credentialId: credentialID,
            configPath: configPath)

        #expect(try roundTrip(attachment) == attachment)
        let object = try #require(
            JSONSerialization.jsonObject(with: try encodeJSON(attachment)) as? [String: Any])
        #expect(object["file"] == nil)
        #expect(object["blockDevice"] == nil)
        let rbd = try #require(object["rbd"] as? [String: Any])
        #expect(rbd["pool"] as? String == "volumes")
        #expect(rbd["image"] as? String == "volume-1")
        #expect(rbd["namespace"] as? String == "project-1")
        #expect(rbd["user"] as? String == "client.project-1")
        #expect(
            rbd["monEndpoints"] as? [String]
                == ["v2:10.0.0.10:3300", "v2:10.0.0.11:3300"])
        #expect(rbd["clusterId"] as? String == clusterID.uuidString)
        #expect(rbd["credentialId"] as? String == credentialID.uuidString)
        #expect(rbd["configPath"] as? String == configPath)
        #expect(rbd["path"] == nil)
        #expect(rbd["keyring"] == nil)
    }

    @Test("The same attachment value crosses both volume wire directions")
    func volumeWireCarriersRoundTrip() throws {
        let clusterID = UUID()
        let credentialID = UUID()
        let attachment = DiskAttachment.rbd(
            pool: "volumes", image: "volume-1", namespace: "project-1",
            user: "client.project-1", monEndpoints: ["v2:mon-1:3300"],
            clusterId: clusterID, credentialId: credentialID,
            configPath:
                "/var/lib/strato/ceph/\(clusterID.uuidString)/\(credentialID.uuidString)/ceph.conf")
        let volumeID = UUID()
        let spec = VolumeSpec(
            volumeId: volumeID, deviceName: .disk(0), attachment: attachment, bootOrder: 0)
        let observed = ObservedVolumeState(
            volumeId: volumeID, present: true, attachment: attachment, observedGeneration: 4)

        #expect(try roundTrip(spec).attachment == attachment)
        #expect(try roundTrip(observed).attachment == attachment)
    }
}
