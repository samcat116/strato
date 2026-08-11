import Foundation
import SotoCore
import SotoS3
import Vapor

/// Builds the configured image store from the environment.
///
/// The filesystem backend stays the default so an existing deployment upgrades
/// with no configuration change and no migration of image bytes.
enum ImageObjectStoreFactory {
    enum Backend: String {
        case filesystem
        case s3
    }

    private struct AWSClientKey: StorageKey {
        typealias Value = AWSClient
    }

    /// Reads an environment variable, treating an empty value as absent.
    ///
    /// Deployment templates routinely set a variable to the empty string rather
    /// than omitting it — Compose's `KEY: ${KEY:-}` map form always sets the
    /// key. The provider returns `""` there, which is non-nil, so an unconfigured
    /// option would otherwise read as configured-but-blank: empty
    /// credentials failed the "set together" check and an empty endpoint was
    /// handed to Soto as a literal base URL, breaking real AWS.
    private static func value(
        _ key: ControlPlaneStringKey,
        configuration: ControlPlaneConfiguration
    ) -> String? {
        guard let value = configuration.string(key), !value.isEmpty else { return nil }
        return value
    }

    static func configure(_ app: Application) throws {
        let configuration = app.controlPlaneConfiguration
        let raw = configuration.string(.imageStorageBackend)!
        guard let backend = Backend(rawValue: raw) else {
            throw ImageError.storageFailed(
                "Unknown IMAGE_STORAGE_BACKEND '\(raw)' (expected 'filesystem' or 's3')")
        }

        switch backend {
        case .filesystem:
            let root = FilesystemImageObjectStore.rootPath(configuration: configuration)
            app.imageObjectStore = FilesystemImageObjectStore(
                rootPath: root, threadPool: app.threadPool)
            app.logger.info(
                "Image storage backend: filesystem", metadata: ["path": .string(root)])

        case .s3:
            let store = try makeS3Store(app)
            app.imageObjectStore = store
            app.logger.info(
                "Image storage backend: s3",
                metadata: [
                    "bucket": .string(store.bucket),
                    "endpoint": .string(value(.imageS3Endpoint, configuration: configuration) ?? "aws"),
                ])
        }
    }

    private static func makeS3Store(_ app: Application) throws -> S3ImageObjectStore {
        let configuration = app.controlPlaneConfiguration
        guard let bucket = value(.imageS3Bucket, configuration: configuration) else {
            throw ImageError.storageFailed("IMAGE_S3_BUCKET is required when IMAGE_STORAGE_BACKEND=s3")
        }

        // Explicit credentials when both are supplied; otherwise fall back to
        // Soto's default chain so IRSA / instance roles / ~/.aws work without
        // putting long-lived keys in the environment.
        let credentialProvider: CredentialProviderFactory
        switch (
            value(.imageS3AccessKeyID, configuration: configuration),
            value(.imageS3SecretAccessKey, configuration: configuration)
        ) {
        case let (key?, secret?):
            credentialProvider = .static(
                accessKeyId: key,
                secretAccessKey: secret,
                sessionToken: value(.imageS3SessionToken, configuration: configuration)
            )
        case (nil, nil):
            credentialProvider = .default
        default:
            throw ImageError.storageFailed(
                "IMAGE_S3_ACCESS_KEY_ID and IMAGE_S3_SECRET_ACCESS_KEY must be set together")
        }

        let client = AWSClient(credentialProvider: credentialProvider)
        // Soto's AWSClient must be shut down explicitly or it traps on deinit.
        app.storage.set(AWSClientKey.self, to: client) { client in
            try? client.syncShutdown()
        }

        // A custom endpoint is addressed path-style by default, which is what
        // self-hosted implementations (MinIO, Garage, Ceph RGW) expect. Some
        // providers require virtual-host addressing instead.
        var options: AWSServiceConfig.Options = []
        if configuration.bool(.imageS3VirtualHostStyle) == true {
            options.insert(.s3ForceVirtualHost)
        }

        // A region is still required for request signing even against an
        // implementation that ignores regions; us-east-1 is the conventional
        // placeholder MinIO and Garage accept.
        let region = Region(rawValue: configuration.string(.imageS3Region)!)

        let s3 = S3(
            client: client,
            region: region,
            endpoint: value(.imageS3Endpoint, configuration: configuration),
            options: options
        )

        return S3ImageObjectStore(s3: s3, bucket: bucket)
    }
}
