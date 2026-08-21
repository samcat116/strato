import Testing

import AppTestSupport
@testable import App

@Suite("SSF lifecycle", .serialized)
struct SSFLifecycleTests {
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        var openState: Bool { isOpen }
    }

    @Test("shutdown waits for a poll task that has started")
    func shutdownWaitsForPollTask() async throws {
        try await withTestApp { app in
            let started = Gate()
            let release = Gate()
            let shutdownFinished = Gate()

            app.ssf.startPollSweep {
                await started.open()
                await release.wait()
            }
            await started.wait()

            let shutdown = Task {
                await app.ssf.shutdown()
                await shutdownFinished.open()
            }
            await Task.yield()

            #expect(await !shutdownFinished.openState)

            await release.open()
            await shutdown.value
            #expect(await shutdownFinished.openState)
        }
    }
}
