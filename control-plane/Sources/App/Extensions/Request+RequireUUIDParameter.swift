import Foundation
import Vapor

extension Request {
    /// A UUID route parameter, preserving the caller's error text for missing or malformed values.
    func requireUUIDParameter(_ name: String, reason: String) throws -> UUID {
        guard let value = parameters.get(name, as: UUID.self) else {
            throw Abort(.badRequest, reason: reason)
        }
        return value
    }
}
