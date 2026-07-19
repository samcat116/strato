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

    static func configure(_ app: Application) throws {
        let raw = Environment.get("IMAGE_STORAGE_BACKEND")?.lowercased() ?? Backend.filesystem.rawValue
        guard let backend = Backend(rawValue: raw) else {
            throw ImageError.storageFailed(
                "Unknown IMAGE_STORAGE_BACKEND '\(raw)' (expected 'filesystem' or 's3')")
        }

        switch backend {
        case .filesystem:
            let root = FilesystemImageObjectStore.defaultRootPath
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
                    "endpoint": .string(Environment.get("IMAGE_S3_ENDPOINT") ?? "aws"),
                ])
        }
    }

    private static func makeS3Store(_ app: Application) throws -> S3ImageObjectStore {
        guard let bucket = Environment.get("IMAGE_S3_BUCKET"), !bucket.isEmpty else {
            throw ImageError.storageFailed("IMAGE_S3_BUCKET is required when IMAGE_STORAGE_BACKEND=s3")
        }

        // Explicit credentials when both are supplied; otherwise fall back to
        // Soto's default chain so IRSA / instance roles / ~/.aws work without
        // putting long-lived keys in the environment.
        let credentialProvider: CredentialProviderFactory
        let accessKey = Environment.get("IMAGE_S3_ACCESS_KEY_ID")
        let secretKey = Environment.get("IMAGE_S3_SECRET_ACCESS_KEY")
        switch (accessKey, secretKey) {
        case let (key?, secret?) where !key.isEmpty && !secret.isEmpty:
            credentialProvider = .static(
                accessKeyId: key,
                secretAccessKey: secret,
                sessionToken: Environment.get("IMAGE_S3_SESSION_TOKEN")
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
        if Environment.get("IMAGE_S3_VIRTUAL_HOST_STYLE").flatMap(Bool.init) == true {
            options.insert(.s3ForceVirtualHost)
        }

        // A region is still required for request signing even against an
        // implementation that ignores regions; us-east-1 is the conventional
        // placeholder MinIO and Garage accept.
        let region = Region(rawValue: Environment.get("IMAGE_S3_REGION") ?? "us-east-1")

        let s3 = S3(
            client: client,
            region: region,
            endpoint: Environment.get("IMAGE_S3_ENDPOINT"),
            options: options
        )

        return S3ImageObjectStore(s3: s3, bucket: bucket)
    }
}
