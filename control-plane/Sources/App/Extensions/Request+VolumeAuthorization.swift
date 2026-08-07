import Fluent
import Vapor

extension Request {
    /// Fetch a volume and enforce a permission on it in one call, through the
    /// evaluator.
    ///
    /// The per-handler defense-in-depth complement to
    /// `AuthorizationMiddleware`, mirroring `authorizedVM(_:permission:)` and
    /// `authorizedSandbox(_:permission:)`. Added with STR-148, when volumes
    /// became a resource the operations façade can be asked about by id and so
    /// needed the same by-id authorization the other two kinds have.
    ///
    /// - Throws: `.unauthorized` if unauthenticated, `.notFound` if the volume
    ///   does not exist, `.forbidden` if the user lacks `permission` on it.
    func authorizedVolume(_ volumeID: UUID, permission: String) async throws -> Volume {
        guard let volume = try await Volume.find(volumeID, on: db) else {
            throw Abort(.notFound)
        }

        try await authorize(permission, on: "volume", id: volume.id?.uuidString ?? "")

        return volume
    }
}
