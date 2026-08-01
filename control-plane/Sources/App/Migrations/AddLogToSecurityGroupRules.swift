import Fluent

/// Per-rule ACL logging (STR-34): the agent maps this onto the OVN ACL's
/// `log`/`severity`/`name` columns so operators can see which rule admitted a
/// flow.
///
/// Required with a `false` default rather than nullable: every rule written
/// before this column meant "don't log", and the default backfills them in
/// one statement. A nullable column would also make the wire mapping
/// ambiguous — a nil `DesiredSecurityGroupRule.log` from an older control
/// plane already means "off", so a third state would say nothing new.
struct AddLogToSecurityGroupRules: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("security_group_rules")
            .field("log", .bool, .required, .sql(.default(false)))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("security_group_rules")
            .deleteField("log")
            .update()
    }
}
