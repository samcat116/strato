import Foundation
import StratoShared

@testable import App

// Production mutation helpers deliberately change intent without assigning a
// generation. Tests that construct a persisted historical state use these
// helpers to model the generation that its original writer would have minted.
extension VM {
    mutating func setFixtureDesiredStatus(_ newDesired: DesiredVMStatus) {
        setDesiredStatus(newDesired)
        generation += 1
    }

    mutating func requestFixtureReboot() {
        requestReboot()
        generation += 1
    }

    mutating func requestFixtureRestore(snapshotID: UUID) {
        requestRestore(snapshotID: snapshotID)
        generation += 1
    }
}

extension Sandbox {
    mutating func setFixtureDesiredStatus(_ newDesired: DesiredSandboxStatus) {
        setDesiredStatus(newDesired)
        generation += 1
    }

    mutating func requestFixtureRestore(snapshotID: UUID) {
        requestRestore(snapshotID: snapshotID)
        generation += 1
    }
}

extension SnapshotArtifactResource {
    func settingFixtureDesiredStatus(_ newDesired: DesiredSnapshotStatus) -> Self {
        replacingDesiredStatus(newDesired)
            .replacingGeneration(generation + 1)
    }
}
