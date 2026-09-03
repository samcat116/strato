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

    @Test("Host space exhaustion is blocked across cache, OCI, and storage paths")
    func diskSpaceErrorsAreBlocked() {
        #expect(StorageBackendError.insufficientDiskSpace("full").failureClassification == .blocked)
        #expect(ImageCacheError.insufficientDiskSpace("full").failureClassification == .blocked)
        #expect(OCIError.insufficientDiskSpace(detail: "full").failureClassification == .blocked)
    }

    /// `blocked` is its own case rather than a flavour of the two above because
    /// it answers the two questions differently: report it (like permanent),
    /// keep retrying it (unlike permanent), and burn no attempt doing so
    /// (like a dependency wait, which is reported to nobody). See STR-199.
    @Test("A blocked failure is neither permanent nor a silent dependency wait")
    func blockedIsItsOwnClassification() {
        let blocked: ConvergenceError = .blocked("the guest holding this image is running")
        #expect(blocked.failureClassification == .blocked)
        #expect(blocked.failureClassification != .permanent)
        #expect(blocked.failureClassification != .waitingOnDependency)
        #expect(blocked.errorDescription == "the guest holding this image is running")
    }

    @Test("Unclassified errors default to transient handling")
    func unclassifiedErrorsDefaultTransient() {
        struct Boom: Error {}
        let classification = (Boom() as? any ClassifiableError)?.failureClassification ?? .transient
        #expect(classification == .transient)
    }
}
