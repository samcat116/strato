/// The virtio-balloon device every QEMU VM is spawned with (issue #567),
/// expressed as QEMU command-line arguments.
///
/// This lives in the core library rather than beside the rest of the QEMU
/// command line in `QEMUService`, which links SwiftQEMU and therefore has no
/// unit tests: issue #740 was an invalid device line that QEMU rejected during
/// setup, killing *every* VM boot on the host while surfacing only as a QMP
/// connect timeout. Assembling it here keeps the shape under test.
public enum QEMUBalloonDevice {

    /// The QOM id the device is attached under, which gives the stats probe a
    /// deterministic `/machine/peripheral/<id>` path.
    public static let deviceID = "balloon0"

    /// The iothread that processes free-page hints. QEMU requires one whenever
    /// `free-page-hint=on` — hint processing runs off the main loop — and
    /// refuses to start without it:
    ///
    ///     'free-page-hint' requires 'iothread' to be set
    ///
    /// One iothread per VM is the cost of the feature; the alternative is
    /// dropping free-page hinting entirely.
    public static let ioThreadID = "\(deviceID)-iothread"

    /// The `-object`/`-device` pair to append to a VM's command line. The
    /// iothread is declared first so QEMU has it interned by the time the
    /// device references it.
    public static var arguments: [String] {
        [
            "-object", "iothread,id=\(ioThreadID)",
            "-device", "virtio-balloon-pci,id=\(deviceID),free-page-hint=on,iothread=\(ioThreadID)",
        ]
    }

    /// The QOM path the balloon device answers `qom-get`/`qom-set` on.
    public static var qomPath: String { "/machine/peripheral/\(deviceID)" }
}
