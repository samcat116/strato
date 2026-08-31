enum RetryClassification {
    static func isRetryableStatus(_ status: Int) -> Bool {
        status >= 500 || status == 408 || status == 429
    }
}
