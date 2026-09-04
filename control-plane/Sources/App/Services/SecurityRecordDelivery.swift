import Foundation

/// Shared retry policy for the two security-record streams whose producers
/// must remain fail-open: the audit trail and the IAM decision log.
///
/// The first attempt is immediate. Each entry is the delay before the next
/// attempt, so the production policy makes eight attempts over about eleven
/// seconds without keeping request handlers waiting.
struct SecurityRecordRetryPolicy: Sendable {
    let delays: [Duration]

    static let standard = SecurityRecordRetryPolicy(delays: [
        .milliseconds(100),
        .milliseconds(200),
        .milliseconds(400),
        .milliseconds(800),
        .milliseconds(1_600),
        .milliseconds(3_200),
        .seconds(5),
    ])
}

struct SecurityRecordRetryOutcome<Record: Sendable>: Sendable {
    let undelivered: [Record]
    let attempts: Int
}

/// Retry only the records the destination reports as undelivered. Database
/// batch inserts return the whole batch on failure (the statement is atomic),
/// while per-record HTTP backends can return only their failed subset. This
/// prevents a healthy destination from receiving duplicates because another
/// destination was unavailable. A deadline stops a bounded flush from
/// scheduling retries outside its caller's wall-clock budget.
func retrySecurityRecordDelivery<Record: Sendable>(
    _ records: [Record],
    policy: SecurityRecordRetryPolicy,
    deadline: ContinuousClock.Instant? = nil,
    write: @escaping @Sendable ([Record]) async -> [Record]
) async -> SecurityRecordRetryOutcome<Record> {
    guard !records.isEmpty else {
        return SecurityRecordRetryOutcome(undelivered: [], attempts: 0)
    }

    let clock = ContinuousClock()
    var undelivered = records
    var attempts = 0
    while true {
        if let deadline, clock.now >= deadline {
            return SecurityRecordRetryOutcome(undelivered: undelivered, attempts: attempts)
        }
        attempts += 1
        undelivered = await write(undelivered)
        guard !undelivered.isEmpty else {
            return SecurityRecordRetryOutcome(undelivered: [], attempts: attempts)
        }
        guard attempts <= policy.delays.count, !Task.isCancelled else {
            return SecurityRecordRetryOutcome(undelivered: undelivered, attempts: attempts)
        }
        let delay = policy.delays[attempts - 1]
        if let deadline, clock.now.advanced(by: delay) >= deadline {
            return SecurityRecordRetryOutcome(undelivered: undelivered, attempts: attempts)
        }
        do {
            try await Task.sleep(for: delay)
        } catch {
            return SecurityRecordRetryOutcome(undelivered: undelivered, attempts: attempts)
        }
    }
}
