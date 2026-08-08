import Fluent

/// Adds the per-instance metadata kill switch (STR-185): whether the instance
/// metadata service answers this VM at all, EC2's
/// `MetadataOptions.HttpEndpoint`.
///
/// Defaults to true, and the default is the whole reason this is a column
/// rather than a tag: `AddMetadataEnabledToLogicalNetwork` gave operators a
/// per-*network* switch, which means hardening one workload against SSRF costs
/// it a network of its own. This is the same opt-out at the granularity the
/// threat actually has.
///
/// Existing rows take the default, so the migration changes nothing about a
/// running fleet — which is required rather than merely convenient. STR-54's
/// non-overridable allow means a guest's IMDS reachability does not depend on
/// its security groups, so a column that defaulted false would silently
/// blackhole every VM's cloud-init datasource the moment it landed.
struct AddMetadataEnabledToVM: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("vms")
            .field("metadata_enabled", .bool, .required, .sql(.default(true)))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("vms").deleteField("metadata_enabled").update()
    }
}
