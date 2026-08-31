import Fluent
import FluentPostgresDriver
import NIOSSL
import Vapor

extension Application {
    /// Configures PostgreSQL, registers the ordered schema history, and runs it
    /// through the serialized migration runner.
    func bootstrapDatabase() async throws {
        let statementTimeouts = try configureDatabaseDriver()
        registerMigrations()

        var options = SchemaMigrator.Options.fromConfiguration(controlPlaneConfiguration)
        options.statementTimeouts = statementTimeouts
        try await SchemaMigrator.run(on: self, options: options)
    }

    private func configureDatabaseDriver() throws -> SchemaMigrator.StatementTimeouts? {
        guard environment != .testing else { return nil }

        let databaseTLS = try makeDatabaseTLS(
            configuration: controlPlaneConfiguration, logger: logger)
        let statementTimeout = try DatabaseStatementTimeout(
            milliseconds: controlPlaneConfiguration.int(.databaseStatementTimeoutMS)!)
        let migrationStatementTimeout = try DatabaseStatementTimeout(
            milliseconds: controlPlaneConfiguration.int(.databaseMigrationStatementTimeoutMS)!)
        let statementTimeouts = SchemaMigrator.StatementTimeouts(
            normal: statementTimeout,
            migration: migrationStatementTimeout
        )
        let databaseConfiguration = SQLPostgresConfiguration(
            hostname: controlPlaneConfiguration.string(.databaseHost)!,
            port: controlPlaneConfiguration.int(.databasePort)!,
            username: controlPlaneConfiguration.string(.databaseUsername)!,
            password: controlPlaneConfiguration.string(.databasePassword)!,
            database: controlPlaneConfiguration.string(.databaseName)!,
            tls: databaseTLS
        )
        logger.info(
            "Database statement timeouts configured",
            metadata: [
                "servingMilliseconds": .stringConvertible(statementTimeout.milliseconds),
                "migrationMilliseconds": .stringConvertible(migrationStatementTimeout.milliseconds),
            ])
        databases.use(
            statementTimeout.applying(
                to: DatabaseConfigurationFactory.postgres(configuration: databaseConfiguration)
            ), as: .psql)
        return statementTimeouts
    }

    private func registerMigrations() {
        migrations.add(CurrentSchemaBaseline())
        migrations.add(CreateLoadBalancer())
        migrations.add(CreateLoadBalancerListener())
        migrations.add(CreateLoadBalancerBackend())
        migrations.add(AddLoadBalancerCountToResourceQuota())
        migrations.add(BackfillNetworkQuotaAccounting())
        migrations.add(AddAgentDependencyObservations())
        migrations.add(AddMetadataSourceToVM())
        migrations.add(AddAgentMetadataServiceCapability())
        migrations.add(AddMutableMetadataToVM())
        migrations.add(AddGuestAgentEnabledToVM())
        migrations.add(AddAdministrativeTextLengthConstraints())
        migrations.add(CreateVMCommandExecutions())
        migrations.add(ReplaceVolumeReplicaDatasetPath())
        migrations.add(CreateStorageDevices())
    }
}
