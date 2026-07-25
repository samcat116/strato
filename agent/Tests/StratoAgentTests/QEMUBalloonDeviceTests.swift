import Testing

@testable import StratoAgentCore

/// The virtio-balloon command line (issue #567) is what every QEMU VM on the
/// host boots with, so an invalid device line takes the whole hypervisor down
/// (issue #740) — and QEMU reports it only on the stderr SwiftQEMU discards.
/// These assertions stand in for QEMU's own argument validation.
@Suite("QEMU balloon device arguments")
struct QEMUBalloonDeviceTests {

    /// QEMU's `virtio_balloon_device_realize` errors out with
    /// "'free-page-hint' requires 'iothread' to be set" when the feature is on
    /// without an iothread, so the two must always ship together.
    @Test("free-page hinting is paired with an iothread")
    func freePageHintCarriesIOThread() throws {
        let args = QEMUBalloonDevice.arguments
        let device = try #require(args.first { $0.hasPrefix("virtio-balloon-pci") })
        #expect(device.contains("free-page-hint=on"))
        #expect(device.contains("iothread=\(QEMUBalloonDevice.ioThreadID)"))
    }

    /// QEMU resolves `iothread=` against objects already created, so the
    /// `-object` has to precede the `-device` on the command line.
    @Test("the iothread object is declared before the device that references it")
    func ioThreadPrecedesDevice() throws {
        let args = QEMUBalloonDevice.arguments
        let objectIndex = try #require(args.firstIndex(of: "iothread,id=\(QEMUBalloonDevice.ioThreadID)"))
        let deviceIndex = try #require(args.firstIndex { $0.hasPrefix("virtio-balloon-pci") })
        #expect(objectIndex < deviceIndex)
        #expect(args[objectIndex - 1] == "-object")
        #expect(args[deviceIndex - 1] == "-device")
    }

    /// The stats probe addresses the device by QOM path, which is derived from
    /// the `id=` the command line assigns it — they cannot drift apart.
    @Test("the device id matches the QOM path the stats probe uses")
    func deviceIDMatchesQOMPath() throws {
        let args = QEMUBalloonDevice.arguments
        let device = try #require(args.first { $0.hasPrefix("virtio-balloon-pci") })
        #expect(device.contains("id=\(QEMUBalloonDevice.deviceID)"))
        #expect(QEMUBalloonDevice.qomPath == "/machine/peripheral/\(QEMUBalloonDevice.deviceID)")
    }
}
