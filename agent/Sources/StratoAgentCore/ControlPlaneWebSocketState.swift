/// Generation-keyed lifecycle state for the agent's control-plane WebSocket.
///
/// A close callback can arrive after its socket has been superseded. Keeping
/// classification keyed to the connection that installed the callback makes
/// that stale close a no-op instead of disconnecting the successor.
public struct ControlPlaneWebSocketState: Sendable {
    public struct Generation: Hashable, Sendable {
        public let rawValue: UInt64

        fileprivate init(rawValue: UInt64) {
            self.rawValue = rawValue
        }
    }

    public enum CloseDisposition: Equatable, Sendable {
        case stale
        case intentional
        case unexpected
    }

    private var nextGeneration: UInt64 = 0
    private var currentGeneration: Generation?
    private var connectedGenerationStorage: Generation?
    private var intentionalClosures: Set<Generation> = []

    public init() {}

    public var connectedGeneration: Generation? {
        connectedGenerationStorage
    }

    public mutating func beginConnection() -> Generation {
        nextGeneration &+= 1
        let generation = Generation(rawValue: nextGeneration)
        currentGeneration = generation
        connectedGenerationStorage = nil
        return generation
    }

    /// Marks an established connection current. Returns false when a newer
    /// attempt superseded it before its ready callback completed.
    public mutating func markConnected(_ generation: Generation) -> Bool {
        guard currentGeneration == generation else { return false }
        connectedGenerationStorage = generation
        return true
    }

    public mutating func markConnectionFailed(_ generation: Generation) {
        guard currentGeneration == generation else { return }
        currentGeneration = nil
        connectedGenerationStorage = nil
        intentionalClosures.remove(generation)
    }

    /// Marks the current connected socket as operator-initiated before its
    /// asynchronous close begins.
    public mutating func beginIntentionalDisconnect() -> Generation? {
        guard let generation = connectedGenerationStorage else { return nil }
        intentionalClosures.insert(generation)
        connectedGenerationStorage = nil
        return generation
    }

    public mutating func markClosed(_ generation: Generation) -> CloseDisposition {
        let wasIntentional = intentionalClosures.remove(generation) != nil
        guard currentGeneration == generation else { return .stale }

        currentGeneration = nil
        connectedGenerationStorage = nil
        return wasIntentional ? .intentional : .unexpected
    }
}
