import Foundation
import StratoShared

/// How a VM's UEFI firmware is attached to QEMU (issue #565).
public enum FirmwareSet: Equatable, Sendable {
    /// The split EDK2 build: a read-only code image plus a writable variable
    /// store. The store is copied per VM, so boot entries the guest writes —
    /// and Secure Boot keys it enrolls — survive a restart.
    case pflash(code: String, varsTemplate: String)
    /// A single firmware blob attached with `-bios`. No writable varstore, so
    /// the guest's UEFI variables are lost on every respawn. Kept as a fallback
    /// for hosts (and operator configs) that only have a monolithic image, so
    /// deployments that boot today keep booting.
    case monolithic(path: String)
}

/// Operator-configured firmware paths (`firmware_code_path`,
/// `firmware_vars_template`, their `secure_boot_` counterparts, and the legacy
/// `firmware_path_*` keys). Every field is optional; whatever is unset falls
/// back to this platform's default candidates.
public struct FirmwareOverrides: Equatable, Sendable {
    public var codePath: String?
    public var varsTemplatePath: String?
    public var secureBootCodePath: String?
    public var secureBootVarsTemplatePath: String?
    /// The legacy single-file firmware path (`firmware_path_arm64` /
    /// `firmware_path_x86_64`), used only as the `-bios` fallback.
    public var monolithicPath: String?

    public init(
        codePath: String? = nil,
        varsTemplatePath: String? = nil,
        secureBootCodePath: String? = nil,
        secureBootVarsTemplatePath: String? = nil,
        monolithicPath: String? = nil
    ) {
        self.codePath = codePath
        self.varsTemplatePath = varsTemplatePath
        self.secureBootCodePath = secureBootCodePath
        self.secureBootVarsTemplatePath = secureBootVarsTemplatePath
        self.monolithicPath = monolithicPath
    }
}

/// Resolves which EDK2 firmware files a VM boots with.
///
/// Pre-#565 the agent passed a single firmware file as `-bios`, which runs the
/// firmware with no writable variable store: UEFI boot entries the guest writes
/// are silently discarded on the next respawn, and Secure Boot keys can never be
/// enrolled at all. This resolver prefers the split CODE/VARS pair every distro
/// actually ships, and keeps the monolithic form as a fallback.
///
/// Candidates are **pairs**, never a cross product: OVMF's 4MB build requires
/// its own 4MB variable store, and pairing `OVMF_CODE_4M.fd` with the 2MB
/// `OVMF_VARS.fd` produces a firmware that fails to boot in a way that looks
/// like a broken guest image.
public enum FirmwareResolver {

    /// Why no firmware set could be resolved. Secure Boot failures are fatal to
    /// a create — booting the guest without it would quietly contradict what
    /// the API said the VM has.
    public struct UnresolvedError: Error, CustomStringConvertible, Sendable {
        public let secureBoot: Bool
        public let architecture: CPUArchitecture

        public var description: String {
            if secureBoot {
                return
                    "no Secure Boot firmware pair found for \(architecture.rawValue). Install the signed EDK2 build "
                    + "(Debian/Ubuntu: `apt install ovmf` provides OVMF_CODE_4M.secboot.fd + OVMF_VARS_4M.ms.fd) "
                    + "or set secure_boot_firmware_code_path and secure_boot_firmware_vars_template "
                    + "in the agent configuration."
            }
            return
                "no UEFI firmware found for \(architecture.rawValue). Install EDK2 firmware "
                + "(Debian/Ubuntu: `apt install ovmf qemu-efi-aarch64`, macOS: bundled with `brew install qemu`) "
                + "or set firmware_code_path and firmware_vars_template in the agent configuration."
        }
    }

    /// Resolves the firmware set for a VM.
    ///
    /// - Parameters:
    ///   - secureBoot: Whether the guest asked for Secure Boot. When true only
    ///     the signed candidates (and the `secure_boot_*` overrides) are
    ///     considered — silently falling back to an unsigned build would boot a
    ///     guest the API describes as Secure Boot enabled without it.
    ///   - perVMPath: A per-VM firmware path from the spec's `BootSource`, when
    ///     the caller set one. Honored as a monolithic image, matching the
    ///     pre-#565 meaning of the field.
    ///   - overrides: Operator configuration.
    ///   - architecture: Guest architecture; agents only run same-arch guests
    ///     accelerated, so this is the host architecture in practice.
    ///   - fileExists: Injected for testing.
    public static func resolve(
        secureBoot: Bool,
        perVMPath: String? = nil,
        overrides: FirmwareOverrides = FirmwareOverrides(),
        architecture: CPUArchitecture = .current,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) throws -> FirmwareSet {
        // An explicitly configured pair wins outright, including over a per-VM
        // path: the operator named the files this host boots with.
        let configuredCode = secureBoot ? overrides.secureBootCodePath : overrides.codePath
        let configuredVars = secureBoot ? overrides.secureBootVarsTemplatePath : overrides.varsTemplatePath
        if let code = nonEmpty(configuredCode), let vars = nonEmpty(configuredVars),
            fileExists(code), fileExists(vars)
        {
            return .pflash(code: code, varsTemplate: vars)
        }

        for pair in defaultPairs(secureBoot: secureBoot, architecture: architecture)
        where fileExists(pair.code) && fileExists(pair.vars) {
            return .pflash(code: pair.code, varsTemplate: pair.vars)
        }

        // Secure Boot has no monolithic form: a `-bios` firmware cannot hold
        // enrolled keys across a boot, so there is nothing to degrade to.
        guard !secureBoot else {
            throw UnresolvedError(secureBoot: true, architecture: architecture)
        }

        for candidate in [perVMPath, overrides.monolithicPath] {
            if let path = nonEmpty(candidate), fileExists(path) {
                return .monolithic(path: path)
            }
        }
        if let path = defaultMonolithicPath(architecture: architecture), fileExists(path) {
            return .monolithic(path: path)
        }

        throw UnresolvedError(secureBoot: false, architecture: architecture)
    }

