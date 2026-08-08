import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore

/// Firmware resolution for VM boot (issue #565). Every case injects
/// `fileExists`, so these run identically on a host with no EDK2 installed.
@Suite("FirmwareResolver")
struct FirmwareResolverTests {

    /// Only the named paths "exist".
    private func existing(_ paths: String...) -> (String) -> Bool {
        let set = Set(paths)
        return { set.contains($0) }
    }

    @Test("A configured CODE/VARS pair wins over everything else")
    func configuredPairWins() throws {
        let overrides = FirmwareOverrides(
            codePath: "/custom/CODE.fd",
            varsTemplatePath: "/custom/VARS.fd",
            monolithicPath: "/custom/monolithic.fd")
        let set = try FirmwareResolver.resolve(
            secureBoot: false,
            perVMPath: "/per-vm.fd",
            overrides: overrides,
            architecture: .x86_64,
            fileExists: existing("/custom/CODE.fd", "/custom/VARS.fd", "/custom/monolithic.fd", "/per-vm.fd"))
        #expect(set == .pflash(code: "/custom/CODE.fd", varsTemplate: "/custom/VARS.fd"))
    }

    @Test("A half-present configured pair falls through to the platform defaults")
    func halfPresentConfiguredPairIsIgnored() throws {
        // The operator named both, but the varstore is missing on this host.
        // Booting off the code image alone would be the `-bios` behavior the
        // pair exists to replace, so the resolver moves on rather than
        // improvising a partner for it.
        let overrides = FirmwareOverrides(
            codePath: "/custom/CODE.fd", varsTemplatePath: "/custom/VARS.fd")
        let defaults = FirmwareResolver.defaultPairs(secureBoot: false, architecture: .x86_64)
        let fallback = try #require(defaults.first)
        let set = try FirmwareResolver.resolve(
            secureBoot: false,
            overrides: overrides,
            architecture: .x86_64,
            fileExists: existing("/custom/CODE.fd", fallback.code, fallback.vars))
        #expect(set == .pflash(code: fallback.code, varsTemplate: fallback.vars))
    }

    @Test("Default pairs are never crossed: a 4M code image is not paired with a 2M varstore")
    func pairsAreNotCrossed() throws {
        let defaults = FirmwareResolver.defaultPairs(secureBoot: false, architecture: .x86_64)
        let first = try #require(defaults.first)
        let second = try #require(defaults.dropFirst().first)
        // Only the *mismatched* halves of two different pairs exist. Pairing
        // them would boot a firmware that cannot find its variable store, so
        // resolution must skip both pairs. (It may still land on the monolithic
        // fallback — that path is `-bios`, which needs no varstore at all.)
        let resolved = try? FirmwareResolver.resolve(
            secureBoot: false,
            architecture: .x86_64,
            fileExists: existing(first.code, second.vars))
        #expect(resolved != .pflash(code: first.code, varsTemplate: second.vars))
        #expect(resolved != .pflash(code: second.code, varsTemplate: first.vars))
        if case .pflash = resolved {
            Issue.record("resolved a pflash pair from mismatched halves: \(String(describing: resolved))")
        }
    }

    @Test("Falls back to a monolithic image when no pair resolves")
    func monolithicFallback() throws {
        let overrides = FirmwareOverrides(monolithicPath: "/legacy/OVMF.fd")
        let set = try FirmwareResolver.resolve(
            secureBoot: false,
            overrides: overrides,
            architecture: .x86_64,
            fileExists: existing("/legacy/OVMF.fd"))
        #expect(set == .monolithic(path: "/legacy/OVMF.fd"))
    }

    @Test("A per-VM firmware path is honored as a monolithic image")
    func perVMPathIsMonolithic() throws {
        let set = try FirmwareResolver.resolve(
            secureBoot: false,
            perVMPath: "/per-vm/OVMF.fd",
            overrides: FirmwareOverrides(monolithicPath: "/legacy/OVMF.fd"),
            architecture: .x86_64,
            fileExists: existing("/per-vm/OVMF.fd", "/legacy/OVMF.fd"))
        #expect(set == .monolithic(path: "/per-vm/OVMF.fd"))
    }

