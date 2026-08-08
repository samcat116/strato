import Testing

@testable import StratoAgentCore

/// Coverage for STR-196: a hypervisor that cannot answer must not be reported
/// as an idle host.
///
/// `LibvirtService.reservedResources()` used to end
/// `stale(lastKnownReservations, …) ?? (vcpus: 0, memoryBytes: 0)`. The cache
/// covered a driver that used to answer; the never-answered branch synthesized
/// a zero at the seam, and a zero is indistinguishable from a correct answer on
/// an idle host. That is the shape STR-190 took in the field — fresh agent,
/// decoder broken from the first sweep, no good answer ever cached, the agent's
/// manifest fallback bypassed, and a node advertising its full capacity to the
/// scheduler while running VMs, at warning level, looking healthy throughout.
///
/// The decision now lives here rather than in the driver because the driver is
/// in an executable target no test can import. Instantiated below at exactly
/// the two types the seam carries, so the real payloads are what gets asserted.
@Suite("Last Known Inventory")
struct LastKnownInventoryTests {

    /// Matches `LibvirtService.staleInventoryThreshold`. Not shared with it —
    /// the cadence is the driver's policy and this type holds none — but the
    /// same number, so the ageing tests read against the figure in production.
    static let threshold: Duration = .seconds(300)

    private static func reservations() -> LastKnownInventory<(vcpus: Int, memoryBytes: Int64)> {
        LastKnownInventory<(vcpus: Int, memoryBytes: Int64)>(staleThreshold: threshold)
    }

    private static func vmIds() -> LastKnownInventory<[String]> {
        LastKnownInventory<[String]>(staleThreshold: threshold)
    }

    // MARK: - Never answered is not an answer

    /// The sweep that has never once succeeded. Nothing above this line can
    /// tell a synthesized zero from a real one, which is why the driver has to
    /// decline to synthesize it: the scheduler places against whatever number
    /// arrives, and "this host is idle" is the most expensive wrong answer it
    /// can be given.
    @Test("A hypervisor that has never answered says so, rather than describing an idle host")
    func neverAnsweredIsNotAnIdleHost() {
        let inventory = Self.reservations()

        guard case .neverAnswered = inventory.fallback() else {
            Issue.record("a driver with no answer must report not knowing, never (0, 0)")
            return
        }
    }

    /// The mirror-image failure, and its own test because the consequence is a
    /// different one: an empty VM list is read as every VM on this host being
    /// gone, not as this host being cheap to fill.
    @Test("…and says so about the VM list too")
    func neverAnsweredIsNotAnEmptyHost() {
        let inventory = Self.vmIds()

        guard case .neverAnswered = inventory.fallback() else {
            Issue.record("a driver with no answer must report not knowing, never []")
            return
        }
    }

    // MARK: - A recorded emptiness is a real answer

    /// The load-bearing distinction. STR-190's cached `(0, 0)` was recorded
    /// legitimately, back when the host had no Strato domains — what went wrong
    /// was that every later failure produced the same value without anything
    /// having recorded it. Both cases must stay expressible: an idle host
    /// reports zero, and a host nobody could read reports nothing.
    @Test("A zero reservation libvirtd actually gave is a real answer, and is served as one")
    func aRecordedZeroIsServedAsAnAnswer() {
        var inventory = Self.reservations()
        let recordedAt = ContinuousClock.now
        inventory.record((vcpus: 0, memoryBytes: 0), at: recordedAt)

        guard case .lastKnown(let reserved, _, let badlyStale) = inventory.fallback(now: recordedAt) else {
            Issue.record("an answer that was recorded must be served, zero or not")
            return
        }
        #expect(reserved.vcpus == 0)
        #expect(reserved.memoryBytes == 0)
        #expect(badlyStale == false)
    }

