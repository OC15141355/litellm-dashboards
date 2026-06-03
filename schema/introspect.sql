-- introspect.sql — LiteLLM Postgres ground-truth schema extractor (READ-ONLY)
-- Usage:  psql -U litellm -d litellm -F'|' -tA -f introspect.sql
-- Emits section-delimited (### MARKER) pipe-separated rows. Reproduces the structural
-- spine of SCHEMA-MAP.md on any LiteLLM Postgres; diff two runs for version/parity drift.
-- Verified against ghcr.io/berriai/litellm-database:v1.83.14-stable.patch.3.

\echo ### VERSION
SELECT 'postgres', version();
SELECT 'migrations_applied', count(*) FROM _prisma_migrations WHERE finished_at IS NOT NULL;
SELECT 'latest_migration', migration_name FROM _prisma_migrations WHERE finished_at IS NOT NULL ORDER BY finished_at DESC LIMIT 1;

\echo ### TABLES
SELECT c.relname, c.reltuples::bigint, pg_size_pretty(pg_total_relation_size(c.oid))
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public' AND c.relkind='r' ORDER BY c.relname;

\echo ### COLUMNS
SELECT table_name, ordinal_position, column_name, data_type, is_nullable, coalesce(column_default,'')
FROM information_schema.columns WHERE table_schema='public'
ORDER BY table_name, ordinal_position;

\echo ### PRIMARY_KEYS
SELECT tc.table_name, kcu.column_name
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON tc.constraint_name=kcu.constraint_name AND tc.table_schema=kcu.table_schema
WHERE tc.constraint_type='PRIMARY KEY' AND tc.table_schema='public'
ORDER BY tc.table_name, kcu.ordinal_position;

\echo ### FOREIGN_KEYS
SELECT tc.table_name, kcu.column_name, ccu.table_name AS ref_table, ccu.column_name AS ref_col, rc.delete_rule
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu ON tc.constraint_name=kcu.constraint_name
JOIN information_schema.constraint_column_usage ccu ON ccu.constraint_name=tc.constraint_name
JOIN information_schema.referential_constraints rc ON rc.constraint_name=tc.constraint_name
WHERE tc.constraint_type='FOREIGN KEY' AND tc.table_schema='public'
ORDER BY tc.table_name, kcu.column_name;

\echo ### INDEXES
SELECT tablename, indexname, indexdef FROM pg_indexes
WHERE schemaname='public' ORDER BY tablename, indexname;

\echo ### VIEWS
-- LiteLLM ships 8 admin-UI spend-analytics views (relkind 'v') — NOT Prisma models, NOT in the TABLES section above.
SELECT table_name, regexp_replace(view_definition, '\s+', ' ', 'g')
FROM information_schema.views WHERE table_schema='public' ORDER BY table_name;
