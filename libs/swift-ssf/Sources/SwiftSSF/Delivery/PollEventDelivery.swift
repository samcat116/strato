import Foundation
import Logging

/// Configuration for poll-based event delivery
public struct PollDeliveryConfiguration: Sendable {
    /// Polling interval in seconds
    public let pollInterval: TimeInterval
    
    /// Maximum number of events to fetch per poll
    public let maxEventsPerPoll: Int
    
    /// Maximum number of poll errors before stopping
    public let maxConsecutiveErrors: Int
    
    /// Backoff strategy for errors
    public let errorBackoffStrategy: BackoffStrategy
    
    /// Whether to continue polling after errors
    public let continueOnError: Bool
    
    public init(
        pollInterval: TimeInterval = 30.0,
        maxEventsPerPoll: Int = 100,
        maxConsecutiveErrors: Int = 5,
        errorBackoffStrategy: BackoffStrategy = .exponential(base: 2.0, maxDelay: 300.0, multiplier: 1.0),
        continueOnError: Bool = true
    ) {
        self.pollInterval = pollInterval
        self.maxEventsPerPoll = maxEventsPerPoll
        self.maxConsecutiveErrors = maxConsecutiveErrors
        self.errorBackoffStrategy = errorBackoffStrategy
        self.continueOnError = continueOnError
    }
}

/// Backoff strategies for error handling
public enum BackoffStrategy: Sendable {
    /// No backoff - retry immediately
    case none
    
    /// Fixed delay between retries
    case fixed(delay: TimeInterval)
    
    /// Exponential backoff
    case exponential(base: Double, maxDelay: TimeInterval, multiplier: Double)
    
    /// Linear backoff
    case linear(increment: TimeInterval, maxDelay: TimeInterval)
    
    /// Calculate delay for given attempt number
    func delay(for attempt: Int) -> TimeInterval {
        switch self {
        case .none:
            return 0
        case .fixed(let delay):
            return delay
        case .exponential(let base, let maxDelay, let multiplier):
            let delay = multiplier * pow(base, Double(attempt))
            return min(delay, maxDelay)
        case .linear(let increment, let maxDelay):
            let delay = increment * Double(attempt)
            return min(delay, maxDelay)
        }
    }
}

/// Poll-based event delivery service
public actor PollEventDelivery {
    private let receiver: SSFReceiver
    private let streamId: String
    private let configuration: PollDeliveryConfiguration
    private let eventHandler: SSFEventHandler
    private let logger = Logger(label: "SwiftSSF.PollEventDelivery")
    
    private var isRunning = false
    private var pollTask: Task<Void, Never>?
    private var consecutiveErrors = 0
    
    public init(
        receiver: SSFReceiver,
        streamId: String,
        configuration: PollDeliveryConfiguration = PollDeliveryConfiguration(),
        eventHandler: SSFEventHandler
    ) {
        self.receiver = receiver
        self.streamId = streamId
        self.configuration = configuration
        self.eventHandler = eventHandler
    }
    
    /// Start polling for events
    public func start() async {
        guard !isRunning else {
            logger.warning("Poll delivery is already running")
            return
        }
        
        isRunning = true
        consecutiveErrors = 0
        
        logger.info("Starting poll-based event delivery for stream \(streamId)")
        
        pollTask = Task {
            await runPollingLoop()
        }
    }
    
    /// Stop polling for events
    public func stop() async {
        guard isRunning else {
            logger.warning("Poll delivery is not running")
            return
        }
        
        logger.info("Stopping poll-based event delivery for stream \(streamId)")
        
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
    }
    
    /// Check if polling is currently running
    public var running: Bool {
        return isRunning
    }
    
    /// Get current consecutive error count
    public var errorCount: Int {
        return consecutiveErrors
    }
    
    // MARK: - Private Methods
    
    private func runPollingLoop() async {
        while isRunning && !Task.isCancelled {
            do {
                let eventsProcessed = try await receiver.pollEvents(
                    streamId: streamId,
                    maxEvents: configuration.maxEventsPerPoll,
                    handler: eventHandler
                )
                
                // Reset error count on successful poll
                if consecutiveErrors > 0 {
                    logger.info("Polling recovered after \(consecutiveErrors) consecutive errors")
                    consecutiveErrors = 0
                }
                
                if eventsProcessed > 0 {
                    logger.debug("Processed \(eventsProcessed) events in poll cycle")
                }
                
                // Wait for next poll interval
                try await Task.sleep(nanoseconds: UInt64(configuration.pollInterval * 1_000_000_000))
                
            } catch {
                consecutiveErrors += 1
                let ssfError = error as? SSFError ?? SSFError.unknown(error)
                
                logger.error("Poll error (\(consecutiveErrors)/\(configuration.maxConsecutiveErrors)): \(ssfError.localizedDescription)")
                
                // Notify error handler
                await eventHandler.handleError(ssfError, token: nil)
                
                // Check if we should stop due to too many errors
                if consecutiveErrors >= configuration.maxConsecutiveErrors {
                    if configuration.continueOnError {
                        logger.warning("Maximum consecutive errors reached, but continuing due to configuration")
                        consecutiveErrors = 0  // Reset to avoid infinite error state
                    } else {
                        logger.error("Maximum consecutive errors reached, stopping poll delivery")
                        await stop()
                        break
                    }
                }
                
                // Apply backoff strategy
                let backoffDelay = configuration.errorBackoffStrategy.delay(for: consecutiveErrors)
                if backoffDelay > 0 {
                    logger.debug("Applying backoff delay of \(backoffDelay) seconds")
                    try? await Task.sleep(nanoseconds: UInt64(backoffDelay * 1_000_000_000))
                }
            }
        }
        
        logger.info("Poll delivery loop ended for stream \(streamId)")
    }
}

