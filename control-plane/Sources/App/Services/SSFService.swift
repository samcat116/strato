import Fluent
import Foundation
import NIOConcurrencyHelpers
import SwiftSSF
import Vapor

/// Shared Signals Framework receiver integration (issue #38).
///
/// Wraps swift-ssf's `SSFReceiver` for each configured `SSFStream`: stream
/// registration against the transmitter's management API, verification of
/// inbound Security Event Tokens (push delivery), and a periodic cluster-
/// singleton sweep that drains poll-delivery streams (RFC 8936).
///
/// Configuration (environment):
/// - `SSF_CALLBACK_BASE_URL` — public base URL for push delivery endpoints
///   (falls back to `WEBAUTHN_RELYING_PARTY_ORIGIN`).
/// - `SSF_POLL_INTERVAL_SECONDS` — poll sweep cadence, default 60.
/// - `SSF_POLL_ENABLED` — force the poll sweep on/off; defaults to on except
///   under `.testing` (tests drive `sweepPollStreams()` directly).
/// - `SSF_ALLOW_UNVERIFIED_TOKENS` — accept unsigned SETs; honored only
///   under `.testing`.
/// SSRF guard for transmitter base URLs: streams drive server-side HTTP
/// requests (discovery, stream management, polling), so an org admin must not
/// be able to point Strato at internal or metadata services, nor leak the
/// management bearer token over cleartext. Same approach as OIDC discovery:
/// HTTPS only, host allow-listed. `SSF_TRANSMITTER_ALLOWED_HOSTS` /
/// `SSF_TRANSMITTER_ALLOWED_SUFFIXES` override the OIDC discovery defaults.
enum SSFValidation {
    /// `label` names the URL in error messages; the same rules cover every
    /// URL the receiver fetches, including transmitter-returned poll
    /// endpoints — a compromised transmitter must not be able to point the
    /// recurring sweep at internal services either.
    static func validateTransmitterURL(_ raw: String, label: String = "transmitterURL") throws {
        guard let url = URL(string: raw),
            url.scheme?.lowercased() == "https",
            let host = url.host?.lowercased()
        else {
            throw Abort(.unprocessableEntity, reason: "\(label) must be a valid HTTPS URL")
        }

        let allowedHosts =
            Environment.get("SSF_TRANSMITTER_ALLOWED_HOSTS")
            .map { Set(OIDCValidation.parseAllowList($0)) } ?? OIDCValidation.allowedHosts()
        let allowedSuffixes =
            Environment.get("SSF_TRANSMITTER_ALLOWED_SUFFIXES")
            .map(OIDCValidation.parseAllowList) ?? OIDCValidation.allowedDomainSuffixes()

        guard allowedHosts.contains(host) || allowedSuffixes.contains(where: { host.hasSuffix($0) })
        else {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "\(label) host is not in the allowed list for security reasons. "
                    + "Set SSF_TRANSMITTER_ALLOWED_HOSTS or SSF_TRANSMITTER_ALLOWED_SUFFIXES "
                    + "to allow this host.")
        }
    }
}

