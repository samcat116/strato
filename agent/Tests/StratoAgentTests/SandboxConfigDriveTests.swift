import Foundation
import Testing
import StratoShared

@testable import StratoAgentCore

@Suite("Sandbox Config Drive Tests")
struct SandboxConfigDriveTests {

    private func guestConfig(
        entrypoint: [String] = ["/bin/app"],
        cmd: [String] = ["--serve"],
        env: [String] = ["PATH=/usr/bin", "FOO=bar"],
        workingDir: String? = "/app",
        user: String? = "1000:2000"
    ) -> SandboxGuestConfig {
        SandboxGuestConfig(entrypoint: entrypoint, cmd: cmd, env: env, workingDir: workingDir, user: user)
    }

    private func spec(
        entrypoint: [String]? = nil,
        cmd: [String]? = nil,
        env: [String: String] = [:],
        workingDir: String? = nil
    ) -> SandboxSpec {
        SandboxSpec(
            image: "docker.io/library/alpine:latest", cpus: 1, memoryBytes: 128 * 1024 * 1024,
            entrypoint: entrypoint, cmd: cmd, env: env, workingDir: workingDir)
    }

    /// The encoded document must match the guest's serde contract exactly:
    /// snake_case top level, PascalCase image_config, snake_case overrides.
    @Test("encodes the guest wire schema with the right key casing")
    func encodesGuestSchema() throws {
        let drive = SandboxConfigDrive(
            sandboxId: "sb-1", identityNonce: "nonce-1", guestConfig: guestConfig(), spec: spec())
        let json = try drive.encoded()
        let obj = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])

        #expect(obj["schema_version"] as? Int == 2)
        #expect(obj["sandbox_id"] as? String == "sb-1")
        #expect(obj["identity_nonce"] as? String == "nonce-1")
        #expect(obj["vsock_port"] as? Int == 1024)

        let rootfs = try #require(obj["rootfs"] as? [String: Any])
        #expect(rootfs["device"] as? String == "/dev/vda")
        #expect(rootfs["fstype"] as? String == "ext4")
        #expect(rootfs["readonly"] as? Bool == false)

        let imageConfig = try #require(obj["image_config"] as? [String: Any])
        #expect(imageConfig["Entrypoint"] as? [String] == ["/bin/app"])
        #expect(imageConfig["Cmd"] as? [String] == ["--serve"])
        #expect(imageConfig["Env"] as? [String] == ["PATH=/usr/bin", "FOO=bar"])
        #expect(imageConfig["WorkingDir"] as? String == "/app")
        #expect(imageConfig["User"] as? String == "1000:2000")
    }

    /// Spec overrides ride in `overrides`, so the guest performs the OCI merge.
    @Test("forwards spec overrides in the overrides object")
    func forwardsOverrides() throws {
        let drive = SandboxConfigDrive(
            sandboxId: "sb-2", identityNonce: "n",
            guestConfig: guestConfig(),
            spec: spec(entrypoint: ["/bin/other"], cmd: ["--flag"], env: ["DEBUG": "1"], workingDir: "/data"))
        let obj = try #require(
            try JSONSerialization.jsonObject(with: try drive.encoded()) as? [String: Any])
        let overrides = try #require(obj["overrides"] as? [String: Any])

        #expect(overrides["entrypoint"] as? [String] == ["/bin/other"])
        #expect(overrides["cmd"] as? [String] == ["--flag"])
        #expect(overrides["workdir"] as? String == "/data")
        let env = try #require(overrides["env"] as? [String: String])
        #expect(env == ["DEBUG": "1"])
    }

    /// A nil override is omitted (the guest's `#[serde(default)]` reads an
    /// absent key as `None`), and a nil image workingDir/user collapse to empty
    /// strings.
    @Test("absent overrides are omitted; absent image fields become empty strings")
    func absentFieldsEncodeSafely() throws {
        let drive = SandboxConfigDrive(
            sandboxId: "sb-3", identityNonce: "n",
            guestConfig: guestConfig(workingDir: nil, user: nil), spec: spec())
        let obj = try #require(
            try JSONSerialization.jsonObject(with: try drive.encoded()) as? [String: Any])

        let imageConfig = try #require(obj["image_config"] as? [String: Any])
        #expect(imageConfig["WorkingDir"] as? String == "")
        #expect(imageConfig["User"] as? String == "")

        let overrides = try #require(obj["overrides"] as? [String: Any])
        #expect(overrides["entrypoint"] == nil)
        #expect(overrides["cmd"] == nil)
        #expect(overrides["workdir"] == nil)
        #expect(overrides["user"] == nil)
        // env is non-optional and always present (empty when unset).
        #expect(overrides["env"] as? [String: String] == [:])
    }

    /// The block image is the JSON followed by NUL padding to a whole sector,
    /// and re-parses after the guest's trailing-NUL strip.
    @Test("block image pads to a whole 512-byte sector and re-parses")
    func blockImagePadsAndReparses() throws {
        let drive = SandboxConfigDrive(
            sandboxId: "sb-4", identityNonce: "n", guestConfig: guestConfig(), spec: spec())
        let image = try drive.blockImage()

        #expect(image.count % 512 == 0)
        #expect(image.count >= 512)

        // Mirror the guest's parse: strip trailing NUL/whitespace, then decode.
        let end = image.lastIndex(where: { $0 != 0 }).map { image.index(after: $0) } ?? image.startIndex
        let trimmed = image[image.startIndex..<end]
        let decoded = try JSONDecoder().decode(SandboxConfigDrive.self, from: Data(trimmed))
        #expect(decoded.sandboxId == "sb-4")
        #expect(decoded.schemaVersion == 2)
    }

    /// A tiny document still fills at least one sector.
    @Test("block image honors the minimum sector size")
    func blockImageMinimumSize() throws {
        let drive = SandboxConfigDrive(
            sandboxId: "s", identityNonce: "n",
            guestConfig: SandboxGuestConfig(entrypoint: [], cmd: ["/bin/true"], env: [], workingDir: nil, user: nil),
            spec: spec())
        #expect(try drive.blockImage().count >= 512)
    }

    /// `decode(fromBlockImage:)` recovers the document (and its nonce) from the
    /// padded block image — the path the runtime uses to re-learn a sandbox's
    /// identity after an agent restart.
    @Test("decode(fromBlockImage:) recovers the document from padding")
    func decodeFromBlockImageRecoversNonce() throws {
        let drive = SandboxConfigDrive(
            sandboxId: "sb-5", identityNonce: "boot-nonce-xyz", guestConfig: guestConfig(), spec: spec())
        let decoded = try SandboxConfigDrive.decode(fromBlockImage: try drive.blockImage())
        #expect(decoded.sandboxId == "sb-5")
        #expect(decoded.identityNonce == "boot-nonce-xyz")
    }

    // MARK: - Warm start (issue #426)

    /// Ordinary documents must not carry `warm_hold` at all — the field is
    /// encoded only when set, keeping pre-warm-start guests byte-compatible.
    @Test("warm_hold is omitted by default and encoded when set")
    func warmHoldEncodesOnlyWhenSet() throws {
        let ordinary = SandboxConfigDrive(
            sandboxId: "sb-6", identityNonce: "n", guestConfig: guestConfig(), spec: spec())
        let ordinaryObject = try #require(
            try JSONSerialization.jsonObject(with: ordinary.encoded()) as? [String: Any])
        #expect(ordinaryObject["warm_hold"] == nil)

        let template = SandboxConfigDrive(
            sandboxId: "warm-template-1", identityNonce: "n",
            imageConfig: SandboxConfigDrive.ImageConfig(
                env: [], entrypoint: [], cmd: ["/bin/true"], workingDir: "", user: ""),
            overrides: SandboxConfigDrive.ProcessOverrides(
                entrypoint: nil, cmd: nil, env: [:], workdir: nil, user: nil),
            warmHold: true)
        let templateObject = try #require(
            try JSONSerialization.jsonObject(with: template.encoded()) as? [String: Any])
        #expect(templateObject["warm_hold"] as? Bool == true)
        let decoded = try SandboxConfigDrive.decode(fromBlockImage: try template.blockImage())
        #expect(decoded.warmHold == true)
    }

    /// Warm restores stage a different sandbox's config document at the
    /// device capacity the template snapshot recorded, so all warm-eligible
    /// drives share `standardBlockImageBytes` regardless of document size.
    @Test("the standard block-image capacity is stable across document sizes")
    func standardCapacityIsStable() throws {
        let small = SandboxConfigDrive(
            sandboxId: "sb-7", identityNonce: "n", guestConfig: guestConfig(), spec: spec())
        let big = SandboxConfigDrive(
            sandboxId: "sb-8", identityNonce: "n", guestConfig: guestConfig(),
            spec: spec(
                env: Dictionary(
                    uniqueKeysWithValues: (0..<200).map { ("KEY_\($0)", String(repeating: "v", count: 64)) })))
        let smallImage = try small.blockImage(minimumBytes: SandboxConfigDrive.standardBlockImageBytes)
        let bigImage = try big.blockImage(minimumBytes: SandboxConfigDrive.standardBlockImageBytes)
        #expect(smallImage.count == SandboxConfigDrive.standardBlockImageBytes)
        #expect(bigImage.count == SandboxConfigDrive.standardBlockImageBytes)
        // And both still re-parse.
        #expect(try SandboxConfigDrive.decode(fromBlockImage: smallImage).sandboxId == "sb-7")
        #expect(try SandboxConfigDrive.decode(fromBlockImage: bigImage).sandboxId == "sb-8")
    }

    // MARK: - Guest networking (STR-101)

    private func attachment(
        macAddress: String? = "06:00:ac:10:00:05",
        ipAddress: String? = "172.16.0.5",
        netmask: String? = "255.255.255.0",
        gateway: String? = "172.16.0.1",
        ip6Address: String? = nil,
        prefixLength6: Int? = nil,
        gateway6: String? = nil,
        mtu: Int? = 1442,
        dhcpEnabled: Bool = false,
        dnsServers: [String] = ["172.16.0.2"],
        domainName: String? = "proj.strato.internal"
    ) -> ResolvedNetworkAttachment {
        ResolvedNetworkAttachment(
            network: "tenant", attachment: .tap(interface: "tap0"), macAddress: macAddress,
            ipAddress: ipAddress, netmask: netmask, gateway: gateway, ip6Address: ip6Address,
            prefixLength6: prefixLength6, gateway6: gateway6, mtu: mtu, dhcpEnabled: dhcpEnabled,
            dnsServers: dnsServers, domainName: domainName)
    }

    /// The guest reads snake_case keys and a numeric prefix for both families,
    /// so the host is where a dotted netmask becomes one.
    @Test("the network block encodes the guest's key casing and a numeric prefix")
    func networkBlockEncodesGuestSchema() throws {
        let network = try SandboxConfigDrive.network(
            for: attachment(
                ip6Address: "fd12:3456:789a::5", prefixLength6: 64,
                gateway6: "fd12:3456:789a::1"),
            hostname: SandboxConfigDrive.guestHostname(sandboxId: "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"))
        let drive = SandboxConfigDrive(
            sandboxId: "sb-9", identityNonce: "n", guestConfig: guestConfig(), spec: spec(),
            network: network)
        let obj = try #require(
            try JSONSerialization.jsonObject(with: try drive.encoded()) as? [String: Any])
        let block = try #require(obj["network"] as? [String: Any])

        #expect(block["mac_address"] as? String == "06:00:ac:10:00:05")
        #expect(block["mtu"] as? Int == 1442)
        #expect(block["nameservers"] as? [String] == ["172.16.0.2"])
        #expect(block["search_domains"] as? [String] == ["proj.strato.internal"])
        #expect(block["hostname"] as? String == "strato-0f1e2d3c4b5a")

        let v4 = try #require(block["ipv4"] as? [String: Any])
        #expect(v4["address"] as? String == "172.16.0.5")
        #expect(v4["prefix_length"] as? Int == 24)
        #expect(v4["gateway"] as? String == "172.16.0.1")

        let v6 = try #require(block["ipv6"] as? [String: Any])
        #expect(v6["address"] as? String == "fd12:3456:789a::5")
        #expect(v6["prefix_length"] as? Int == 64)
        #expect(v6["gateway"] as? String == "fd12:3456:789a::1")
    }

    /// A network-free sandbox's document is unchanged, so nothing about the
    /// v1-shaped boot path moves under it.
    @Test("the network block is omitted for a sandbox with no NIC")
    func networkBlockOmittedWithoutANIC() throws {
        let drive = SandboxConfigDrive(
            sandboxId: "sb-10", identityNonce: "n", guestConfig: guestConfig(), spec: spec())
        let obj = try #require(
            try JSONSerialization.jsonObject(with: try drive.encoded()) as? [String: Any])
        #expect(obj["network"] == nil)
    }

    /// The block is written even for a DHCP-enabled NIC: OVN still answers
    /// DHCP for the port, but the guest runs no client and must not depend on
    /// one.
    @Test("a DHCP-enabled NIC still gets static addressing")
    func dhcpNICStillGetsStaticAddressing() throws {
        let network = try SandboxConfigDrive.network(
            for: attachment(dhcpEnabled: true), hostname: "strato-abc")
        #expect(network.ipv4?.address == "172.16.0.5")
        #expect(network.ipv4?.prefixLength == 24)
    }

    /// Silently dropping the family would boot a sandbox with a link-up,
    /// unaddressed interface while the host reports it running.
    @Test("an IPv4 address with no usable netmask is refused, not dropped")
    func unusableNetmaskIsRefused() throws {
        #expect(throws: SandboxRuntimeError.self) {
            _ = try SandboxConfigDrive.network(
                for: attachment(netmask: nil), hostname: nil)
        }
        #expect(throws: SandboxRuntimeError.self) {
            // Non-contiguous masks have no prefix length.
            _ = try SandboxConfigDrive.network(
                for: attachment(netmask: "255.0.255.0"), hostname: nil)
        }
    }

    /// An isolated network has no gateway and no resolvers; the guest should
    /// still get its address, and blank strings must not reach it as entries.
    @Test("optional fields collapse rather than travelling blank")
    func optionalNetworkFieldsCollapse() throws {
        let network = try SandboxConfigDrive.network(
            for: attachment(gateway: "", mtu: nil, dnsServers: ["", "  "], domainName: " "),
            hostname: nil)
        #expect(network.ipv4?.gateway == nil)
        #expect(network.mtu == nil)
        #expect(network.nameservers.isEmpty)
        #expect(network.searchDomains.isEmpty)
        #expect(network.hostname == nil)

        // And nothing empty survives the encode either.
        let drive = SandboxConfigDrive(
            sandboxId: "sb-11", identityNonce: "n", guestConfig: guestConfig(), spec: spec(),
            network: network)
        let obj = try #require(
            try JSONSerialization.jsonObject(with: try drive.encoded()) as? [String: Any])
        let block = try #require(obj["network"] as? [String: Any])
        #expect(block["mtu"] == nil)
        #expect(block["hostname"] == nil)
        let v4 = try #require(block["ipv4"] as? [String: Any])
        #expect(v4["gateway"] == nil)
    }

    /// A dual-stack network allocates /64s, and the VM path's seed already
    /// falls back to that when the prefix is missing.
    @Test("a missing IPv6 prefix length falls back to /64")
    func ipv6PrefixDefaultsTo64() throws {
        let network = try SandboxConfigDrive.network(
            for: attachment(ip6Address: "fd12::5", prefixLength6: nil), hostname: nil)
        #expect(network.ipv6?.prefixLength == 64)
    }

    /// The config drive and the fork's `reidentify` must agree, or a restored
    /// guest would come up under a different name than it booted with.
    @Test("the guest hostname is a DNS-safe label derived from the sandbox id")
    func guestHostnameIsDerivedFromTheSandboxId() {
        #expect(
            SandboxConfigDrive.guestHostname(sandboxId: "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0")
                == "strato-0f1e2d3c4b5a")
        #expect(SandboxConfigDrive.guestHostname(sandboxId: "ab").count <= 63)
    }
}
