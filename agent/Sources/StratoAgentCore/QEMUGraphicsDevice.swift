import Foundation
import StratoShared

/// The display half of a QEMU VM's command line (issue #566): the framebuffer
/// device, the VNC server that exports it, and the pointer that makes it
/// usable from a browser.
///
/// This lives in the core library rather than beside the rest of the QEMU
/// command line in `QEMUService`, for the reason `QEMUBalloonDevice` gives: that
/// file links SwiftQEMU and therefore has no unit tests, and a device line QEMU
/// rejects kills the VM during setup while surfacing only as a QMP connect
/// timeout. Taking the architecture as a parameter (rather than reading
/// `#if arch`) also lets both branches be asserted from one host.
public enum QEMUGraphicsDevice {

    /// The VNC socket's name inside the VM's own directory. Deterministic, so a
    /// VM re-adopted after an agent restart resolves its console from
    /// `vmStoragePath + vmId` alone — the listening socket belongs to the
    /// surviving QEMU process, not to the agent.
    public static let socketFilename = "vnc.sock"

    /// Where `socketFilename` lives for a VM whose directory is `vmDirectory`.
    public static func socketPath(vmDirectory: String) -> String {
        (vmDirectory as NSString).appendingPathComponent(socketFilename)
    }

    /// The arguments to append for a VM whose spec asks for a graphics console.
    ///
    /// - `-display none` plus `-vnc unix:…`: in current QEMU `-vnc` *is* a
    ///   display backend (`-vnc <display>` is documented as shorthand for
    ///   `-display vnc=<display>`), so the two coexist — the VNC server is what
    ///   exports the framebuffer, and no local window is ever opened. The
    ///   caller must correspondingly stop passing `-nographic`, whose whole job
    ///   is to force `-display none` and redirect the *default* serial and
    ///   monitor to stdio. Dropping it does not affect this VM's serial
    ///   console, which is an explicit `-serial unix:…`.
    /// - The socket carries no RFB password by design: it is a Unix socket in
    ///   the VM's directory, so its file mode plus the control plane's
    ///   `view_console` authorization are the security boundary — the same
    ///   trust model as the QMP and serial sockets beside it. It must never
    ///   become a TCP listener.
    /// - Standard VGA on x86, not virtio: the point of this console is
    ///   pre-driver output — UEFI, GRUB, Windows Setup, a panic screen — and
    ///   `virtio-vga` needs a guest driver for anything past its VGA-compat
    ///   mode. `std` is also not universally built: QEMU ships virtio-gpu as a
    ///   separate module that some distribution builds omit entirely, while
    ///   `std` is always present. Passing `-vga std` *selects* the default
    ///   adapter rather than adding a second one, which is what keeps QEMU from
    ///   refusing to start with two VGA devices.
    /// - On arm64 the `virt` machine creates no display device at all, so one
    ///   must be added explicitly; `virtio-gpu-pci` is the standard choice and
    ///   EDK2 drives it at firmware time through `VirtioGpuDxe`.
    /// - `usb-tablet` reports **absolute** pointer positions. Without it the
    ///   guest sees relative motion and its cursor drifts away from the
    ///   browser's, which makes a graphical installer unclickable. It needs a
    ///   controller to sit on: `q35` starts with USB off and `virt` has none at
    ///   all, hence the explicit `qemu-xhci` and the `bus=` that pins the
    ///   tablet to it.
    /// - `usb-kbd` on **every** architecture, and this is not redundant on the
    ///   one where it looks it. `q35` still carries the default i8042 PS/2
    ///   controller, so x86 guests would type without it (it simply becomes a
    ///   second keyboard there, which is harmless). The arm64 `virt` machine
    ///   has no PS/2 controller and creates no input devices at all, so without
    ///   this an aarch64 guest would render and accept clicks while dropping
    ///   every keystroke — the failure mode that breaks exactly the installer
    ///   this console exists to drive.
    public static func arguments(vncSocketPath: String, architecture: CPUArchitecture) -> [String] {
        var args = [
            "-display", "none",
            "-vnc", "unix:\(vncSocketPath)",
        ]
        switch architecture {
        case .x86_64:
            args += ["-vga", "std"]
        case .arm64:
            args += ["-device", "virtio-gpu-pci"]
        }
        args += [
            "-device", "\(usbControllerModel),id=\(usbControllerID)",
            "-device", "usb-tablet,bus=\(usbControllerID).0",
            "-device", "usb-kbd,bus=\(usbControllerID).0",
        ]
        return args
    }

    /// The USB controller the tablet plugs into. xHCI is the one model present
    /// on both `q35` and `virt`.
    static let usbControllerModel = "qemu-xhci"

    /// Namespaced so it cannot collide with a device id from elsewhere on the
    /// command line.
    static let usbControllerID = "strato-xhci"
}
