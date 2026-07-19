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

        #expect(obj["schema_version"] as? Int == 1)
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
        #expect(decoded.schemaVersion == 1)
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
}