    /// An empty host is a legitimate host, and the fix must not make emptiness
    /// unreportable — only unsynthesizable.
    @Test("An empty VM list libvirtd actually gave is a real answer")
    func aRecordedEmptyListIsServedAsAnAnswer() {
        var inventory = Self.vmIds()
        let recordedAt = ContinuousClock.now
        inventory.record([], at: recordedAt)

        guard case .lastKnown(let ids, _, _) = inventory.fallback(now: recordedAt) else {
            Issue.record("an answer that was recorded must be served, empty or not")
            return
        }
        #expect(ids.isEmpty)
    }

    // MARK: - Ageing

    /// The ordinary hiccup: one failed sweep against a driver that answered a
    /// moment ago. Serving the last answer beats serving an empty one, and at
    /// ten seconds old it is not worth escalating over.
    @Test("A recorded answer is served back when the live query fails")
    func aRecentAnswerIsServedBack() {
        var inventory = Self.reservations()
        let recordedAt = ContinuousClock.now
        inventory.record((vcpus: 4, memoryBytes: 8 * 1024 * 1024 * 1024), at: recordedAt)

        guard
            case .lastKnown(let reserved, let age, let badlyStale) = inventory.fallback(
                now: recordedAt.advanced(by: .seconds(10)))
        else {
            Issue.record("a recent answer must be served")
            return
        }
        #expect(reserved.vcpus == 4)
        #expect(reserved.memoryBytes == 8 * 1024 * 1024 * 1024)
        #expect(age == .seconds(10))
        #expect(badlyStale == false)
    }

    /// Stale beats empty, always — so the value still comes back. What the flag
    /// buys is that "these are this second's figures" and "these are from an
    /// hour ago" stop differing only by a log line nobody reads.
    @Test("An answer nobody has refreshed in minutes is still served — and flagged")
    func aBadlyStaleAnswerIsStillServed() {
        var inventory = Self.reservations()
        let recordedAt = ContinuousClock.now
        inventory.record((vcpus: 4, memoryBytes: 8 * 1024 * 1024 * 1024), at: recordedAt)

        guard
            case .lastKnown(let reserved, _, let badlyStale) = inventory.fallback(
                now: recordedAt.advanced(by: Self.threshold + .seconds(1)))
        else {
            Issue.record("a badly stale answer is still the best answer there is")
            return
        }
        #expect(reserved.vcpus == 4)
        #expect(badlyStale)
    }

    /// Pins the comparison at `>` rather than `>=`, so the escalation cannot be
    /// flipped by a refactor without something failing.
    @Test("An answer exactly at the threshold has not gone bad yet")
    func thresholdIsExclusive() {
        var inventory = Self.vmIds()
        let recordedAt = ContinuousClock.now
        inventory.record(["a"], at: recordedAt)

        guard case .lastKnown(_, _, let atThreshold) = inventory.fallback(now: recordedAt.advanced(by: Self.threshold))
        else {
            Issue.record("an answer at the threshold is still an answer")
            return
        }
        #expect(atThreshold == false)

        guard
            case .lastKnown(_, _, let pastThreshold) = inventory.fallback(
                now: recordedAt.advanced(by: Self.threshold + .nanoseconds(1)))
        else {
            Issue.record("an answer past the threshold is still an answer")
            return
        }
        #expect(pastThreshold)
    }

    /// A driver that recovers stops being badly stale, rather than carrying the
    /// first answer's age forever.
    @Test("A fresh answer replaces the old one and restarts its clock")
    func recordingAgainRestartsTheClock() {
        var inventory = Self.vmIds()
        let recordedAt = ContinuousClock.now
        inventory.record(["stale"], at: recordedAt)
        inventory.record(["fresh"], at: recordedAt.advanced(by: .seconds(400)))

        guard
            case .lastKnown(let ids, let age, let badlyStale) = inventory.fallback(
                now: recordedAt.advanced(by: .seconds(410)))
        else {
            Issue.record("the newest answer must be the one served")
            return
        }
        #expect(ids == ["fresh"])
        #expect(age == .seconds(10))
        #expect(badlyStale == false)
    }
}
