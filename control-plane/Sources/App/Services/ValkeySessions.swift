import Foundation
import Valkey
import Vapor

/// Valkey-backed session storage, replacing vapor/redis's `.redis` driver
/// (which has no Vapor-5-era successor). Wire format is kept compatible with
/// that driver — the same `vrs-` key prefix and JSON-encoded `SessionData`
/// values, and no TTL — so sessions created before the swap keep working.
///
/// `SessionDriver` is still an `EventLoopFuture` protocol in Vapor 4, so each
/// method bridges to async with `makeFutureWithTask`; the driver itself does
/// no future composition.
struct ValkeySessionDriver: SessionDriver {
    let client: ValkeyClient

    private func key(for sessionID: SessionID) -> ValkeyKey {
        ValkeyKey("vrs-\(sessionID.string)")
    }

    func createSession(_ data: SessionData, for request: Request) -> EventLoopFuture<SessionID> {
        let sessionID = SessionID(string: [UInt8].random(count: 32).base64)
        return request.eventLoop.makeFutureWithTask {
            let json = try JSONEncoder().encode(data)
            _ = try await client.set(key(for: sessionID), value: json)
            return sessionID
        }
    }

    func readSession(_ sessionID: SessionID, for request: Request) -> EventLoopFuture<SessionData?> {
        request.eventLoop.makeFutureWithTask {
            guard let stored = try await client.get(key(for: sessionID)) else {
                return nil
            }
            return try JSONDecoder().decode(SessionData.self, from: ByteBuffer(stored))
        }
    }

    func updateSession(_ sessionID: SessionID, to data: SessionData, for request: Request) -> EventLoopFuture<SessionID>
    {
        request.eventLoop.makeFutureWithTask {
            let json = try JSONEncoder().encode(data)
            _ = try await client.set(key(for: sessionID), value: json)
            return sessionID
        }
    }

    func deleteSession(_ sessionID: SessionID, for request: Request) -> EventLoopFuture<Void> {
        request.eventLoop.makeFutureWithTask {
            _ = try await client.del(keys: [key(for: sessionID)])
        }
    }
}

extension Application.Sessions.Provider {
    /// Session storage in Valkey via the shared `app.valkey` client.
    static var valkey: Self {
        .init {
            $0.sessions.use { app in
                ValkeySessionDriver(client: app.valkey)
            }
        }
    }
}
