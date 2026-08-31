import Fluent
import Foundation
import SQLKit
import StratoShared

/// Fleet-wide workload-NIC MAC allocation.
///
/// The ledger's primary key spans VM and sandbox interfaces, so unlike IPAM no
/// fleet-wide advisory lock is needed. `ON CONFLICT DO NOTHING` is important:
/// catching a unique violation inside PostgreSQL would leave the surrounding
/// create transaction aborted and unable to redraw. A losing draw instead
/// returns no row and can retry in the same transaction.
enum MACAllocator {
    static let ledgerTable = "mac_address_allocations"
    static let defaultMaximumAttempts = 64

    enum OwnerKind: String, Sendable {
        case vmInterface = "vm"
        case sandboxInterface = "sandbox"
    }

    enum AllocationError: Error, LocalizedError, Equatable {
        case postgresRequired
        case attemptsExhausted(Int)

        var errorDescription: String? {
            switch self {
            case .postgresRequired:
                return "MAC allocation requires PostgreSQL"
            case .attemptsExhausted(let attempts):
                return "Could not allocate a unique MAC address after \(attempts) attempts"
            }
        }
    }

    static func allocate(
        for ownerKind: OwnerKind,
        ownerID: UUID,
        on database: any Database,
        maximumAttempts: Int = defaultMaximumAttempts,
        candidate: @Sendable () async -> MACAddress = { generateCandidate() }
    ) async throws -> MACAddress {
        precondition(maximumAttempts >= 1)
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            throw AllocationError.postgresRequired
        }

        for _ in 0..<maximumAttempts {
            let address = await candidate()
            // The candidate seam is useful for collision tests, but it must
            // not become a way for a caller to bypass the allocation policy.
            guard address.isLocallyAdministered else { continue }
            let inserted = try await sql.raw(
                """
                INSERT INTO mac_address_allocations (
                    mac_address, owner_kind, owner_id, created_at
                ) VALUES (
                    \(bind: address.description), \(bind: ownerKind.rawValue), \(bind: ownerID), now()
                )
                ON CONFLICT DO NOTHING
                RETURNING mac_address
                """
            ).first(decodingColumn: "mac_address", as: String.self)
            if inserted != nil { return address }
        }

        throw AllocationError.attemptsExhausted(maximumAttempts)
    }

    /// `02` is the locally administered, unicast prefix. All remaining 40 bits
    /// are random; uniqueness comes from the ledger, not from probability.
    static func generateCandidate() -> MACAddress {
        let suffix = (0..<5).map { _ in String(format: "%02x", Int(UInt8.random(in: .min ... .max))) }
        guard let address = MACAddress(allocated: "02:\(suffix.joined(separator: ":"))") else {
            preconditionFailure("MACAllocator constructed an invalid local-unicast address")
        }
        return address
    }
}
