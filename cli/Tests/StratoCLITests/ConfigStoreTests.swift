import Foundation
import Testing

@testable import StratoCLICore

@Suite("ConfigStore")
struct ConfigStoreTests {
    @Test("Round-trips contexts through TOML")
    func testRoundTrip() throws {
        try withTemporaryDirectory { directory in
            let store = ConfigStore(directory: directory)
            var config = CLIConfig()
            config.currentContext = "prod"
            config.contexts["prod"] = ContextConfig(
                server: "https://strato.example.com",
                organization: "0a1b2c3d",
                project: "9f8e7d6c")
            config.contexts["dev"] = ContextConfig(server: "http://localhost:8080")

            try store.save(config)
            let loaded = try store.load()

            #expect(loaded == config)
        }
    }

    @Test("Loading a missing file yields an empty config")
    func testMissingFile() throws {
        try withTemporaryDirectory { directory in
            let store = ConfigStore(directory: directory)
            let loaded = try store.load()
            #expect(loaded == CLIConfig())
        }
    }

    @Test("Values with quotes and backslashes survive the TOML writer")
    func testEscaping() throws {
        try withTemporaryDirectory { directory in
            let store = ConfigStore(directory: directory)
            var config = CLIConfig()
            config.contexts["odd"] = ContextConfig(server: #"https://x/"quoted"\path"#)
            try store.save(config)
            let loaded = try store.load()
            #expect(loaded.contexts["odd"]?.server == #"https://x/"quoted"\path"#)
        }
    }
}

@Suite("CredentialStore")
struct CredentialStoreTests {
    @Test("Stores, reads, and deletes per-context credentials")
    func testRoundTrip() throws {
        try withTemporaryDirectory { directory in
            let store = CredentialStore(directory: directory)
            let credentials = StoredCredentials(
                accessToken: "st_abc", refreshToken: "rt_abc",
                expiresAt: Date(timeIntervalSince1970: 2_000_000_000))

            try store.store(credentials, for: "prod")
            #expect(try store.credentials(for: "prod") == credentials)
            #expect(try store.credentials(for: "other") == nil)

            try store.delete(for: "prod")
            #expect(try store.credentials(for: "prod") == nil)
        }
    }

    @Test("Credentials file is written mode 0600")
    func testFilePermissions() throws {
        try withTemporaryDirectory { directory in
            let store = CredentialStore(directory: directory)
            try store.store(
                StoredCredentials(accessToken: "st_abc", refreshToken: "rt_abc"), for: "prod")

            let attributes = try FileManager.default.attributesOfItem(
                atPath: store.credentialsFile.path)
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
            #expect(permissions.uint16Value == 0o600)
        }
    }
}
