import Foundation

/// How a hot-plugged volume is identified inside its VM's QEMU (STR-129).
///
/// Hot-plug used to name the QMP `device_id` — and through it the
/// `drive-<id>` block node — after the volume's *device name*. That made
/// detach resolve the disk by a string the control plane had never constrained:
/// two volumes on one VM could hold the same `disk1`, and `device_del` would
/// then unplug whichever QEMU happened to have registered under it — pulling a
/// live disk out from under a running guest.
///
/// The volume id is unique by construction and already travels in `VolumeSpec`,
/// so it is what the device is named after. The device name survives as the
/// guest-facing label the operator chose and as the Firecracker drive id; it is
/// no longer an identifier anything resolves by.
public enum QEMUDiskIdentity {
    /// The QMP `device_id` for a hot-plugged volume.
    ///
    /// QEMU ids are restricted to `[A-Za-z0-9._-]` and are conventionally led by
    /// a letter; a UUID's canonical form plus the `vol-` prefix satisfies both.
    /// The prefix also keeps volume-owned devices distinguishable from the ids
    /// QEMU generates for a VM's launch-time disks.
    public static func deviceID(volumeId: String) -> String {
        "vol-\(volumeId.lowercased())"
    }
}
