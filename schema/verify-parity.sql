-- verify-parity.sql — normalized schema fingerprint for work↔homelab parity (READ-ONLY)
-- Run on BOTH deployments, capture output, then `diff` the two files. Identical output =
-- identical schema (same LiteLLM build). Any diff line = a real schema drift to investigate.
--
--   psql -U litellm -d litellm -F'|' -tA -f verify-parity.sql > parity-<host>.txt
--   diff parity-work.txt parity-homelab.txt   # expect: no output
--
-- Deterministic: every section is ORDER BY'd. Excludes volatile data (row counts, sizes, timestamps)
-- so only STRUCTURE is compared. Verified against v1.83.14-stable.patch.3.

\echo ### MIGRATION_HEAD
SELECT migration_name FROM _prisma_migrations WHERE finished_at IS NOT NULL
ORDER BY finished_at DESC LIMIT 1;

\echo ### MIGRATION_COUNT
SELECT count(*) FROM _prisma_migrations WHERE finished_at IS NOT NULL;

\echo ### COLUMNS   -- table|column|type|nullable|default
SELECT table_name||'|'||column_name||'|'||data_type||'|'||is_nullable||'|'||coalesce(column_default,'')
FROM information_schema.columns WHERE table_schema='public'
ORDER BY table_name, column_name;

\echo ### PRIMARY_KEYS   -- table|col
SELECT tc.table_name||'|'||kcu.column_name
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON tc.constraint_name=kcu.constraint_name AND tc.table_schema=kcu.table_schema
WHERE tc.constraint_type='PRIMARY KEY' AND tc.table_schema='public'
ORDER BY tc.table_name, kcu.column_name;

\echo ### FOREIGN_KEYS   -- table|col->reftable.refcol (on delete)
SELECT tc.table_name||'|'||kcu.column_name||'->'||ccu.table_name||'.'||ccu.column_name||' ('||rc.delete_rule||')'
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu ON tc.constraint_name=kcu.constraint_name
JOIN information_schema.constraint_column_usage ccu ON ccu.constraint_name=tc.constraint_name
JOIN information_schema.referential_constraints rc ON rc.constraint_name=tc.constraint_name
WHERE tc.constraint_type='FOREIGN KEY' AND tc.table_schema='public'
ORDER BY tc.table_name, kcu.column_name, ccu.table_name;

\echo ### INDEXES   -- normalized index definitions
SELECT regexp_replace(indexdef, '^CREATE (UNIQUE )?INDEX [^ ]+ ON', 'IDX ON')
FROM pg_indexes WHERE schemaname='public'
ORDER BY 1;

\echo ### VIEWS   -- view name + normalized definition (catches drift-orphan / version differences)
SELECT table_name || ' :: ' || regexp_replace(view_definition, '\s+', ' ', 'g')
FROM information_schema.views WHERE table_schema='public'
ORDER BY table_name;
