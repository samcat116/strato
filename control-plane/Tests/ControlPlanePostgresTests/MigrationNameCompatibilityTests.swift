import ControlPlanePostgres
import Testing

@Suite("Fluent migration ledger compatibility")
struct MigrationNameCompatibilityTests {
    @Test("native migration names exactly preserve the retired Fluent ledger")
    func migrationNames() {
        #expect(
            StratoMigrations.current.map(\.name) == [
                "App.CurrentSchemaBaseline.v1",
                "App.CreateLoadBalancer",
                "App.CreateLoadBalancerListener",
                "App.CreateLoadBalancerBackend",
                "App.AddLoadBalancerCountToResourceQuota",
                "App.BackfillNetworkQuotaAccounting",
                "App.AddAgentDependencyObservations",
                "App.AddMetadataSourceToVM",
                "App.AddAgentMetadataServiceCapability",
                "App.AddMutableMetadataToVM",
                "App.AddGuestAgentEnabledToVM",
                "App.AddAdministrativeTextLengthConstraints",
                "App.CreateVMCommandExecutions",
                "App.ReplaceVolumeReplicaDatasetPath",
                "App.CreateStorageDevices",
                "App.AddAgentEnrollmentBootstrapTokens",
            ]
        )
    }
}
