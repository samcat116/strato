import Foundation
import Logging

/// The files and sockets that live in a VM's own directory
/// (`<vmStoragePath>/<vmId>`).
///
/// Every name is deterministic from the directory alone, which is what lets a
/// VM re-adopted after an agent restart resolve its console, guest-agent
/// channel and varstore from `vmStoragePath + vmId` with no retained state.
///
/// Two neighbours are deliberately *not* duplicated here, because they already
/// have owners: the VNC socket is `QEMUGraphicsDevice.socketPath(vmDirectory:)`
/// and swtpm's state and control socket belong to libvirt, not to this layout.
public enum VMDirectoryLayout {

    /// The VM's own directory, `<vmStoragePath>/<vmId>`.
    public static func directory(vmStoragePath: String, vmId: String) -> String {
        (vmStoragePath as NSString).appendingPathComponent(vmId)
    }

    /// Removes a VM's directory and everything in it.
    ///
    /// Deleting a VM is a single recursive removal rather than a list of known
    /// files. The file-by-file version this replaced grew one unlink per issue
    /// that introduced a file (#563, #565, #566, #567) and never included the
    /// boot disk or the cloud-init ISO, so every delete leaked them (#969) —
    /// naming files individually is the bug, not a detail of it.
    ///
    /// Callers must have torn the hypervisor process (and any swtpm) down
    /// first: this unlinks the disk the guest is running from.
    ///
    /// Best-effort. A delete whose hypervisor teardown already succeeded must
    /// not fail and strand the VM in the reconciler, so a removal failure is
    /// logged at error level — loud, because what survives is the largest
    /// artifact on the host — rather than thrown.
    public static func removeDirectory(vmStoragePath: String, vmId: String, logger: Logger) {
        // This removal is recursive, so an id that is not a single path
        // component would take the storage root — every other VM's disk — with
        // it. Ids come from the control plane as UUIDs; refuse anything else
        // instead of trusting that.
        guard !vmStoragePath.isEmpty, !vmId.isEmpty, vmId != ".", vmId != "..", !vmId.contains("/") else {
            logger.error(
                "Refusing to remove VM directory: implausible storage path or VM id",
                metadata: ["strato.vm.id": .string(vmId), "vmStoragePath": .string(vmStoragePath)])
            return
        }

        // No `fileExists` pre-check: it follows symlinks, so a dangling
        // symlink at this path would report absent and never be unlinked, and
        // the removal itself already distinguishes "not there" from a real
        // failure. An already-absent directory is a success — a delete can be
        // replayed, and the reconciler is level-triggered.
        let directory = directory(vmStoragePath: vmStoragePath, vmId: vmId)
        do {
            try FileManager.default.removeItem(atPath: directory)
            // At info, not debug: this is the only record that a VM's disk
            // space was actually reclaimed, and its absence next to the error
            // below is what tells an operator which deletes leaked.
            logger.info("Removed VM directory", metadata: ["strato.vm.id": .string(vmId), "path": .string(directory)])
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError
        {
            logger.debug("VM directory already absent", metadata: ["strato.vm.id": .string(vmId)])
        } catch {
            logger.error(
                "Failed to remove VM directory; its disk image and other artifacts are leaked on this host",
                metadata: [
                    "strato.vm.id": .string(vmId),
                    "path": .string(directory),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    /// virtio console (`hvc0`) socket — the stream `ConsoleSocketManager`
    /// relays to the browser console.
    public static func consoleSocket(vmDirectory: String) -> String {
        path(vmDirectory, "console.sock")
    }

    /// Serial console (`ttyS0`/`ttyAMA0`) socket.
    public static func serialSocket(vmDirectory: String) -> String {
        path(vmDirectory, "serial.sock")
    }

    /// Host end of the `org.qemu.guest_agent.0` channel.
    public static func guestAgentSocket(vmDirectory: String) -> String {
        path(vmDirectory, "qga.sock")
    }

    /// The NoCloud seed ISO, when guest provisioning produced one.
    public static func cloudInitISO(vmDirectory: String) -> String {
        path(vmDirectory, "cloud-init.iso")
    }

    /// The per-VM UEFI variable store.
    ///
    /// The name is unchanged from the QEMU path, but under libvirt the file is
    /// declared `format='qcow2'` rather than raw: libvirt ≥ 11.5 requires a
    /// qcow2 varstore before it will take an internal snapshot of a VM with
    /// pflash firmware, which is how VM checkpoints are realized. A raw
    /// `nvram.fd` left behind by the QEMU driver at this path is therefore not
    /// interchangeable — converting existing varstores is part of the cutover,
    /// not of this file.
    ///
    /// `UEFIVarstore` is what writes it, before the domain is defined, because
    /// libvirt will seed a varstore from a template but not change its format
    /// on the way (STR-188).
    public static func nvram(vmDirectory: String) -> String {
        path(vmDirectory, "nvram.fd")
    }

    private static func path(_ directory: String, _ component: String) -> String {
        (directory as NSString).appendingPathComponent(component)
    }
}
