import Foundation
import Testing

@testable import StratoAgentCore

@Suite("Failure Classification Tests")
struct FailureClassificationTests {

    @Test("Host misconfiguration and spec-level storage errors are permanent")
    func permanentStorageErrors() {
        let misconfigured: StorageBackendError = .hostMisconfiguration("qemu-img missing")
        #expect(misconfigured.failureClassification == .permanent)

        let unsupported: StorageBackendError = .unsupportedFormat("vmdk")
        #expect(unsupported.failureClassification == .permanent)

        let noSource: StorageBackendError = .imageSourceUnavailable
        #expect(noSource.failureClassification == .permanent)
    }

    @Test("Operational storage errors stay transient (retryable)")
    func transientStorageErrors() {
        let createFailed: StorageBackendError = .createFailed("qemu-img create failed: exit 1")
        #expect(createFailed.failureClassification == .transient)

        let notFound: StorageBackendError = .volumeNotFound("vol-1")
        #expect(notFound.failureClassification == .transient)
    }

    @Test("Unclassified errors default to transient handling")
    func unclassifiedErrorsDefaultTransient() {
        struct Boom: Error {}
        let classification = (Boom() as? any ClassifiableError)?.failureClassification ?? .transient
        #expect(classification == .transient)
    }
}