actor SSFService {
    private let app: Application
    private var receivers: [UUID: SSFReceiver] = [:]
    private let pollTask = NIOLockedValueBox<Task<Void, Never>?>(nil)

    init(app: Application) {
        self.app = app
    }

    // MARK: - Receiver construction

    /// The receiver for a stream, cached so transmitter metadata and JWKS
    /// caches survive across events. Invalidate on config changes.
    func receiver(for stream: SSFStream) throws -> SSFReceiver {
        let id = try stream.requireID()
        if let cached = receivers[id] {
            return cached
        }

        // Re-validated here (not just at create) so rows predating a
        // tightened allow-list can't reach a now-disallowed host.
        try SSFValidation.validateTransmitterURL(stream.transmitterURL)
        guard let transmitterURL = URL(string: stream.transmitterURL) else {
            throw Abort(.unprocessableEntity, reason: "Invalid transmitter URL")
        }
        let allowUnverified =
            app.environment == .testing
            && Environment.get("SSF_ALLOW_UNVERIFIED_TOKENS").flatMap(Bool.init) == true
        let audience = stream.expectedAudienceArray
        let configuration = SSFReceiverConfiguration(
            transmitterURL: transmitterURL,
            authToken: stream.authToken,
            expectedIssuer: stream.expectedIssuer.flatMap(URL.init(string:)),
            expectedAudience: audience.isEmpty ? nil : audience,
            allowUnverifiedTokens: allowUnverified,
            httpClient: app.http.client.shared
        )
        let receiver = SSFReceiver(configuration: configuration)
        receivers[id] = receiver
        return receiver
    }

    /// Drop the cached receiver after the stream's configuration changed or
    /// the stream was deleted.
    func invalidateReceiver(for streamID: UUID) {
        receivers[streamID] = nil
    }

    // MARK: - Push delivery (RFC 8935)

    /// Parse, verify, and act on one inbound SET. Throws `SSFError` for the
    /// controller to translate into an RFC 8935 error response.
    func processInboundToken(_ token: String, stream: SSFStream) async throws {
        let receiver = try self.receiver(for: stream)
        let processor = SSFSignalProcessor(
            app: app,
            streamID: try stream.requireID(),
            organizationID: stream.$organization.id
        )
        try await receiver.processSecurityEventToken(token, handler: processor)
    }

    /// The public URL a transmitter delivers push events to for a stream, or
    /// nil when no public base URL is configured.
    nonisolated static func pushEndpointURL(for streamID: UUID) -> String? {
        let base =
            Environment.get("SSF_CALLBACK_BASE_URL")
            ?? Environment.get("WEBAUTHN_RELYING_PARTY_ORIGIN")
        guard let base, !base.isEmpty else { return nil }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return "\(trimmed)/ssf/events/\(streamID.uuidString)"
    }

    // MARK: - Stream management against the transmitter

    /// Register the stream with its transmitter. For push streams this
    /// generates (or rotates) the inbound bearer token and returns it —
    /// the only time the plaintext token is available. Re-registering an
    /// already-registered stream deletes the old remote stream first
    /// (best-effort).
    func registerStream(_ stream: SSFStream, on db: Database) async throws -> String? {
        guard let method = stream.deliveryMethodValue else {
            throw Abort(.unprocessableEntity, reason: "Unknown delivery method: \(stream.deliveryMethod)")
        }
        let receiver = try self.receiver(for: stream)

        if let existing = stream.remoteStreamID {
            try? await receiver.deleteStream(id: existing)
            // Persist the unregistered state before attempting the
            // replacement: if createStream fails below, the row must not
            // keep claiming a remote stream that was just deleted — and the
            // old push token must stop authenticating deliveries.
            stream.remoteStreamID = nil
            stream.pollEndpoint = nil
            stream.verifiedAt = nil
            stream.pushTokenHash = nil
            stream.pushTokenPrefix = nil
            try await stream.save(on: db)
        }

        var pushToken: String?
        let delivery: DeliveryConfiguration
        switch method {
        case .push:
            guard let endpoint = Self.pushEndpointURL(for: try stream.requireID()),
                let endpointURL = URL(string: endpoint)
            else {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Push delivery requires a public callback URL; set SSF_CALLBACK_BASE_URL "
                        + "(or WEBAUTHN_RELYING_PARTY_ORIGIN)")
            }
            let token = SSFStream.generatePushToken()
            pushToken = token
            stream.pushTokenHash = SSFStream.hashPushToken(token)
            stream.pushTokenPrefix = SSFStream.extractPushTokenPrefix(token)
            delivery = DeliveryConfiguration(
                method: .push,
                endpoint_url: endpointURL,
                authorization_header: "Bearer \(token)"
            )
        case .poll:
            delivery = DeliveryConfiguration(method: .poll)
        }

        let events = stream.eventsRequestedArray
        let configuration = try await receiver.createStream(
            eventsRequested: events.isEmpty ? nil : events,
            delivery: delivery,
            description: stream.description
        )

        stream.remoteStreamID = configuration.stream_id
        stream.pollEndpoint = nil
        if method == .poll, let endpoint = configuration.delivery?.endpoint_url?.absoluteString {
            // The poll endpoint is transmitter-controlled; hold it to the
            // same HTTPS/allow-list rules as the transmitter itself. On
            // failure, undo the remote registration we just made.
            do {
                try SSFValidation.validateTransmitterURL(endpoint, label: "Transmitter poll endpoint")
            } catch {
                try? await receiver.deleteStream(id: configuration.stream_id)
                stream.remoteStreamID = nil
                try await stream.save(on: db)
                throw error
            }
            stream.pollEndpoint = endpoint
        }
        stream.verifiedAt = nil
        stream.lastError = nil
        try await stream.save(on: db)
        return pushToken
    }

    /// Ask the transmitter to send a verification event on this stream.
    func requestVerification(of stream: SSFStream) async throws {
        guard let remoteID = stream.remoteStreamID else {
            throw Abort(.conflict, reason: "Stream is not registered with the transmitter")
        }
        let receiver = try self.receiver(for: stream)
        try await receiver.verifyStream(id: remoteID, state: UUID().uuidString)
    }

    func streamStatus(of stream: SSFStream) async throws -> StreamStatusResponse {
        guard let remoteID = stream.remoteStreamID else {
            throw Abort(.conflict, reason: "Stream is not registered with the transmitter")
        }
        let receiver = try self.receiver(for: stream)
        return try await receiver.getStreamStatus(id: remoteID)
    }

    /// Delete the stream at the transmitter, tolerating failure — the local
    /// row is being removed either way.
    func deleteRemoteStream(_ stream: SSFStream) async {
        guard let remoteID = stream.remoteStreamID,
            let receiver = try? self.receiver(for: stream)
        else { return }
        do {
            try await receiver.deleteStream(id: remoteID)
        } catch {
            app.logger.warning(
                "Failed to delete SSF stream at transmitter; continuing with local delete",
                metadata: [
                    "streamID": .string(stream.id?.uuidString ?? ""),
                    "error": .string("\(error)"),
                ])
        }
    }

    // MARK: - Poll delivery (RFC 8936)

    /// Drain one poll-delivery stream: repeated one-shot polls until the
    /// transmitter reports no more events (bounded to keep a sweep pass from
    /// monopolizing a hot stream).
    @discardableResult
    func pollStream(_ stream: SSFStream, on db: Database) async throws -> SSFPollResultResponse {
        guard stream.deliveryMethodValue == .poll else {
            throw Abort(.unprocessableEntity, reason: "Not a poll-delivery stream")
        }
        guard stream.remoteStreamID != nil,
            let endpointRaw = stream.pollEndpoint
        else {
            throw Abort(.conflict, reason: "Stream is not registered with the transmitter")
        }
        // Re-validated on every use so stored endpoints predating a
        // tightened allow-list can't keep being polled.
        try SSFValidation.validateTransmitterURL(endpointRaw, label: "Transmitter poll endpoint")
        guard let endpoint = URL(string: endpointRaw) else {
            throw Abort(.unprocessableEntity, reason: "Invalid poll endpoint URL")
        }

        let receiver = try self.receiver(for: stream)
        let processor = SSFSignalProcessor(
            app: app,
            streamID: try stream.requireID(),
            organizationID: stream.$organization.id
        )

        var processed = 0
        var failed = 0
        var moreAvailable = false
        for _ in 0..<10 {
            let result = try await receiver.pollEvents(endpoint: endpoint, handler: processor)
            processed += result.processed
            failed += result.failed
            moreAvailable = result.moreAvailable
            if !moreAvailable { break }
        }
        return SSFPollResultResponse(processed: processed, failed: failed, moreAvailable: moreAvailable)
    }

    /// One pass over every enabled, registered poll stream. Cluster-singleton
    /// via the coordination sweep lock. Internal so tests can drive a pass
    /// directly.
    func sweepPollStreams() async {
        // The default sweep-lock TTL (25s) is tuned for quick local sweeps; a
        // poll pass makes network requests per stream and can outlive it,
        // letting another replica drain the same streams concurrently. Size
        // the TTL to the sweep cadence (slightly under, so this holder's next
        // tick can reacquire).
        let lockTTL = max(55, pollIntervalSeconds - 5)
        guard await app.coordination.acquireSweepLock("ssf_poll", ttlSeconds: lockTTL) else {
            return
        }

        let streams: [SSFStream]
        do {
            streams = try await SSFStream.query(on: app.db)
                .filter(\.$enabled == true)
                .filter(\.$deliveryMethod == SSFDeliveryMethod.poll.rawValue)
                .filter(\.$remoteStreamID != nil)
                .all()
        } catch {
            app.logger.error("SSF poll sweep failed to load streams: \(error)")
            return
        }

        for stream in streams {
            do {
                try await pollStream(stream, on: app.db)
            } catch {
                app.logger.warning(
                    "SSF poll failed",
                    metadata: [
                        "streamID": .string(stream.id?.uuidString ?? ""),
                        "error": .string("\(error)"),
                    ])
                stream.lastError = "\(error)"
                try? await stream.save(on: app.db)
            }
        }
    }

    // MARK: - Poll sweep lifecycle

    private var pollIntervalSeconds: Int {
        Environment.get("SSF_POLL_INTERVAL_SECONDS").flatMap(Int.init) ?? 60
    }

    private var pollSweepEnabled: Bool {
        Environment.get("SSF_POLL_ENABLED").flatMap(Bool.init) ?? (app.environment != .testing)
    }

    /// Arm the periodic poll sweep. Called once from the boot lifecycle.
    nonisolated func startPollSweep() {
        pollTask.withLockedValue { task in
            guard task == nil else { return }
            task = Task { [weak self] in
                guard let self, await self.pollSweepEnabled else { return }
                let interval = await self.pollIntervalSeconds
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(interval))
                    } catch {
                        break  // cancelled
                    }
                    await self.sweepPollStreams()
                }
            }
        }
    }

    /// Cancel the poll sweep so it never outlives the application.
    nonisolated func shutdown() {
        pollTask.withLockedValue { task in
            task?.cancel()
            task = nil
        }
    }
}

// MARK: - Application accessor / lifecycle

extension Application {
    private struct SSFServiceKey: StorageKey, LockKey {
        typealias Value = SSFService
    }

    var ssf: SSFService {
        lazyService(SSFServiceKey.self) { SSFService(app: self) }
    }

    /// The SSF service if something already created it. Shutdown must not
    /// instantiate the service just to shut it down.
    var ssfServiceIfCreated: SSFService? {
        storage[SSFServiceKey.self]
    }
}

/// Arms the SSF poll sweep at boot and cancels it at shutdown so the periodic
/// transmitter polling never outlives the application.
struct SSFPollLifecycleHandler: LifecycleHandler {
    func didBootAsync(_ application: Application) async throws {
        application.ssf.startPollSweep()
    }

    func shutdownAsync(_ application: Application) async {
        application.ssfServiceIfCreated?.shutdown()
    }
}
