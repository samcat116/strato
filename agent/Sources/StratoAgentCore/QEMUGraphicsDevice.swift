import Foundation

/// The display half of a QEMU VM (issue #566), reduced to the two facts the
/// domain document needs from outside `DomainXMLBuilder`: where the VNC socket
/// lives, and which USB controller the pointer plugs into.
///
/// The argv builder this used to be went with the process driver (STR-136).
/// libvirt writes the `<graphics>`, `<video>` and `<input>` elements now, and
/// the reasoning that used to live here — standard VGA on x86 because the
/// console exists for pre-driver output, `virtio-gpu-pci` on arm64 because the
/// `virt` machine creates no display device at all, an absolute-positioning
/// tablet and an explicit keyboard because `virt` has no PS/2 controller — is
/// asserted against the builder's golden domain XML instead.
public enum QEMUGraphicsDevice {

    /// The deterministic VNC socket for a VM. A VM re-adopted after an agent
    /// restart resolves its console from `vmStoragePath + vmId` alone — the
    /// listening socket belongs to libvirt's QEMU process, not to the agent.
    public static func socketPath(vmDirectory: String) -> String {
        (vmDirectory as NSString).appendingPathComponent("vnc.sock")
    }

    /// The USB controller the tablet and keyboard plug into. xHCI is the one
    /// model present on both `q35` and `virt`.
    static let usbControllerModel = "qemu-xhci"
}
