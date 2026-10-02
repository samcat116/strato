import Foundation
import Logging
import StratoShared
import Testing
@testable import StratoAgentCore

@Suite("Strato guest-agent bootstrap")
struct GuestAgentBootstrapTests {
    @Test(
        arguments: [
            nil, "#cloud-config\npackages: [nginx]\n", "#!/bin/sh\necho tenant\n",
            "MIME-Version: 1.0\nContent-Type: multipart/mixed; boundary=tenant\n\n--tenant\nContent-Type: text/cloud-config\n\n#cloud-config\nruncmd: [echo tenant]\n--tenant--\n",
        ] as [String?])
    func preservesUserDataAndDeliveryParity(userData: String?) throws {
        let release = GuestAgentBootstrap.defaultRelease
        let iso = try CloudInitProvisioner.seedDocuments(
            metadataSource: .iso, vmId: "test", hostname: nil, sshAuthorizedKeys: [],
            userData: userData, networkAttachments: [], guestAgentRelease: release)
        let metadata = InstanceMetadata(
            instanceId: UUID(), projectId: UUID(), userData: userData,
            guestAgentRelease: release, serviceEnabled: true)
        #expect(iso["user-data"] == CloudInitProvisioner.userDataDocument(for: metadata))
        #expect(iso["user-data"]!.contains("filename=\"strato-guest-agent-install.sh\""))
        if let userData { #expect(iso["user-data"]!.contains(userData.trimmingCharacters(in: .newlines))) }
        let optedOut = CloudInitProvisioner.userDataDocument(sshAuthorizedKeys: [], userData: userData)
        #expect(!optedOut.contains("strato-guest-agent-install.sh"))
        if userData?.hasPrefix("MIME-Version") == true { #expect(optedOut == userData) }
    }

    @Test func nestedMIMEKeepsBothExecutableLeafParts() throws {
        let tenant =
            "MIME-Version: 1.0\nContent-Type: multipart/mixed; boundary=tenant\n\n--tenant\nContent-Type: text/x-shellscript\nContent-Disposition: attachment; filename=tenant.sh\n\n#!/bin/sh\necho tenant\n--tenant--\n"
        let document = CloudInitProvisioner.userDataDocument(
            sshAuthorizedKeys: [], userData: tenant,
            guestAgentRelease: GuestAgentBootstrap.defaultRelease)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("strato-mime-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try document.write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", "-c",
            """
            import email, sys
            with open(sys.argv[1]) as f: message = email.message_from_file(f)
            leaves = [part for part in message.walk() if not part.is_multipart()]
            assert len(leaves) == 2
            assert leaves[0].get_filename() == 'tenant.sh'
            assert leaves[0].get_payload().strip() == '#!/bin/sh\\necho tenant'
            assert leaves[1].get_filename() == 'strato-guest-agent-install.sh'
            assert 'exec-capable ROOT daemon' in leaves[1].get_payload()
            """, file.path,
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func imdsStubDoesNotDuplicateInstallation() throws {
        let docs = try CloudInitProvisioner.seedDocuments(
            metadataSource: .imds, noCloudSeedToken: UUID(),
            vmId: "test", hostname: nil, sshAuthorizedKeys: [], userData: "#!/bin/sh\necho tenant",
            networkAttachments: [], guestAgentRelease: GuestAgentBootstrap.defaultRelease)
        #expect(docs["user-data"] == "")
    }
}

private actor ProbeConnection: GuestLineConnection {
    let response: String?
    var closed = false
    var requests: [Data] = []
    init(_ response: String?) { self.response = response }
    func write(_ data: Data) { requests.append(data) }
    func nextLine(timeout: TimeInterval?) -> String? { response }
    func close() { closed = true }
}

@Suite("Strato guest-agent reachability")
struct GuestAgentProbeTests {
    @Test(
        arguments: [
            nil, "{}", "{\"type\":\"pong\",\"sandbox_id\":\"vm\",\"nonce\":\"n\",\"control_protocol_version\":4}",
        ] as [String?])
    func probeRequiresProtocolPong(response: String?) async throws {
        let connection = ProbeConnection(response)
        let result = try await GuestAgentProbe.check(cid: 42, logger: Logger(label: "test")) { _, _, _, _ in connection
        }
        #expect(result.reachable == (response?.contains("pong") == true))
        #expect(await connection.closed)
        #expect(await connection.requests == [GuestControlProtocol.Request.ping.encodedLine()])
    }

    @Test func cancellationIsNotReportedAsUnreachable() async {
        do {
            _ = try await GuestAgentProbe.check(cid: 42, logger: Logger(label: "test")) { _, _, _, _ in
                throw CancellationError()
            }
            // Connector cancellation itself must propagate even if the caller task is not cancelled.
            Issue.record("Cancellation must propagate")
        } catch is CancellationError {} catch { Issue.record("Wrong cancellation error: \(error)") }
    }
}
