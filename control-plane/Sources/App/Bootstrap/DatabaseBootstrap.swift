import ControlPlanePostgres
import Vapor

extension Application {
    /// Starts native PostgreSQL, installs the concrete persistence modules, and
    /// runs the compatible schema history through the serialized migrator.
    func bootstrapDatabase() async throws -> ControlPlanePersistence {
        let configuration: ControlPlanePostgres.PostgresDatabase.Configuration
        if let override = nativePostgresConfigurationOverride {
            configuration = override
        } else {
            configuration = try .init(
                hostname: controlPlaneConfiguration.string(.databaseHost)!,
                port: controlPlaneConfiguration.int(.databasePort)!,
                username: controlPlaneConfiguration.string(.databaseUsername)!,
                password: controlPlaneConfiguration.string(.databasePassword),
                database: controlPlaneConfiguration.string(.databaseName)!,
                tls: makeNativeDatabaseTLS(
                    configuration: controlPlaneConfiguration,
                    logger: logger
                ),
                maximumConnections: controlPlaneConfiguration.int(.databaseMaxConnections)!,
                connectionAcquireTimeout: .milliseconds(
                    controlPlaneConfiguration.int(.databaseConnectionAcquireTimeoutMS)!),
                statementTimeoutMilliseconds: controlPlaneConfiguration.int(
                    .databaseStatementTimeoutMS)!
            )
        }

        let database = ControlPlanePostgres.PostgresDatabase(
            configuration: configuration,
            eventLoopGroup: eventLoopGroup,
            logger: logger
        )
        lifecycle.use(NativePostgresLifecycleHandler(database: database))
        try await database.start()

        let persistence = ControlPlanePersistence(database: database)
        installPersistenceModules(persistence)

        // Vapor shuts lifecycle handlers down in reverse order. Register the
        // background-work registry after the database handler so tracked work
        // drains before the native client and its pool close.
        setUpBackgroundTaskRegistry()

        let migrator = try ControlPlanePostgres.SchemaMigrator(
            database: database,
            migrations: StratoMigrations.current,
            logger: logger
        )
        try await migrator.run(
            options: .init(
                runMigrations: controlPlaneConfiguration.bool(.runMigrations)!,
                lockTimeout: .milliseconds(
                    Int64(
                        controlPlaneConfiguration.double(.migrationLockTimeoutSeconds) * 1_000)),
                lockPollInterval: .milliseconds(
                    Int64(
                        controlPlaneConfiguration.double(.migrationLockPollSeconds) * 1_000)),
                servingStatementTimeoutMilliseconds: controlPlaneConfiguration.int(
                    .databaseStatementTimeoutMS)!,
                migrationStatementTimeoutMilliseconds: controlPlaneConfiguration.int(
                    .databaseMigrationStatementTimeoutMS)!
            ))

        return persistence
    }

    private func installPersistenceModules(_ persistence: ControlPlanePersistence) {
        if environment == .testing {
            testPostgres = persistence.storeContext
        }

        observedStateApplier = ObservedStateApplier(
            app: self,
            database: persistence.storeContext,
            workloads: persistence.workloads
        )
        desiredStateAssembler = DesiredStateAssembler(
            app: self,
            database: persistence.storeContext,
            workloads: persistence.workloads,
            floatingIPAllocations: persistence.floatingIPAllocations
        )
        imageFetchService = ImageFetchService(app: self, database: persistence.storeContext)
        policySetVersion = PolicySetVersionCache(logger: logger, iam: persistence.iam)
        cedarPolicySet = CedarPolicySetCache(logger: logger, iam: persistence.iam)
        decisionLogsPersistence = persistence.decisionLogs
        storagePoolsPersistence = persistence.storagePools
        oauthDeviceSessionsPersistence = persistence.oauthDeviceSessions
        apiKeysPersistence = persistence.apiKeys
        userDirectoryPersistence = persistence.userDirectory
        scimTokensPersistence = persistence.scimTokens
        ssfStreamsPersistence = persistence.ssfStreams
        passkeysPersistence = persistence.passkeys
        accountRecoveryPersistence = persistence.accountRecovery
        agentEnrollmentsPersistence = persistence.agentEnrollments
        oidcProvidersPersistence = persistence.oidcProviders
        scimExternalIDsPersistence = persistence.scimExternalIDs
        groupsPersistence = persistence.groups
        hierarchyPersistence = persistence.hierarchy
        iamPersistence = persistence.iam
        serviceAccountsPersistence = persistence.serviceAccounts
        orgTrustDomainsPersistence = persistence.orgTrustDomains
        projectsPersistence = persistence.projects
        networksPersistence = persistence.networks
        sitesPersistence = persistence.sites
        floatingIPPoolsPersistence = persistence.floatingIPPools
        resourceQuotasPersistence = persistence.resourceQuotas
        registryPullSecretsPersistence = persistence.registryPullSecrets
        workloadsPersistence = persistence.workloads
        vmCommandExecutionsPersistence = persistence.vmCommandExecutions
        webhookSubscriptionsPersistence = persistence.webhookSubscriptions
        webhookDeliveriesPersistence = persistence.webhookDeliveries
        vmCommandExecutionService = VMCommandExecutionService(
            app: self,
            persistence: persistence.vmCommandExecutions)
        ssf = SSFService(
            app: self,
            configuration: controlPlaneConfiguration,
            apiKeys: persistence.apiKeys,
            streams: persistence.ssfStreams,
            userSecurity: persistence.userSecurity
        )
        audit = AuditService(
            app: self,
            config: .fromConfiguration(controlPlaneConfiguration),
            events: persistence.auditEvents
        )
    }
}
