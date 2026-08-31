import Foundation
import Logging
import StratoShared
import Synchronization

/// A JSON Lines handler for the agent's process log.
///
/// Every record is encoded completely before it is handed to the shared writer. The
/// writer holds one process-wide lock through the stderr write, so records emitted by
/// different `Logger` instances cannot interleave.
public struct CustomLogHandler: LogHandler {
    static let maximumMessageBytes = 8 * 1024
    static let maximumMetadataBytes = 16 * 1024
    static let maximumRecordBytes = 16 * 1024

    private let label: String
    private let output: SerializedLogRecordWriter
    private let now: @Sendable () -> Date

    public var logLevel: Logger.Level = .info
    public var metadata: Logger.Metadata = [:]
    public var metadataProvider: Logger.MetadataProvider?

    public init(
        label: String,
        metadataProvider: Logger.MetadataProvider? = nil
    ) {
        self.init(
            label: label,
            metadataProvider: metadataProvider,
            output: .standardError,
            now: Date.init)
    }

    init(
        label: String,
        metadataProvider: Logger.MetadataProvider? = nil,
        output: SerializedLogRecordWriter,
        now: @escaping @Sendable () -> Date
    ) {
        self.label = label
        self.metadataProvider = metadataProvider
        self.output = output
        self.now = now
    }

    public subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get { metadata[metadataKey] }
        set { metadata[metadataKey] = newValue }
    }

    public func log(event: LogEvent) {
        // Canonicalize before each merge. Otherwise an event-level `vmId` would
        // coexist with, rather than override, a handler-level `strato.vm.id`.
        var mergedMetadata = Self.canonicalized(metadata)
        if let providedMetadata = metadataProvider?.get() {
            mergedMetadata.merge(Self.canonicalized(providedMetadata)) { _, provided in provided }
        }
        if let eventMetadata = event.metadata {
            mergedMetadata.merge(Self.canonicalized(eventMetadata)) { _, event in event }
        }

        // Typed errors win over manually supplied fields: these values describe
        // the actual `Error` carried by this `LogEvent`.
        if let error = event.error {
            mergedMetadata["error.type"] = .string(String(reflecting: type(of: error)))
            mergedMetadata["error.message"] = .string(String(describing: error))
        }

        let record = LogRecordEncoder.encode(
            timestamp: now(),
            level: event.level,
            label: label,
            source: event.source,
            message: event.message.description,
            metadata: mergedMetadata)
        output.write(record)
    }

    private static func canonicalized(_ metadata: Logger.Metadata) -> Logger.Metadata {
        var canonical: Logger.Metadata = [:]
        let sortedKeys = metadata.keys.sorted()

        // Pick aliases deterministically when a layer contains more than one old
        // spelling for the same key.
        for key in sortedKeys {
            let canonicalKey = LogMetadata.canonicalKey(for: key)
            if canonical[canonicalKey] == nil {
                canonical[canonicalKey] = metadata[key]
            }
        }

        // A canonical spelling in the same layer always wins over an alias.
        for key in sortedKeys where LogMetadata.canonicalKey(for: key) == key {
            canonical[key] = metadata[key]
        }
        return canonical
    }
}

/// Owns the serialization boundary for a log destination.
///
/// The standard-error instance is shared by every production handler. Tests inject
/// the same abstraction with a recording destination and therefore exercise the
/// production write contract without redirecting process-global stderr.
final class SerializedLogRecordWriter: Sendable {
    private let writeBody: Mutex<@Sendable (Data) -> Void>

    static let standardError = SerializedLogRecordWriter { data in
        FileHandle.standardError.write(data)
    }

    init(_ writeBody: @escaping @Sendable (Data) -> Void) {
        self.writeBody = Mutex(writeBody)
    }

    func write(_ record: Data) {
        writeBody.withLock { write in
            write(record)
        }
    }
}

private enum LogRecordEncoder {
    private static let maximumEnvelopeFieldBytes = 2 * 1024
    private static let maximumMetadataValueBytes = 4 * 1024
    private static let maximumMetadataDepth = 16
    private static let maximumMetadataNodes = 2_048

    private static let metadataPriority: [String] = [
        "error.type",
        "error.message",
        LogMetadata.Key.serviceName,
        LogMetadata.Key.serviceInstanceID,
        LogMetadata.Key.deploymentEnvironmentName,
        LogMetadata.Key.serviceVersion,
        LogMetadata.Key.requestID,
        LogMetadata.Key.operationID,
        LogMetadata.Key.agentID,
        LogMetadata.Key.agentName,
        LogMetadata.Key.agentIdentity,
        LogMetadata.Key.vmID,
        LogMetadata.Key.sandboxID,
        LogMetadata.Key.projectID,
        LogMetadata.Key.sessionKind,
        LogMetadata.Key.sessionID,
    ]

    private struct ConversionState {
        var remainingNodes = maximumMetadataNodes
        var truncated = false
    }

