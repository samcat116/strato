import Foundation
import Testing
import StratoShared

@Suite("Volume operation messages")
struct VolumeMessageTests {
    @Test func volumeCreateRoundTrip() throws {
        let decoded = try throughEnvelope(
            VolumeCreateMessage(
                requestId: Fixtures.requestId,
                timestamp: Fixtures.timestamp,
                volumeId: "vol-1",
                size: 10_737_418_240,
                format: "raw",
                sourceImageInfo: Fixtures.imageInfo,
                sourceVolumePath: "/var/lib/strato/base.qcow2"
            )
        )
        #expect(decoded.type == .volumeCreate)
        #expect(decoded.volumeId == "vol-1")
        #expect(decoded.size == 10_737_418_240)
        #expect(decoded.format == "raw")
        #expect(decoded.sourceImageInfo?.imageId == Fixtures.imageInfo.imageId)
        #expect(decoded.sourceVolumePath == "/var/lib/strato/base.qcow2")
    }

    @Test func volumeDeleteRoundTrip() throws {
        let decoded = try throughEnvelope(
            VolumeDeleteMessage(requestId: Fixtures.requestId, timestamp: Fixtures.timestamp, volumeId: "vol-1", volumePath: "/var/lib/strato/vol-1.qcow2")
        )
        #expect(decoded.type == .volumeDelete)
        #expect(decoded.volumeId == "vol-1")
        #expect(decoded.volumePath == "/var/lib/strato/vol-1.qcow2")
    }

    @Test func volumeAttachRoundTrip() throws {
        let decoded = try throughEnvelope(
            VolumeAttachMessage(
                requestId: Fixtures.requestId,
                timestamp: Fixtures.timestamp,
                vmId: "vm-1",
                volumeId: "vol-1",
                volumePath: "/var/lib/strato/vol-1.qcow2",
                deviceName: "disk1",
                readonly: true
            )
        )
        #expect(decoded.type == .volumeAttach)
        #expect(decoded.vmId == "vm-1")
        #expect(decoded.volumeId == "vol-1")
        #expect(decoded.deviceName == "disk1")
        #expect(decoded.readonly)
    }

    @Test func volumeDetachRoundTrip() throws {
        let decoded = try throughEnvelope(
            VolumeDetachMessage(requestId: Fixtures.requestId, timestamp: Fixtures.timestamp, vmId: "vm-1", volumeId: "vol-1", deviceName: "disk1")
        )
        #expect(decoded.type == .volumeDetach)
        #expect(decoded.deviceName == "disk1")
    }

    @Test func volumeResizeRoundTrip() throws {
        let decoded = try throughEnvelope(
            VolumeResizeMessage(
                requestId: Fixtures.requestId,
                timestamp: Fixtures.timestamp,
                volumeId: "vol-1",
                volumePath: "/var/lib/strato/vol-1.qcow2",
                newSize: 21_474_836_480
            )
        )
        #expect(decoded.type == .volumeResize)
        #expect(decoded.newSize == 21_474_836_480)
    }

    @Test func volumeSnapshotRoundTrip() throws {
        let decoded = try throughEnvelope(
            VolumeSnapshotMessage(
                requestId: Fixtures.requestId,
                timestamp: Fixtures.timestamp,
                volumeId: "vol-1",
                snapshotId: "snap-1",
                volumePath: "/var/lib/strato/vol-1.qcow2",
                snapshotPath: "/var/lib/strato/snap-1.qcow2"
            )
        )
        #expect(decoded.type == .volumeSnapshot)
        #expect(decoded.snapshotId == "snap-1")
        #expect(decoded.snapshotPath == "/var/lib/strato/snap-1.qcow2")
    }

    @Test func volumeCloneRoundTrip() throws {
        let decoded = try throughEnvelope(
            VolumeCloneMessage(
                requestId: Fixtures.requestId,
                timestamp: Fixtures.timestamp,
                sourceVolumeId: "vol-1",
                sourceVolumePath: "/var/lib/strato/vol-1.qcow2",
                targetVolumeId: "vol-2",
                targetVolumePath: "/var/lib/strato/vol-2.qcow2"
            )
        )
        #expect(decoded.type == .volumeClone)
        #expect(decoded.sourceVolumeId == "vol-1")
        #expect(decoded.targetVolumeId == "vol-2")
        #expect(decoded.targetVolumePath == "/var/lib/strato/vol-2.qcow2")
    }

    @Test func volumeInfoRoundTrip() throws {
        let decoded = try throughEnvelope(
            VolumeInfoMessage(requestId: Fixtures.requestId, timestamp: Fixtures.timestamp, volumeId: "vol-1", volumePath: "/var/lib/strato/vol-1.qcow2")
        )
        #expect(decoded.type == .volumeInfo)
        #expect(decoded.volumeId == "vol-1")
    }

    @Test func volumeStatusRoundTrip() throws {
        let decoded = try throughEnvelope(
            VolumeStatusMessage(requestId: Fixtures.requestId, timestamp: Fixtures.timestamp, volumeId: "vol-1")
        )
        #expect(decoded.type == .volumeStatus)
        #expect(decoded.volumeId == "vol-1")
    }

    @Test func volumeInfoResponseRoundTrip() throws {
        let decoded = try roundTrip(
            VolumeInfoResponse(volumeId: "vol-1", actualSize: 1_234_567, virtualSize: 10_737_418_240, format: "qcow2", dirty: true, encrypted: true)
        )
        #expect(decoded.volumeId == "vol-1")
        #expect(decoded.actualSize == 1_234_567)
        #expect(decoded.virtualSize == 10_737_418_240)
        #expect(decoded.format == "qcow2")
        #expect(decoded.dirty)
        #expect(decoded.encrypted)
    }

    @Test func volumeStatusResponseRoundTrip() throws {
        let decoded = try roundTrip(VolumeStatusResponse(volumeId: "vol-1", status: "creating", storagePath: nil))
        #expect(decoded.volumeId == "vol-1")
        #expect(decoded.status == "creating")
        #expect(decoded.storagePath == nil)
    }
}
