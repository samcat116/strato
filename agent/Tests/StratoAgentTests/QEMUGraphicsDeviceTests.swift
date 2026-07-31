import StratoShared
import Testing

@testable import StratoAgentCore

/// The graphics command line (issue #566) is assembled where QEMU's own
/// validation cannot be reached: SwiftQEMU discards the stderr on which QEMU
/// reports a bad device line, so the failure reaches the operator as a QMP
/// connect timeout. These assertions stand in for that validation. The shapes
/// below were verified against QEMU 10.1.0, which starts on this vector and
/// answers `RFB 003.008` on the resulting socket.
@Suite("QEMU graphics device arguments")
struct QEMUGraphicsDeviceTests {

    private func arguments(_ architecture: CPUArchitecture) -> [String] {
        QEMUGraphicsDevice.arguments(vncSocketPath: "/vms/abc/vnc.sock", architecture: architecture)
    }

    /// `-vnc` is a display backend, so it is what exports the framebuffer;
    /// `-display none` keeps QEMU from also opening a local window.
    @Test("the VNC server is exported on the VM's own Unix socket", arguments: CPUArchitecture.allCases)
    func vncIsBoundToTheUnixSocket(architecture: CPUArchitecture) throws {
        let args = arguments(architecture)
        let vncIndex = try #require(args.firstIndex(of: "-vnc"))
        #expect(args[vncIndex + 1] == "unix:/vms/abc/vnc.sock")

        let displayIndex = try #require(args.firstIndex(of: "-display"))
        #expect(args[displayIndex + 1] == "none")
    }

    /// A TCP listener would put an unauthenticated RFB server (there is no VNC
    /// password) on the hypervisor node's network, bypassing every check the
    /// control plane makes. The socket must stay a Unix socket.
    @Test("the VNC server never listens on TCP", arguments: CPUArchitecture.allCases)
    func vncIsNeverATCPListener(architecture: CPUArchitecture) throws {
        let args = arguments(architecture)
        let target = try #require(args.firstIndex(of: "-vnc").map { args[$0 + 1] })
        #expect(target.hasPrefix("unix:"))
    }

    /// `-nographic` forces `-display none` and would fight the `-vnc` display
    /// backend; the caller drops it for a graphics VM, so it must not reappear
    /// from here.
    @Test("-nographic is never emitted", arguments: CPUArchitecture.allCases)
    func nographicIsNeverEmitted(architecture: CPUArchitecture) {
        #expect(!arguments(architecture).contains("-nographic"))
    }

    /// Standard VGA is what a guest with no driver loaded can draw on — UEFI,
    /// GRUB, Windows Setup — and `-vga std` selects the default adapter rather
    /// than adding a second VGA device, which QEMU refuses to start with.
    @Test("x86 gets standard VGA and no virtio display")
    func x86UsesStandardVGA() throws {
        let args = arguments(.x86_64)
        let vgaIndex = try #require(args.firstIndex(of: "-vga"))
        #expect(args[vgaIndex + 1] == "std")
        #expect(!args.contains("virtio-gpu-pci"))
    }

    /// The arm64 `virt` machine creates no display device at all, so one has to
    /// be added explicitly — and there is no `-vga` on that machine to do it.
    @Test("arm64 gets an explicit virtio-gpu and no -vga")
    func arm64AddsAnExplicitDisplayDevice() throws {
        let args = arguments(.arm64)
        let deviceIndex = try #require(args.firstIndex(of: "virtio-gpu-pci"))
        #expect(args[deviceIndex - 1] == "-device")
        #expect(!args.contains("-vga"))
    }

    /// Absolute pointer positioning is what makes a graphical installer
    /// clickable from a browser; a relative pointer drifts out of sync with the
    /// client's cursor.
    @Test("a USB tablet is plugged into an explicit controller", arguments: CPUArchitecture.allCases)
    func tabletIsPinnedToItsController(architecture: CPUArchitecture) throws {
        let args = arguments(architecture)
        let controllerIndex = try #require(
            args.firstIndex(of: "\(QEMUGraphicsDevice.usbControllerModel),id=\(QEMUGraphicsDevice.usbControllerID)"))
        #expect(args[controllerIndex - 1] == "-device")

        // q35 starts with USB off and virt has no controller at all, so the
        // tablet has to name the bus it sits on — and the controller has to be
        // declared before the device referencing it.
        let tabletIndex = try #require(
            args.firstIndex(of: "usb-tablet,bus=\(QEMUGraphicsDevice.usbControllerID).0"))
        #expect(args[tabletIndex - 1] == "-device")
        #expect(controllerIndex < tabletIndex)
    }

    /// The path the agent hands to QEMU and the path it later reconnects to for
    /// a re-adopted VM are the same derivation, so they cannot drift.
    @Test("the socket path is derived from the VM directory")
    func socketPathIsDeterministic() {
        #expect(
            QEMUGraphicsDevice.socketPath(vmDirectory: "/var/lib/strato/vms/abc") == "/var/lib/strato/vms/abc/vnc.sock")
    }
}
