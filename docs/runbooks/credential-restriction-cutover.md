# Credential restriction cutover

STR-227 removes the historical `read`/`write`/`admin` scope arrays from API
keys, pending device authorizations, and CLI sessions. Run the inventory below
against the production database before deploying the cutover:

```sql
SELECT 'api_keys' AS credential_table,
       count(*) FILTER (WHERE restriction_actions IS NULL) AS needs_backfill,
       count(*) FILTER (
           WHERE restriction_actions IS NULL
             AND NOT (scopes && ARRAY['read', 'write', 'admin']::text[])
       ) AS empty_or_malformed
FROM api_keys
UNION ALL
SELECT 'cli_sessions',
       count(*) FILTER (WHERE restriction_actions IS NULL),
       count(*) FILTER (
           WHERE restriction_actions IS NULL
             AND NOT (scopes && ARRAY['read', 'write', 'admin']::text[])
       )
FROM cli_sessions
UNION ALL
SELECT 'oauth_device_authorizations',
       count(*) FILTER (WHERE restriction_actions IS NULL),
       count(*) FILTER (
           WHERE restriction_actions IS NULL
             AND NOT (scopes && ARRAY['read', 'write', 'admin']::text[])
       )
FROM oauth_device_authorizations;
```

The migration preserves the old effective permission: any `write` or `admin`
entry becomes unrestricted (`{"*"}`), `read` becomes the symbolic read action
(`{"read"}`), and an empty or wholly malformed array becomes an empty action
array (deny all). Recognized entries take precedence over unrelated malformed
entries.

After deployment, verify that all three canonical columns are required and the
legacy columns are absent:

```sql
SELECT table_name, column_name, is_nullable
FROM information_schema.columns
WHERE table_schema = current_schema()
  AND table_name IN ('api_keys', 'cli_sessions', 'oauth_device_authorizations')
  AND column_name IN ('restriction_actions', 'scopes')
ORDER BY table_name, column_name;
```

The result must contain exactly three `restriction_actions` rows, each with
`is_nullable = 'NO'`, and no `scopes` rows.
