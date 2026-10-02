import Foundation
import StratoAPIClient
import StratoShared

/// Uses the shared STR-90 validator rather than defining a second CLI schema.
public enum GuestConfigurationInput {
    public static let maxDocumentBytes = 1_048_576

    /// Empty intent withdraws management. The generated Swift encoder omits a
    /// nil nullable property, which would violate the required request envelope.
    public static func withdrawal() throws -> Components.Schemas.ReplaceVMGuestConfigurationRequest {
        try decode(Data("{\"packages\":[],\"files\":[],\"services\":[],\"sysctls\":[]}".utf8))
    }

    public static func decode(_ data: Data) throws -> Components.Schemas.ReplaceVMGuestConfigurationRequest {
        guard data.count <= maxDocumentBytes else {
            throw CLIError.config("Guest configuration JSON exceeds 1 MiB")
        }
        do {
            let config = try JSONDecoder().decode(GuestConfig.self, from: data)
            let encoded = try JSONEncoder().encode(config)
            let wire = try JSONDecoder().decode(Components.Schemas.GuestConfig.self, from: encoded)
            return .init(guestConfig: .init(value1: wire))
        } catch let error as GuestConfigValidationError {
            throw CLIError.config(error.description)
        } catch {
            throw CLIError.config(
                "Invalid guest configuration JSON; packages, files, services and sysctls arrays are required")
        }
    }

    public static func read(file: String) throws -> Components.Schemas.ReplaceVMGuestConfigurationRequest {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file)) } catch {
            throw CLIError.config("Unable to open guest configuration file")
        }
        defer { try? handle.close() }
        let data: Data
        do { data = try handle.read(upToCount: maxDocumentBytes + 1) ?? Data() } catch {
            throw CLIError.config("Unable to read guest configuration file")
        }
        return try decode(data)
    }
}
