import Foundation

/// The display half of a QEMU VM (issue #566), reduced to the two facts the
/// domain document needs from outside `DomainXMLBuilder`: where the VNC socket
/// lives, and which USB controller the pointer plugs into.
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
