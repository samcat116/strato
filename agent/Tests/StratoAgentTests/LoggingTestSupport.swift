import InMemoryLogging
import Testing

enum LogLeakAssertions {
    static func expectNoSecrets(
        _ secrets: [String],
        in entries: [InMemoryLogHandler.Entry]
    ) {
        let rendered = entries.map { entry in
            "\(entry.level) \(entry.message) \(entry.metadata) \(String(describing: entry.error))"
        }.joined(separator: "\n")

        for secret in secrets {
            #expect(!secret.isEmpty)
            #expect(!rendered.contains(secret), "captured log contains secret: \(secret)")
        }
    }
}
