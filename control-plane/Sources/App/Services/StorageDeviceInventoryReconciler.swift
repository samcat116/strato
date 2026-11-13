import Fluent
import Foundation
import SQLKit
import StratoShared
import Vapor

enum StorageDeviceInventoryError: Error {
    case invalidObservation(String)
    case unsupportedDatabase
}

/// Applies one authoritative, successfully enumerated whole-disk snapshot.
/// Validation is deliberately complete before the transaction starts: a bad
/// row cannot turn omission of the remaining rows into disappearance.
struct StorageDeviceInventoryReconciler: Sendable {
    private let database: any Database

    init(application: Application) {
        database = application.db
    }

    init(database: any Database) {
        self.database = database
    }

    func apply(
        _ observations: [ObservedStorageDevice],
        for agent: Agent,
        receivedAt: Date
    ) async throws {
        let validated = try Self.validate(observations)
        let agentID = try agent.requireID()

        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw StorageDeviceInventoryError.unsupportedDatabase
            }
            // Serialize inventory merge and operator eligibility mutation for
            // this agent. Fluent reloads the rows below on this transaction.
            try await sql.raw(
                "SELECT id FROM storage_devices WHERE agent_id = \(bind: agentID) FOR UPDATE"
            ).run()

            let existing = try await StorageDevice.query(on: transaction)
                .filter(\.$agent.$id == agentID)
                .all()
            var stableByIdentity: [StorageDeviceIdentity: StorageDevice] = [:]
            var presentAnonymousByPath: [String: StorageDevice] = [:]
            for device in existing {
                if let identity = device.identity {
                    stableByIdentity[identity] = device
                } else if device.present, presentAnonymousByPath[device.devicePath] == nil {
                    presentAnonymousByPath[device.devicePath] = device
                }
            }

            var seen = Set<UUID>()
            for item in validated {
                let device: StorageDevice
                if let identity = item.observation.optionalIdentity,
                    let stored = stableByIdentity[identity]
                {
                    device = stored
                } else if !item.observation.hasIdentity,
                    let stored = presentAnonymousByPath[item.observation.devicePath]
                {
                    device = stored
                } else {
                    device = StorageDevice(
                        agentID: agentID,
                        identityKind: item.observation.optionalIdentity?.kind,
                        identityValue: item.observation.optionalIdentity?.value,
                        devicePath: item.observation.devicePath,
                        sizeBytes: item.observation.sizeBytes,
                        model: item.observation.optionalModel,
                        serial: item.observation.optionalSerial,
                        wwn: item.observation.optionalWwn,
                        rotational: item.observation.rotational,
                        uses: item.uses,
                        state: item.observation.state,
                        present: true,
                        lastSeenAt: receivedAt)
                }

                device.devicePath = item.observation.devicePath
                device.sizeBytes = item.observation.sizeBytes
                device.model = item.observation.optionalModel
                device.serial = item.observation.optionalSerial
                device.wwn = item.observation.optionalWwn
                device.rotational = item.observation.rotational
                device.uses = item.uses
                device.state = item.observation.state
                device.present = true
                device.lastSeenAt = receivedAt
                if !item.observation.hasIdentity {
                    device.identityKind = nil
                    device.identityValue = nil
                    device.role = .unassigned
                    device.osdId = nil
                }

                try await device.save(on: transaction)
                seen.insert(try device.requireID())
            }

            for device in existing where device.present {
                let id = try device.requireID()
                guard !seen.contains(id) else { continue }
                device.present = false
                try await device.save(on: transaction)
            }
        }
    }

    private static func validate(
        _ observations: [ObservedStorageDevice]
    ) throws -> [ValidatedObservation] {
        var identities = Set<StorageDeviceIdentity>()
        var paths = Set<String>()
        var result: [ValidatedObservation] = []
        result.reserveCapacity(observations.count)

        for observation in observations {
            do { try observation.validateProtocol() } catch {
                throw StorageDeviceInventoryError.invalidObservation("invalid protocol fields")
            }
            guard observation.devicePath.hasPrefix("/dev/"), observation.devicePath.count > 5 else {
                throw StorageDeviceInventoryError.invalidObservation("invalid device path")
            }
            guard paths.insert(observation.devicePath).inserted else {
                throw StorageDeviceInventoryError.invalidObservation("duplicate device path")
            }
            guard observation.sizeBytes >= 0 else {
                throw StorageDeviceInventoryError.invalidObservation("negative device size")
            }

            let preferredIdentity = StorageDeviceIdentity.preferred(
                wwn: observation.optionalWwn,
                serial: observation.optionalSerial)
            guard observation.optionalIdentity == preferredIdentity else {
                throw StorageDeviceInventoryError.invalidObservation("identity does not match raw facts")
            }
            if let identity = observation.optionalIdentity,
                !identities.insert(identity).inserted
            {
                throw StorageDeviceInventoryError.invalidObservation("duplicate stable identity")
            }

            let uniqueUses = Set(observation.uses.values)
            guard uniqueUses.count == observation.uses.values.count else {
                throw StorageDeviceInventoryError.invalidObservation("duplicate device use")
            }
            switch observation.state {
            case .available:
                guard observation.sizeBytes > 0, uniqueUses.isEmpty else {
                    throw StorageDeviceInventoryError.invalidObservation("available device has use or zero size")
                }
            case .inUse:
                guard observation.sizeBytes > 0, !uniqueUses.isEmpty else {
                    throw StorageDeviceInventoryError.invalidObservation("in-use device has no use or zero size")
                }
            case .faulted:
                break
            case .unspecified, .UNRECOGNIZED:
                throw StorageDeviceInventoryError.invalidObservation("unknown device state")
            case .draining:
                throw StorageDeviceInventoryError.invalidObservation("agent cannot report draining")
            }

            result.append(
                ValidatedObservation(
                    observation: observation,
                    uses: uniqueUses.sorted { $0.protocolValue < $1.protocolValue }))
        }
        return result
    }
}

private struct ValidatedObservation: Sendable {
    let observation: ObservedStorageDevice
    let uses: [StorageDeviceUse]
}
