import Testing

@testable import StratoAgentCore

@Suite("Retry Classification")
struct RetryClassificationTests {
    @Test(
        "HTTP retry classification preserves the shared policy",
        arguments: [408, 429, 500, 599]
    )
    func retryableStatuses(status: Int) {
        #expect(RetryClassification.isRetryableStatus(status))
    }

    @Test(
        "Terminal HTTP statuses remain non-retryable",
        arguments: [200, 400, 404, 499]
    )
    func terminalStatuses(status: Int) {
        #expect(!RetryClassification.isRetryableStatus(status))
    }
}
