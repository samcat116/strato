import Foundation

/// Diagnostic for the SPIRE agent's Delegated Identity API: does this node's
/// spire-agent accept strato-agent as a delegate, and will it hand over an SVID
/// minted for a workload it could never attest directly?
///
/// This is the node-side proof behind `docs/architecture/guest-identity.md`.
/// Everything it reports is either configuration the operator can fix or
/// evidence that the mechanism works; the answer is deliberately one of four
/// distinct outcomes, because the interesting failure — "the API answered, and
/// no entry matched" — is not an error at the RPC layer and would otherwise
/// read as success.
public enum DelegatedIdentityProbe {
    /// One SVID the delegate received, reduced to what is safe to print.
    public struct IdentityReport: Equatable, Sendable {
        public let spiffeID: String
        public let expiresAt: Date
        public let chainLength: Int

        /// The private key's length in bytes, and nothing else.
        ///
        /// SPIRE hands the delegate a real PKCS#8 private key. This report gets
        /// pasted into issues and PR descriptions, so the key is not carried in
        /// the value type at all — a formatter cannot leak what it was never
        /// given.
        public let privateKeyDERByteCount: Int

        public let federatesWith: [String]

        public init(
            spiffeID: String,
            expiresAt: Date,
            chainLength: Int,
            privateKeyDERByteCount: Int,
            federatesWith: [String]
        ) {
            self.spiffeID = spiffeID
            self.expiresAt = expiresAt
            self.chainLength = chainLength
            self.privateKeyDERByteCount = privateKeyDERByteCount
            self.federatesWith = federatesWith
        }
    }

    /// Why the probe did not reach a conclusive answer, or — for
    /// `noEntryMatched` — which conclusive-but-negative answer it reached.
    public enum Outcome: String, Equatable, Sendable {
        /// SVIDs were received. The mechanism works on this node.
        case ok
        /// SPIRE refused this process as a delegate.
        case refused
        /// The admin socket is absent or unreachable.
        case unavailable
        /// SPIRE answered, and no registration entry matched the selectors.
        /// A normal answer from this API, and never a success.
        case noEntryMatched
        /// Anything else — a transport or parsing failure.
        case failed
    }

    public struct Report: Equatable, Sendable {
        public let socketPath: String
        public let socketPresent: Bool
        public let selectors: [String]
        public let identities: [IdentityReport]

        /// Trust domains the node is tracking, by bare name, with the number of
        /// X.509 authorities in each. Empty when the bundle stream was not
        /// reached (a refusal short-circuits it).
        public let trustDomains: [String: Int]

        public let outcome: Outcome

        /// Operator-actionable detail, when there is any beyond the outcome.
        public let detail: String?

        public var succeeded: Bool { outcome == .ok && !identities.isEmpty }

        public init(
            socketPath: String,
            socketPresent: Bool,
            selectors: [String],
            identities: [IdentityReport] = [],
            trustDomains: [String: Int] = [:],
            outcome: Outcome,
            detail: String? = nil
        ) {
            self.socketPath = socketPath
            self.socketPresent = socketPresent
            self.selectors = selectors
            self.identities = identities
            self.trustDomains = trustDomains
            self.outcome = outcome
            self.detail = detail
        }
    }

    /// Run the probe. Never throws: every failure mode is a reportable outcome,
    /// because "what does SPIRE say when this is misconfigured" is exactly the
    /// question the probe exists to answer.
    public static func probe(
        client: DelegatedIdentitySPIFFEClient,
        selectors: [DelegatedSelector]
    ) async -> Report {
        let socketPath = await client.adminSocketPath
        let socketPresent = FileManager.default.fileExists(atPath: socketPath)
        let selectorStrings = selectors.map(\.description)

        let svids: [DelegatedX509SVID]
        do {
            svids = try await client.fetchX509SVIDs(selectors: selectors)
        } catch let error as SPIFFEError {
            return Report(
                socketPath: socketPath,
                socketPresent: socketPresent,
                selectors: selectorStrings,
                outcome: outcome(for: error),
                detail: error.localizedDescription
            )
        } catch {
            return Report(
                socketPath: socketPath,
                socketPresent: socketPresent,
                selectors: selectorStrings,
                outcome: .failed,
                detail: "\(error)"
            )
        }

        let identities = svids.map(makeIdentityReport)

        // Bundles are best-effort: a node that hands over an SVID but cannot
        // serve its bundle stream is still a working delegate grant, and saying
        // so beats collapsing two independent results into one failure.
        var trustDomains: [String: Int] = [:]
        var bundleDetail: String?
        do {
            for (domain, bundle) in try await client.fetchTrustBundles() {
                trustDomains[domain] = bundle.x509Authorities.count
            }
        } catch {
            bundleDetail = "trust bundle stream unavailable: \(error)"
        }

        return Report(
            socketPath: socketPath,
            socketPresent: socketPresent,
            selectors: selectorStrings,
            identities: identities,
            trustDomains: trustDomains,
            outcome: identities.isEmpty ? .noEntryMatched : .ok,
            detail: bundleDetail
        )
    }

