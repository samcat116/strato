# Membership role UUID cutover

STR-229 replaces every stored grant token with an `iam_roles.id` UUID, makes
`role_bindings` the sole policy store, and drops the project user/group mirror
tables. The schema migration is transactional and refuses an unresolved,
ambiguous, missing, or out-of-scope role. Run this read-only inventory against
each control-plane database before deploying the cutover.

## Preflight inventory

Inventory every legacy token and the number of rows that carry it:

```sql
WITH stored_roles(source, role_token) AS (
    SELECT 'role_bindings', role FROM role_bindings
    UNION ALL
    SELECT 'user_organizations', role FROM user_organizations
    UNION ALL
    SELECT 'project_members', role FROM project_members
    UNION ALL
    SELECT 'project_group_grants', role FROM project_group_grants
    UNION ALL
    SELECT 'oidc_providers', default_role FROM oidc_providers
)
SELECT source, role_token, count(*) AS rows
FROM stored_roles
GROUP BY source, role_token
ORDER BY source, role_token;
```

UUIDs and the seeded names `viewer`, `operator`, `editor`, and `admin` are
unambiguous. `member` means bare membership for organization/OIDC rows and the
seeded editor role for project rows. Every other value is a custom-role name.
List its possible definitions before the migration resolves it in the target
node's owner chain:

```sql
WITH stored_roles(source, role_token) AS (
    SELECT 'role_bindings', role FROM role_bindings
    UNION ALL
    SELECT 'user_organizations', role FROM user_organizations
    UNION ALL
    SELECT 'project_members', role FROM project_members
    UNION ALL
    SELECT 'project_group_grants', role FROM project_group_grants
    UNION ALL
    SELECT 'oidc_providers', default_role FROM oidc_providers
), custom_names AS (
    SELECT DISTINCT role_token
    FROM stored_roles
    WHERE role_token !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      AND role_token NOT IN ('viewer', 'operator', 'editor', 'admin', 'member')
)
SELECT
    names.role_token,
    roles.id AS candidate_role_id,
    roles.owner_type,
    roles.owner_id
FROM custom_names AS names
LEFT JOIN iam_roles AS roles ON roles.name = names.role_token
ORDER BY names.role_token, roles.owner_type, roles.owner_id;
```

A name with no candidate, or more than one candidate bindable at the row's
node, stops the migration. Resolve it before deployment by choosing the intended
live role and replacing the stored token with that exact role UUID. Do not
delete a mirror row to make the migration pass: it may be the only surviving
copy of a grant.

## Post-migration verification

The application migration verifies every retained membership grant has a
canonical binding before dropping anything. After deployment, this query must
return zero legacy columns or mirror tables:

```sql
SELECT 'legacy column' AS kind, table_name || '.' || column_name AS object
FROM information_schema.columns
WHERE table_schema = current_schema()
  AND (
    (table_name = 'role_bindings' AND column_name = 'role')
    OR (table_name = 'user_organizations' AND column_name = 'role')
    OR (table_name = 'oidc_providers' AND column_name = 'default_role')
  )
UNION ALL
SELECT 'legacy table', table_name
FROM information_schema.tables
WHERE table_schema = current_schema()
  AND table_name IN ('project_members', 'project_group_grants');
```

All authoritative role identities must be non-null UUIDs:

```sql
SELECT count(*) AS invalid_bindings
FROM role_bindings
WHERE role_id IS NULL;
```

`invalid_bindings` must be `0`. A failed migration leaves the old schema intact
because `SchemaMigrator` commits the schema change and its migration record in
one transaction; investigate the named row and retry after remediation.