    // MARK: - Platform defaults

    /// A CODE/VARS candidate, kept together so a 4MB code image is never paired
    /// with a 2MB variable store.
    public struct Pair: Equatable, Sendable {
        public let code: String
        public let vars: String

        public init(code: String, vars: String) {
            self.code = code
            self.vars = vars
        }
    }

    /// Firmware pairs to try, most-preferred first.
    ///
    /// Secure Boot pairs deliberately use the distros' *pre-enrolled* variable
    /// stores (`.ms.fd` on Debian/Ubuntu, `.secboot.fd` on Fedora): Windows
    /// validates against Microsoft's KEK/db, and an empty varstore would leave
    /// the guest in Secure Boot setup mode with nothing trusted.
    public static func defaultPairs(secureBoot: Bool, architecture: CPUArchitecture) -> [Pair] {
        #if os(macOS)
        // Homebrew/MacPorts QEMU ships the split EDK2 build but no signed one,
        // so Secure Boot has no candidates here and resolution fails loudly.
        // macOS agents are dev/test only.
        guard !secureBoot else { return [] }
        let prefixes = ["/opt/homebrew/share/qemu", "/usr/local/share/qemu"]
        switch architecture {
        case .arm64:
            return prefixes.map {
                Pair(code: "\($0)/edk2-aarch64-code.fd", vars: "\($0)/edk2-arm-vars.fd")
            }
        case .x86_64:
            return prefixes.map {
                Pair(code: "\($0)/edk2-x86_64-code.fd", vars: "\($0)/edk2-i386-vars.fd")
            }
        }
        #else
        switch (architecture, secureBoot) {
        case (.x86_64, false):
            return [
                Pair(code: "/usr/share/OVMF/OVMF_CODE_4M.fd", vars: "/usr/share/OVMF/OVMF_VARS_4M.fd"),
                Pair(code: "/usr/share/OVMF/OVMF_CODE.fd", vars: "/usr/share/OVMF/OVMF_VARS.fd"),
                Pair(code: "/usr/share/edk2/ovmf/OVMF_CODE.fd", vars: "/usr/share/edk2/ovmf/OVMF_VARS.fd"),
            ]
        case (.x86_64, true):
            return [
                Pair(
                    code: "/usr/share/OVMF/OVMF_CODE_4M.secboot.fd",
                    vars: "/usr/share/OVMF/OVMF_VARS_4M.ms.fd"),
                Pair(code: "/usr/share/OVMF/OVMF_CODE.secboot.fd", vars: "/usr/share/OVMF/OVMF_VARS.ms.fd"),
                Pair(
                    code: "/usr/share/edk2/ovmf/OVMF_CODE.secboot.fd",
                    vars: "/usr/share/edk2/ovmf/OVMF_VARS.secboot.fd"),
            ]
        case (.arm64, false):
            return [
                Pair(code: "/usr/share/AAVMF/AAVMF_CODE.fd", vars: "/usr/share/AAVMF/AAVMF_VARS.fd"),
                Pair(
                    code: "/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw",
                    vars: "/usr/share/edk2/aarch64/vars-template-pflash.raw"),
            ]
        case (.arm64, true):
            return [
                Pair(code: "/usr/share/AAVMF/AAVMF_CODE.secboot.fd", vars: "/usr/share/AAVMF/AAVMF_VARS.ms.fd"),
                Pair(
                    code: "/usr/share/edk2/aarch64/QEMU_EFI-silent-pflash.raw",
                    vars: "/usr/share/edk2/aarch64/vars-template-pflash.raw"),
            ]
        }
        #endif
    }

    /// The pre-#565 single-file default for this architecture.
    public static func defaultMonolithicPath(architecture: CPUArchitecture) -> String? {
        switch architecture {
        case .arm64:
            return AgentConfig.defaultFirmwarePathARM64
        case .x86_64:
            return AgentConfig.defaultFirmwarePathX86_64
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