    private struct Truncation: Encodable {
        var message = false
        var metadata = false
        var record = false

        var any: Bool { message || metadata || record }

        enum CodingKeys: String, CodingKey {
            case message
            case metadata
            case record
            case messageLimitBytes = "message_limit_bytes"
            case metadataLimitBytes = "metadata_limit_bytes"
            case recordLimitBytes = "record_limit_bytes"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(message, forKey: .message)
            try container.encode(metadata, forKey: .metadata)
            try container.encode(record, forKey: .record)
            try container.encode(CustomLogHandler.maximumMessageBytes, forKey: .messageLimitBytes)
            try container.encode(CustomLogHandler.maximumMetadataBytes, forKey: .metadataLimitBytes)
            try container.encode(CustomLogHandler.maximumRecordBytes, forKey: .recordLimitBytes)
        }
    }

    private struct Record: Encodable {
        let timestamp: String
        let level: String
        let label: String
        let source: String
        let message: String
        let metadata: [String: JSONValue]
        let truncated: Bool
        let truncation: Truncation?
    }

    private enum JSONValue: Encodable {
        case string(String)
        case array([JSONValue])
        case object([String: JSONValue])

        func encode(to encoder: Encoder) throws {
            switch self {
            case .string(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .array(let values):
                var container = encoder.unkeyedContainer()
                for value in values {
                    try container.encode(value)
                }
            case .object(let values):
                var container = encoder.container(keyedBy: DynamicCodingKey.self)
                for key in values.keys.sorted() {
                    try container.encode(values[key]!, forKey: DynamicCodingKey(key))
                }
            }
        }
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(_ stringValue: String) {
            self.stringValue = stringValue
        }

        init?(stringValue: String) {
            self.init(stringValue)
        }

        init?(intValue: Int) {
            return nil
        }
    }

    static func encode(
        timestamp: Date,
        level: Logger.Level,
        label: String,
        source: String,
        message: String,
        metadata: Logger.Metadata
    ) -> Data {
        var truncation = Truncation()

        let boundedLabel = boundedJSONString(label, maximumEncodedBytes: maximumEnvelopeFieldBytes)
        let boundedSource = boundedJSONString(source, maximumEncodedBytes: maximumEnvelopeFieldBytes)
        if boundedLabel.truncated || boundedSource.truncated {
            truncation.record = true
        }

        var boundedMessage = utf8Prefix(message, maximumBytes: CustomLogHandler.maximumMessageBytes)
        if boundedMessage != message {
            truncation.message = true
        }

        let boundedMetadata = boundedMetadata(metadata)
        var retainedMetadata = boundedMetadata.values
        var retainedKeys = boundedMetadata.retainedKeys
        truncation.metadata = boundedMetadata.truncated

        let timestampString = formattedTimestamp(timestamp)
        let payloadLimit = CustomLogHandler.maximumRecordBytes - 1  // reserve the terminal LF

        func makeRecord(message: String) -> Data {
            encoded(
                Record(
                    timestamp: timestampString,
                    level: level.rawValue.uppercased(),
                    label: boundedLabel.value,
                    source: boundedSource.value,
                    message: message,
                    metadata: retainedMetadata,
                    truncated: truncation.any,
                    truncation: truncation.any ? truncation : nil))
        }

        var payload = makeRecord(message: boundedMessage)
        if payload.count > payloadLimit {
            truncation.record = true

            // Shed non-correlation metadata first. Priority keys remain at the
            // front of `retainedKeys`, so removing from the end is deterministic.
            while payload.count > payloadLimit,
                let key = retainedKeys.last,
                !metadataPriority.contains(key)
            {
                retainedKeys.removeLast()
                retainedMetadata.removeValue(forKey: key)
                truncation.metadata = true
                payload = makeRecord(message: boundedMessage)
            }

            if payload.count > payloadLimit {
                // If even an empty body cannot fit, remove the lowest-priority
                // remaining metadata until the structural record fits.
                var emptyPayload = makeRecord(message: "")
                while emptyPayload.count > payloadLimit, let key = retainedKeys.last {
                    retainedKeys.removeLast()
                    retainedMetadata.removeValue(forKey: key)
                    truncation.metadata = true
                    emptyPayload = makeRecord(message: "")
                }

                let fullPayload = makeRecord(message: boundedMessage)
                if fullPayload.count <= payloadLimit {
                    payload = fullPayload
                } else {
                    truncation.message = true
                    boundedMessage = largestFittingPrefix(
                        of: boundedMessage,
                        payloadLimit: payloadLimit,
                        encode: makeRecord)
                    payload = makeRecord(message: boundedMessage)
                }
            }
        }

        // The envelope limits make this unreachable in normal operation, but a
        // minimal valid record is safer than violating the advertised ceiling if
        // a Foundation encoder ever changes its escaping overhead.
        if payload.count > payloadLimit {
            truncation = Truncation(message: true, metadata: true, record: true)
            retainedMetadata = [:]
            payload = encoded(
                Record(
                    timestamp: timestampString,
                    level: level.rawValue.uppercased(),
                    label: "",
                    source: "",
                    message: "",
                    metadata: [:],
                    truncated: true,
                    truncation: truncation))
        }

        payload.append(0x0A)
        return payload
    }