    /// Reduce one SVID to the printable report. The key never leaves this
    /// function.
    public static func makeIdentityReport(_ svid: DelegatedX509SVID) -> IdentityReport {
        IdentityReport(
            spiffeID: svid.spiffeID.uri,
            expiresAt: svid.expiresAt,
            chainLength: svid.certificateChain.count,
            privateKeyDERByteCount: derByteCount(pem: svid.privateKey),
            federatesWith: svid.federatesWith
        )
    }

    private static func outcome(for error: SPIFFEError) -> Outcome {
        switch error {
        case .delegateNotAuthorized: return .refused
        case .workloadAPIUnavailable: return .unavailable
        default: return .failed
        }
    }

    /// Length of the DER payload inside a PEM block, without retaining it.
    static func derByteCount(pem: String) -> Int {
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: body)?.count ?? 0
    }

    // MARK: - Formatting

    public static func format(_ report: Report, now: Date = Date()) -> String {
        var lines: [String] = ["SPIRE delegated identity probe"]
        lines.append(
            "  admin socket   \(report.socketPath) (\(report.socketPresent ? "present" : "absent"))")
        lines.append("  selectors      \(report.selectors.joined(separator: "  "))")
        lines.append("  identities     \(report.identities.count)")

        for identity in report.identities {
            lines.append("    \(identity.spiffeID)")
            lines.append(
                "      expires    \(iso8601(identity.expiresAt)) (in \(relative(identity.expiresAt, from: now)))"
            )
            lines.append("      chain      \(identity.chainLength) certificate(s)")
            lines.append(
                "      key        \(identity.privateKeyDERByteCount)-byte PKCS#8 private key received (not printed)"
            )
            let federates =
                identity.federatesWith.isEmpty
                ? "(none)" : identity.federatesWith.sorted().joined(separator: ", ")
            lines.append("      federates  \(federates)")
        }

        if report.trustDomains.isEmpty {
            lines.append("  trust bundles  (none)")
        } else {
            let rendered = report.trustDomains.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value) X.509 authorit\($0.value == 1 ? "y" : "ies")" }
                .joined(separator: ", ")
            lines.append("  trust bundles  \(rendered)")
        }

        if let detail = report.detail {
            lines.append("  detail         \(detail)")
        }

        lines.append("")
        lines.append(verdict(report))
        return lines.joined(separator: "\n")
    }

    /// The single line that says what happened. Each failure names its fix,
    /// because this is the entire operator experience of a misconfigured node.
    public static func verdict(_ report: Report) -> String {
        switch report.outcome {
        case .ok:
            return "DELEGATED IDENTITY OK"
        case .refused:
            return
                "DELEGATED IDENTITY REFUSED — this agent's SPIFFE ID is not in authorized_delegates "
                + "in the agent { } block of /etc/spire/agent.conf"
        case .unavailable:
            return
                "DELEGATED IDENTITY UNAVAILABLE — admin_socket_path is not configured on this node's "
                + "spire-agent (it must not live under the Workload API socket's directory)"
        case .noEntryMatched:
            return
                "NO ENTRY MATCHED — no registration entry with these selectors has synced to this node; "
                + "check the entry's parentID is spiffe://<trust-domain>/node/<this-node>"
        case .failed:
            return "DELEGATED IDENTITY FAILED"
        }
    }

    public static func formatJSON(_ report: Report) throws -> String {
        var identities: [[String: Any]] = []
        for identity in report.identities {
            identities.append([
                "spiffeID": identity.spiffeID,
                "expiresAt": iso8601(identity.expiresAt),
                "chainLength": identity.chainLength,
                "privateKeyDERByteCount": identity.privateKeyDERByteCount,
                "federatesWith": identity.federatesWith,
            ])
        }

        var payload: [String: Any] = [
            "socketPath": report.socketPath,
            "socketPresent": report.socketPresent,
            "selectors": report.selectors,
            "identities": identities,
            "trustDomains": report.trustDomains,
            "outcome": report.outcome.rawValue,
            "succeeded": report.succeeded,
            "verdict": verdict(report),
        ]
        if let detail = report.detail {
            payload["detail"] = detail
        }

        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private static func relative(_ date: Date, from now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now).rounded())
        if seconds <= 0 { return "expired" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h\((seconds % 3600) / 60)m"
    }
}
