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

/// What a disk-booting libvirt domain document should say about firmware.
///
/// The two cases are not interchangeable, and which one a host gets is decided
/// once per create by `FirmwareResolver.domainFirmware`.
public enum DomainFirmware: Equatable, Sendable {
    /// Name this set in the document. For a `.pflash` set that also obliges the
    /// caller to **materialize the varstore before the domain starts** — see
    /// `UEFIVarstore` — because the document names an nvram file with no
    /// `template` to seed it from.
    case explicit(FirmwareSet)
    /// Name nothing, and let `<os firmware='efi'>` rank libvirt's own installed
    /// descriptors. Carries the resolution failure that led here, which is the
    /// only record of *why* a host ended up on the path that cannot guarantee a
    /// qcow2 varstore.
    case autoselect(FirmwareResolver.UnresolvedError)
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
    public struct UnresolvedError: Error, CustomStringConvertible, Equatable, Sendable {
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
        guard
            let set = resolved(
                secureBoot: secureBoot, perVMPath: perVMPath, overrides: overrides,
                architecture: architecture, allowingPlatformMonolithic: true, fileExists: fileExists)
        else {
            throw UnresolvedError(secureBoot: secureBoot, architecture: architecture)
        }
        return set
    }

    /// What a **disk-booting** libvirt domain names for firmware.
    ///
    /// Autoselection (`<os firmware='efi'>`) used to be the normal path here,
    /// and it cannot be, because Strato's varstore is qcow2 and every EDK2
    /// descriptor Debian and Ubuntu ship declares its nvram template `raw`
    /// (STR-188). libvirt matches the requested format against its descriptors
    /// at *define* time and answers a mismatch with "Unable to find 'efi'
    /// firmware that is compatible with the current configuration" — which
    /// reads like a missing OVMF package rather than the format collision it
    /// is. Naming the pair ourselves takes the descriptor match out of the
    /// picture entirely.
    ///
    /// The format is not negotiable: libvirt refuses an internal snapshot of a
    /// pflash guest whose varstore is not qcow2, and that snapshot is how VM
    /// checkpoints are realized. Nor can libvirt be asked to seed a qcow2
    /// varstore from a raw template ("conversion of the nvram template to
    /// another target format is not supported") — which is why `.explicit`
    /// carries an obligation to materialize the file first.
    ///
    /// Autoselection survives as the answer for a host this resolver's
    /// candidate list does not know (openSUSE's `/usr/share/qemu/ovmf-*.bin`,
    /// say). Such a host may well have descriptors libvirt can rank, and
    /// failing the create outright would take away a VM that boots today. The
    /// error it carries is what the caller logs, because on a raw-descriptor
    /// host the define that follows will fail and this is the reason.
    ///
    /// **The platform's monolithic default is not offered here**, which is the
    /// one candidate this differs from `resolve` on. Its list leads with
    /// `/usr/share/OVMF/OVMF_CODE.fd` — the *CODE half of a split pair* — so it
    /// fires exactly when a split build is half-installed and its VARS is
    /// missing, and it would hand that half to `-bios` as though it were a
    /// whole firmware. Even a genuine single blob is the wrong trade on this
    /// path: `-bios` has no writable varstore at all, so the guest's UEFI boot
    /// entries stop persisting, where autoselect may still find libvirt a
    /// proper pflash pair. A monolithic the *operator* named still wins — that
    /// is a deliberate choice about a host, not a guess made on its behalf.
    public static func domainFirmware(
        secureBoot: Bool,
        perVMPath: String? = nil,
        overrides: FirmwareOverrides = FirmwareOverrides(),
        architecture: CPUArchitecture = .current,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> DomainFirmware {
        guard
            let set = resolved(
                secureBoot: secureBoot, perVMPath: perVMPath, overrides: overrides,
                architecture: architecture, allowingPlatformMonolithic: false, fileExists: fileExists)
        else {
            return .autoselect(UnresolvedError(secureBoot: secureBoot, architecture: architecture))
        }
        return .explicit(set)
    }

    /// The candidate walk both entry points share. Nil means nothing on this
    /// host matched — the two callers differ in what they do about it, and in
    /// whether the platform's monolithic default counts as a match at all (see
    /// `domainFirmware`).
    private static func resolved(
        secureBoot: Bool,
        perVMPath: String?,
        overrides: FirmwareOverrides,
        architecture: CPUArchitecture,
        allowingPlatformMonolithic: Bool,
        fileExists: (String) -> Bool
    ) -> FirmwareSet? {
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
        guard !secureBoot else { return nil }

        for candidate in [perVMPath, overrides.monolithicPath] {
            if let path = nonEmpty(candidate), fileExists(path) {
                return .monolithic(path: path)
            }
        }
        if allowingPlatformMonolithic, let path = defaultMonolithicPath(architecture: architecture),
            fileExists(path)
        {
            return .monolithic(path: path)
        }

        return nil
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
