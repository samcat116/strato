import Fluent
import Vapor

/// Stores application-level settings and secrets
final class AppSetting: Model, @unchecked Sendable {
    static let schema = "app_settings"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "key")
    var key: String

    @Field(key: "value")
    var value: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, key: String, value: String) {
        self.id = id
        self.key = key
        self.value = value
    }

    // MARK: - Known Keys

    static let imageDownloadSigningKey = "image_download_signing_key"
}
