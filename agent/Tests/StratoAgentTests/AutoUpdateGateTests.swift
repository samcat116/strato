import Foundation
import Testing

@testable import StratoAgentCore

@Suite("Auto-update precondition gate")
struct AutoUpdateGateTests {

    private func conditions(
        installMode: AgentInstallMode = .supervisedBinary,
        inFlightReconcileItems: Int = 0
    ) -> AutoUpdateGate.Conditions {
        AutoUpdateGate.Conditions(
            installMode: installMode,
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

    @Test("In-flight reconcile work blocks until the lanes drain")
    func inFlightWorkBlocks() {
        let reason = AutoUpdateGate.blockedReason(conditions(inFlightReconcileItems: 3))
        #expect(reason?.contains("3 reconcile work item(s)") == true)
    }

    @Test("The permanent condition wins when several block at once")
    func permanentReasonFirst() {
        // A containerized agent's in-flight work is irrelevant; the reported
        // reason must be the one an operator can actually act on.
        let reason = AutoUpdateGate.blockedReason(
            conditions(
                installMode: .container(marker: "STRATO_INSTALL_MODE"),
                inFlightReconcileItems: 5
            ))
        #expect(reason?.contains("container") == true)
        #expect(reason?.contains("reconcile") == false)
    }
}
