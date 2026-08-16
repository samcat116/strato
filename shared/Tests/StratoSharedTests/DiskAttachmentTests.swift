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
        let attachment = DiskAttachment.rbd(
            pool: "volumes",
            image: "volume-1",
            user: "client.project-1",
            monHosts: ["10.0.0.10:6789", "10.0.0.11:6789"])

        #expect(try roundTrip(attachment) == attachment)
        let object = try #require(
            JSONSerialization.jsonObject(with: try encodeJSON(attachment)) as? [String: Any])
        #expect(object["file"] == nil)
        #expect(object["blockDevice"] == nil)
        let rbd = try #require(object["rbd"] as? [String: Any])
        #expect(rbd["pool"] as? String == "volumes")
        #expect(rbd["image"] as? String == "volume-1")
        #expect(rbd["user"] as? String == "client.project-1")
        #expect(rbd["monHosts"] as? [String] == ["10.0.0.10:6789", "10.0.0.11:6789"])
        #expect(rbd["path"] == nil)
    }

    @Test("The same attachment value crosses both volume wire directions")
    func volumeWireCarriersRoundTrip() throws {
        let attachment = DiskAttachment.rbd(
            pool: "volumes", image: "volume-1", user: "client.project-1", monHosts: ["mon-1:6789"])
        let volumeID = UUID()
        let spec = VolumeSpec(
            volumeId: volumeID, deviceName: .disk(0), attachment: attachment, bootOrder: 0)
        let observed = ObservedVolumeState(
            volumeId: volumeID, present: true, attachment: attachment, observedGeneration: 4)

        #expect(try roundTrip(spec).attachment == attachment)
        #expect(try roundTrip(observed).attachment == attachment)
    }
}
