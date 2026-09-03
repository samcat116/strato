import Foundation
import StratoShared

@testable import App

// Production mutation helpers deliberately change intent without assigning a
// generation. Tests that construct a persisted historical state use these
// helpers to model the generation that its original writer would have minted.
extension VM {
    package func setFixtureDesiredStatus(_ newDesired: DesiredVMStatus) {
        setDesiredStatus(newDesired)
        generation += 1
    }

    package func requestFixtureReboot() {
        requestReboot()
        generation += 1
    }

    package func requestFixtureRestore(snapshotID: UUID) {
        requestRestore(snapshotID: snapshotID)
        generation += 1
    }
}

extension Sandbox {
    package func setFixtureDesiredStatus(_ newDesired: DesiredSandboxStatus) {
        setDesiredStatus(newDesired)
        generation += 1
    }

    package func requestFixtureRestore(snapshotID: UUID) {
        requestRestore(snapshotID: snapshotID)
        generation += 1
    }
}

extension Volume {
    package func setFixtureDesiredStatus(_ newDesired: DesiredVolumeStatus) {
        setDesiredStatus(newDesired)
        generation += 1
    }

    package func bumpFixtureGeneration() {
        generation += 1
    }
}

extension SnapshotArtifactResource {
    package func setFixtureDesiredStatus(_ newDesired: DesiredSnapshotStatus) {
        setDesiredStatus(newDesired)
        generation += 1
    }
}