/// Convenience extensions for common polling scenarios
extension SSFReceiver {
    /// Start a simple polling service for a stream
    public func startPolling(
        streamId: String,
        configuration: PollDeliveryConfiguration = PollDeliveryConfiguration(),
        eventHandler: SSFEventHandler
    ) async -> PollEventDelivery {
        let pollService = PollEventDelivery(
            receiver: self,
            streamId: streamId,
            configuration: configuration,
            eventHandler: eventHandler
        )
        
        await pollService.start()
        return pollService
    }
}

/// Multi-stream poll manager
public actor MultiStreamPollManager {
    private var pollServices: [String: PollEventDelivery] = [:]
    private let logger = Logger(label: "SwiftSSF.MultiStreamPollManager")
    
    public init() {}
    
    /// Add a stream to be polled
    public func addStream(
        _ streamId: String,
        receiver: SSFReceiver,
        configuration: PollDeliveryConfiguration = PollDeliveryConfiguration(),
        eventHandler: SSFEventHandler
    ) async {
        if pollServices[streamId] != nil {
            logger.warning("Stream \(streamId) is already being polled")
            return
        }
        
        let pollService = PollEventDelivery(
            receiver: receiver,
            streamId: streamId,
            configuration: configuration,
            eventHandler: eventHandler
        )
        
        pollServices[streamId] = pollService
        await pollService.start()
        
        logger.info("Added stream \(streamId) to poll manager")
    }
    
    /// Remove a stream from polling
    public func removeStream(_ streamId: String) async {
        guard let pollService = pollServices[streamId] else {
            logger.warning("Stream \(streamId) is not being polled")
            return
        }
        
        await pollService.stop()
        pollServices.removeValue(forKey: streamId)
        
        logger.info("Removed stream \(streamId) from poll manager")
    }
    
    /// Stop all polling services
    public func stopAll() async {
        logger.info("Stopping all poll services")
        
        for (streamId, pollService) in pollServices {
            await pollService.stop()
            logger.debug("Stopped polling for stream \(streamId)")
        }
        
        pollServices.removeAll()
    }
    
    /// Get status of all polling services
    public func getStatus() async -> [String: Bool] {
        var status: [String: Bool] = [:]
        
        for (streamId, pollService) in pollServices {
            status[streamId] = await pollService.running
        }
        
        return status
    }
    
    /// Get error counts for all services
    public func getErrorCounts() async -> [String: Int] {
        var errorCounts: [String: Int] = [:]
        
        for (streamId, pollService) in pollServices {
            errorCounts[streamId] = await pollService.errorCount
        }
        
        return errorCounts
    }
}