    @Test("Secure Boot never degrades to an unsigned pair")
    func secureBootDoesNotDegrade() {
        // Every *unsigned* candidate exists; none of the signed ones do.
        // Resolution must fail rather than hand back a firmware that would boot
        // the guest with Secure Boot off while the API says it is on.
        let unsigned = FirmwareResolver.defaultPairs(secureBoot: false, architecture: .x86_64)
        let present = Set(unsigned.flatMap { [$0.code, $0.vars] })
        #expect(throws: FirmwareResolver.UnresolvedError.self) {
            try FirmwareResolver.resolve(
                secureBoot: true,
                architecture: .x86_64,
                fileExists: { present.contains($0) })
        }
    }

    @Test("Secure Boot never degrades to a monolithic image either")
    func secureBootDoesNotFallBackToBios() {
        // A `-bios` firmware has no writable varstore, so it cannot hold the
        // enrolled keys Secure Boot is defined by — the monolithic fallback
        // must not apply here even when one is configured and present.
        let overrides = FirmwareOverrides(monolithicPath: "/legacy/OVMF.fd")
        #expect(throws: FirmwareResolver.UnresolvedError.self) {
            try FirmwareResolver.resolve(
                secureBoot: true,
                overrides: overrides,
                architecture: .x86_64,
                fileExists: existing("/legacy/OVMF.fd"))
        }
    }

    @Test("A configured Secure Boot pair is used when present")
    func configuredSecureBootPair() throws {
        let overrides = FirmwareOverrides(
            codePath: "/plain/CODE.fd",
            varsTemplatePath: "/plain/VARS.fd",
            secureBootCodePath: "/signed/CODE.secboot.fd",
            secureBootVarsTemplatePath: "/signed/VARS.ms.fd")
        let paths = existing(
            "/plain/CODE.fd", "/plain/VARS.fd", "/signed/CODE.secboot.fd", "/signed/VARS.ms.fd")
        let secure = try FirmwareResolver.resolve(
            secureBoot: true, overrides: overrides, architecture: .x86_64, fileExists: paths)
        #expect(secure == .pflash(code: "/signed/CODE.secboot.fd", varsTemplate: "/signed/VARS.ms.fd"))

        // The unsigned pair is still what a non-Secure-Boot VM gets: the two
        // configurations coexist on one host.
        let plain = try FirmwareResolver.resolve(
            secureBoot: false, overrides: overrides, architecture: .x86_64, fileExists: paths)
        #expect(plain == .pflash(code: "/plain/CODE.fd", varsTemplate: "/plain/VARS.fd"))
    }

    @Test("Nothing installed at all is an error, not a silent unbootable VM")
    func nothingResolves() {
        #expect(throws: FirmwareResolver.UnresolvedError.self) {
            try FirmwareResolver.resolve(
                secureBoot: false, architecture: .x86_64, fileExists: { _ in false })
        }
    }

    // MARK: - What a domain document names

    /// The regression STR-188 was reported as, at the one place a unit test can
    /// reach it.
    ///
    /// A stock Debian or Ubuntu hypervisor node configures no firmware paths at
    /// all, and that used to be the signal to hand the choice to libvirt's
    /// autoselection — which cannot produce the qcow2 varstore checkpoints
    /// need, because every EDK2 descriptor those distros ship declares its
    /// nvram template `raw`. The define then failed with "Unable to find 'efi'
    /// firmware that is compatible with the current configuration" and every
    /// VM create on the host failed with it.
    ///
    /// So: an unconfigured host with the ordinary OVMF files present must name
    /// them. Not "may" — autoselect is what this asserts the absence of.
    @Test("A host with a stock EDK2 pair and no configuration still names it")
    func unconfiguredHostNamesItsPair() throws {
        let pair = try #require(
            FirmwareResolver.defaultPairs(secureBoot: false, architecture: .x86_64).first)
        let firmware = FirmwareResolver.domainFirmware(
            secureBoot: false, architecture: .x86_64, fileExists: existing(pair.code, pair.vars))
        #expect(firmware == .explicit(.pflash(code: pair.code, varsTemplate: pair.vars)))
    }

    /// The same for a Secure Boot VM, whose varstore is the one carrying
    /// enrolled keys — so a wrong answer here is worse than a failed create.
    ///
    /// Driven through overrides rather than the platform candidates, because
    /// `defaultPairs` has no signed entries at all on macOS (no Homebrew QEMU
    /// ships one) and this property is not about which files a host has.
    @Test("A Secure Boot VM names the signed pair rather than autoselecting")
    func secureBootNamesItsSignedPair() {
        let overrides = FirmwareOverrides(
            secureBootCodePath: "/signed/CODE.secboot.fd",
            secureBootVarsTemplatePath: "/signed/VARS.ms.fd")
        let firmware = FirmwareResolver.domainFirmware(
            secureBoot: true, overrides: overrides, architecture: .x86_64,
            fileExists: existing("/signed/CODE.secboot.fd", "/signed/VARS.ms.fd"))
        #expect(
            firmware
                == .explicit(.pflash(code: "/signed/CODE.secboot.fd", varsTemplate: "/signed/VARS.ms.fd")))
    }

    /// Autoselect survives, and this is the whole of what it is for: a host
    /// whose EDK2 build sits somewhere this resolver's candidate list has never
    /// heard of (openSUSE's `/usr/share/qemu/ovmf-x86_64-code.bin`, say). Such
    /// a host may still have descriptors libvirt can rank, and failing the
    /// create outright would take away a VM that boots today.
    @Test("Autoselect is the answer only where nothing resolves")
    func autoselectIsTheFallback() {
        let firmware = FirmwareResolver.domainFirmware(
            secureBoot: false, architecture: .x86_64, fileExists: { _ in false })
        #expect(firmware == .autoselect(.init(secureBoot: false, architecture: .x86_64)))
    }

    /// The fallback carries the failure it fell back from, because that error
    /// is the only thing that says *why* a host ended up on the path whose
    /// define may be refused. A Secure Boot failure has its own remediation, so
    /// the flag has to survive the trip.
    @Test("The autoselect fallback carries the Secure Boot reason it failed for")
    func autoselectCarriesTheSecureBootReason() {
        // Every unsigned candidate is present; a non-Secure-Boot VM therefore
        // resolves, and only the Secure Boot one falls through.
        let unsigned = FirmwareResolver.defaultPairs(secureBoot: false, architecture: .x86_64)
        let present = Set(unsigned.flatMap { [$0.code, $0.vars] })
        let firmware = FirmwareResolver.domainFirmware(
            secureBoot: true, architecture: .x86_64, fileExists: { present.contains($0) })
        guard case .autoselect(let unresolved) = firmware else {
            Issue.record("expected the Secure Boot VM to fall back, got \(firmware)")
            return
        }
        #expect(unresolved.secureBoot)
        #expect(unresolved.description.contains("secure_boot_firmware_code_path"))
    }

    /// A monolithic firmware has no varstore at all, so it is named the same
    /// way whether or not a varstore could be materialized — the branch that
    /// STR-188 changed does not apply to it.
    @Test("A monolithic fallback is named explicitly too")
    func monolithicIsNamedNotAutoselected() {
        let firmware = FirmwareResolver.domainFirmware(
            secureBoot: false, perVMPath: "/per-vm/OVMF.fd", architecture: .x86_64,
            fileExists: existing("/per-vm/OVMF.fd"))
        #expect(firmware == .explicit(.monolithic(path: "/per-vm/OVMF.fd")))
    }
}
