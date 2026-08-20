# PostgresNIO migration compatibility baseline

This baseline freezes the persistence contract used while the control plane is
migrated from Fluent to PostgresNIO. It was captured from a clean worktree at
`origin/main` commit `2dbc9a3` with PostgreSQL 16. The reference database was
created by that commit's Fluent migrator; the candidate database was created by
`ControlPlanePostgres.SchemaMigrator` from the same commit.

The migration ledger order is part of the compatibility contract:

1. `App.CurrentSchemaBaseline`
2. `App.CreateLoadBalancer`
3. `App.CreateLoadBalancerListener`
4. `App.CreateLoadBalancerBackend`
5. `App.AddLoadBalancerCountToResourceQuota`
6. `App.BackfillNetworkQuotaAccounting`
7. `App.AddAgentDependencyObservations`
8. `App.AddMetadataSourceToVM`
9. `App.AddAgentMetadataServiceCapability`
10. `App.AddMutableMetadataToVM`
11. `App.AddGuestAgentEnabledToVM`
12. `App.AddAdministrativeTextLengthConstraints`
13. `App.CreateVMCommandExecutions`
14. `App.ReplaceVolumeReplicaDatasetPath`
15. `App.CreateStorageDevices`
16. `App.AddAgentEnrollmentBootstrapTokens`

The native fresh schema must continue to match these catalog fingerprints:

| Catalog | Entries | MD5 |
| --- | ---: | --- |
| Relations | 71 | `e953794cac7964260ab5e965a27887c9` |
| Columns | 925 | `d79ea7bb93a433093f9aa517cdcbca19` |
| Constraints | 328 | `e5965b2127fce5f640bc1171854c7196` |
| Indexes | 210 | `45af49bc929bfbaaf82dd6c876b70d46` |
| Enum entries | 12 | `1b6a9b8ae9bc29bafc0663f3c1666878` |
| Triggers | 1 | `0a93402d631bf28e83d754d849fbe76b` |
| Functions | 1 | `f42045aa59da47a5032d695f92e585c8` |
| Extensions | 1 | `e2789c545aaac4fd5c1fcbf1364795b0` |
| Migration ledger | 16 | `c525fdfa47385a9e380ed6492c8a861e` |

`SchemaMigrationCompatibilityTests` recomputes every fingerprint from a fresh
native migration. A migration that lands before the final schema freeze must
retain its exact Fluent ledger name and update this baseline only after its
Fluent and native catalogs compare exactly.

The migration deliberately retains `_fluent_migrations`, `_fluent_sessions`,
and `_fluent_enums`. Their names do not imply a runtime Fluent dependency and
their removal requires a separate evidence-gated cleanup.
