import Foundation

/// Operating system of a hypervisor host.
///
/// Reported at agent registration (alongside `CPUArchitecture`) so the control
/// plane can resolve the right release artifact for an agent self-update —
/// release tarballs are published per OS/arch pair (`strato-<os>-<arch>.tar.gz`).
/// The raw values match the asset-name components `deploy/agent/install.sh`
/// derives from `uname -s`.
public enum OperatingSystem: String, Codable, CaseIterable, Sendable {
    case linux = "linux"
    case macos = "macos"

    /// The OS this binary was compiled for (the host OS, since agents run
    /// natively on their hypervisor node).
    public static var current: OperatingSystem {
        #if os(Linux)
        return .linux
        #elseif os(macOS)
        return .macos
        #else
        #error("Unsupported OS: Strato agents support Linux and macOS hosts")
        #endif
    }
}