    private static func boundedMetadata(
        _ metadata: Logger.Metadata
    ) -> (values: [String: JSONValue], retainedKeys: [String], truncated: Bool) {
        var state = ConversionState()
        let priority = Dictionary(uniqueKeysWithValues: metadataPriority.enumerated().map { ($1, $0) })
        let keys = metadata.keys.sorted { lhs, rhs in
            let lhsPriority = priority[lhs] ?? Int.max
            let rhsPriority = priority[rhs] ?? Int.max
            return lhsPriority == rhsPriority ? lhs < rhs : lhsPriority < rhsPriority
        }

        var values: [String: JSONValue] = [:]
        var retainedKeys: [String] = []
        var encodedBytes = 2  // `{}`

        for key in keys {
            guard let metadataValue = metadata[key],
                let value = jsonValue(metadataValue, depth: 0, state: &state)
            else {
                state.truncated = true
                continue
            }

            let pairBytes = encoded([key: value]).count - 2
            let separatorBytes = retainedKeys.isEmpty ? 0 : 1
            guard encodedBytes + separatorBytes + pairBytes <= CustomLogHandler.maximumMetadataBytes else {
                state.truncated = true
                continue
            }

            values[key] = value
            retainedKeys.append(key)
            encodedBytes += separatorBytes + pairBytes
        }

        return (values, retainedKeys, state.truncated)
    }

    private static func jsonValue(
        _ value: Logger.Metadata.Value,
        depth: Int,
        state: inout ConversionState
    ) -> JSONValue? {
        guard depth < maximumMetadataDepth, state.remainingNodes > 0 else {
            state.truncated = true
            return nil
        }
        state.remainingNodes -= 1

        switch value {
        case .string(let value):
            let bounded = boundedJSONString(value, maximumEncodedBytes: maximumMetadataValueBytes)
            state.truncated = state.truncated || bounded.truncated
            return .string(bounded.value)
        case .stringConvertible(let value):
            let bounded = boundedJSONString(value.description, maximumEncodedBytes: maximumMetadataValueBytes)
            state.truncated = state.truncated || bounded.truncated
            return .string(bounded.value)
        case .array(let values):
            var converted: [JSONValue] = []
            for value in values {
                guard let item = jsonValue(value, depth: depth + 1, state: &state) else {
                    state.truncated = true
                    break
                }
                converted.append(item)
            }
            if converted.count != values.count {
                state.truncated = true
            }
            return .array(converted)
        case .dictionary(let values):
            var converted: [String: JSONValue] = [:]
            for key in values.keys.sorted() {
                guard let value = values[key],
                    let item = jsonValue(value, depth: depth + 1, state: &state)
                else {
                    state.truncated = true
                    break
                }
                converted[key] = item
            }
            if converted.count != values.count {
                state.truncated = true
            }
            return .object(converted)
        }
    }

    private static func boundedJSONString(
        _ value: String,
        maximumEncodedBytes: Int
    ) -> (value: String, truncated: Bool) {
        guard encoded(JSONValue.string(value)).count > maximumEncodedBytes else {
            return (value, false)
        }

        var lowerBound = 0
        var upperBound = value.utf8.count
        while lowerBound < upperBound {
            let candidateBytes = (lowerBound + upperBound + 1) / 2
            let candidate = utf8Prefix(value, maximumBytes: candidateBytes)
            if encoded(JSONValue.string(candidate)).count <= maximumEncodedBytes {
                lowerBound = candidateBytes
            } else {
                upperBound = candidateBytes - 1
            }
        }
        return (utf8Prefix(value, maximumBytes: lowerBound), true)
    }

    private static func largestFittingPrefix(
        of value: String,
        payloadLimit: Int,
        encode: (String) -> Data
    ) -> String {
        var lowerBound = 0
        var upperBound = value.utf8.count
        while lowerBound < upperBound {
            let candidateBytes = (lowerBound + upperBound + 1) / 2
            let candidate = utf8Prefix(value, maximumBytes: candidateBytes)
            if encode(candidate).count <= payloadLimit {
                lowerBound = candidateBytes
            } else {
                upperBound = candidateBytes - 1
            }
        }
        return utf8Prefix(value, maximumBytes: lowerBound)
    }

    private static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }

        var result = ""
        result.reserveCapacity(maximumBytes)
        var usedBytes = 0
        for character in value {
            let fragment = String(character)
            let fragmentBytes = fragment.utf8.count
            guard usedBytes + fragmentBytes <= maximumBytes else { break }
            result.append(character)
            usedBytes += fragmentBytes
        }
        return result
    }

    private static func formattedTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func encoded<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Every encoded type above is made exclusively from JSON primitives.
        return try! encoder.encode(value)
    }
}
