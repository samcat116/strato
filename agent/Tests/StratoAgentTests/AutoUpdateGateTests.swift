import Foundation
import Testing

@testable import StratoAgentCore

@Suite("Auto-update precondition gate")
struct AutoUpdateGateTests {

    private func conditions(
        installMode: AgentInstallMode = .supervisedBinary,
        runningFirecrackerVMs: Int = 0,
        inFlightReconcileItems: Int = 0
    ) -> AutoUpdateGate.Conditions {
        AutoUpdateGate.Conditions(
            installMode: installMode,
            runningFirecrackerVMs: runningFirecrackerVMs,
            inFlightReconcileItems: inFlightReconcileItems
        )
    }

    @Test("All preconditions holding yields no blocked reason")
    func clearGate() {
        #expect(AutoUpdateGate.blockedReason(conditions()) == nil)
    }

    @Test("A containerized install blocks with the detection marker")
    func containerBlocks() {
        let reason = AutoUpdateGate.blockedReason(
            conditions(installMode: .container(marker: "/.dockerenv")))
        #expect(reason?.contains("/.dockerenv") == true)
        #expect(reason?.contains("container") == true)
    }

    @Test("Running Firecracker VMs block until re-adoption exists")
    func firecrackerBlocks() {
        let reason = AutoUpdateGate.blockedReason(conditions(runningFirecrackerVMs: 2))
        #expect(reason?.contains("2 Firecracker VM(s)") == true)
    }

    @Test("In-flight reconcile work blocks until the lanes drain")
    func inFlightWorkBlocks() {
        let reason = AutoUpdateGate.blockedReason(conditions(inFlightReconcileItems: 3))
        #expect(reason?.contains("3 reconcile work item(s)") == true)
    }

    @Test("The permanent condition wins when several block at once")
    func permanentReasonFirst() {
        // A containerized agent's VM counts are irrelevant; the reported
        // reason must be the one an operator can actually act on.
        let reason = AutoUpdateGate.blockedReason(
            conditions(
                installMode: .container(marker: "STRATO_INSTALL_MODE"),
                runningFirecrackerVMs: 5,
                inFlightReconcileItems: 5
            ))
        #expect(reason?.contains("container") == true)
        #expect(reason?.contains("Firecracker") == false)
    }
}
