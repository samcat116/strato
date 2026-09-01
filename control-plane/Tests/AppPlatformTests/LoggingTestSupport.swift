import InMemoryLogging
import Logging
import Testing

struct InMemoryLogCapture {
    let handler: InMemoryLogHandler
    let logger: Logger

    init(label: String, logLevel: Logger.Level = .trace) {
        let handler = InMemoryLogHandler()
        var logger = Logger(label: label) { _ in handler }
        logger.logLevel = logLevel
        self.handler = handler
        self.logger = logger
    }

    func expectNoSecrets(_ secrets: [String]) {
        let rendered = handler.entries.map { entry in
            "\(entry.level) \(entry.message) \(entry.metadata) \(String(describing: entry.error))"
        }.joined(separator: "\n")

        for secret in secrets {
            #expect(!secret.isEmpty)
            #expect(!rendered.contains(secret), "captured log contains secret: \(secret)")
        }
    }
}
