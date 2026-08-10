# ADR 0009: Fresh databases start from one current-schema baseline

- **Status**: Accepted
- **Date**: 2026-08-09
- **Deciders**: Sam Schmitt
- **Scope**: control-plane PostgreSQL schema creation and the STR-234 cutover
- **Affects**: every deployment upgrading from the executable historical
  migration chain

## Context

The control plane registered 189 historical migrations and compiled their
helper source. They
described every intermediate representation since the first schema, including
models and backfills that the application can no longer use. That made the
fresh-install schema difficult to review and kept compatibility-only types in
the production binary.

The final chain at commit `74b81d8` produced 64 application tables, 841 columns,
286 constraints, 190 indexes, three PostgreSQL enum types, one trigger, and one
function. Git retains every deleted migration and its rationale; executable
runtime code does not need to be the archive.

## Decision

`CurrentSchemaBaseline` is the only registered migration. It
applies the reviewed `CurrentSchema.sql` resource, generated with `pg_dump
--schema-only` from a fresh database migrated by the chain at `74b81d8`.
`SchemaMigrator` is unchanged: it still holds the PostgreSQL advisory lock and
commits the baseline DDL and its `_fluent_migrations` row in one transaction.

The baseline is irreversible. Reverting it would be equivalent to deleting the
database, so teardown must discard the database explicitly.

## Existing databases require a rebuild

There is no in-place marker migration. The baseline queries `pg_tables` before
executing DDL and accepts only a schema with no application tables (the
`_fluent_migrations` bookkeeping table is ignored because `SchemaMigrator`
creates it before previewing migrations). If any application table exists, the
process fails with the complete table list before the baseline changes schema or
data.

Operators must therefore:

1. Back up the old database and stop every control-plane writer.
2. Export data that must be retained through current domain APIs or a reviewed
   ETL. Do not restore the old schema dump into the new database.
3. Point the control plane at a newly created empty database and let the
   baseline run.
4. Import retained data through the current model and verify resource counts and
   relationships before serving traffic.

This is intentionally a deployment boundary. Automatically marking an
arbitrary historical database as current would claim constraints and backfills
exist without proving them; replaying the baseline over it would collide with
objects and could conceal partial state.

## Verification and provenance

The committed schema was captured from PostgreSQL 16 after the final chain ran
on an empty database. The obsolete global default network created early in that
chain was removed in the disposable capture database so the site cutover could
continue; the later project-network cutover removes the same compatibility row,
and it is absent from the resulting current schema. A catalog manifest covering
enum values, columns and defaults, constraints, index definitions, triggers,
and functions hashed to:

`42a63d3b96fe17dcf08346be422d3f036ba89689aab6e376af15c786e8d26287`

The in-database MD5 used by the regression test (to avoid client newline and
encoding differences) is `79bd505a06c0e20e36d670eb8302201c`.

The baseline tests apply only `CurrentSchemaBaseline` to an empty database and
compare that same catalog manifest. They also verify that a populated unknown
schema is rejected without changing its sentinel row or recording the baseline.
The historical migration sources remain available in Git at `74b81d8` and its
ancestors when a past transition needs forensic review.

## Consequences

- Fresh-install behavior is one migration and one reviewable SQL definition.
- Historical snapshot-only models are no longer compiled.
- Future schema changes append normal forward migrations after the baseline;
  they do not edit a baseline that has already shipped.
- Existing installations cannot upgrade this boundary in place. That cost is
  explicit and test-enforced instead of being an implicit risk to retained data.
