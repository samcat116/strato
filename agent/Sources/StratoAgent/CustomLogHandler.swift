import Foundation
import Logging

// Custom log handler that formats timestamps without timezone
struct CustomLogHandler: LogHandler {
    private let label: String
    
    var logLevel: Logger.Level = .info
    var metadata: Logger.Metadata = [:]
    
    init(label: String) {
        self.label = label
    }
    
    subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get { metadata[metadataKey] }
        set { metadata[metadataKey] = newValue }
    }
    
    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(abbreviation: "UTC")
        let timestamp = formatter.string(from: Date())
        
        let logLevel = level.rawValue.uppercased()
        let mergedMetadata = self.metadata.merging(metadata ?? [:]) { _, new in new }
        
        var output = "\(timestamp) \(logLevel) \(label) : "
        
        // Add metadata if present
        if !mergedMetadata.isEmpty {
            let metadataString = mergedMetadata.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            output += "\(metadataString) "
        }
        
        output += "[\(source)] \(message)"
        
        // Use FileHandle.standardError directly for concurrency safety
        FileHandle.standardError.write(Data((output + "\n").utf8))
    }
}