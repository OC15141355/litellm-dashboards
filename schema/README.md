# LiteLLM DB schema reference

Authoritative map of the LiteLLM proxy Postgres schema for **`v1.83.14-stable.patch.3`** (the build both
the work and homelab deployments are pinned to). Built from live introspection + the upstream Prisma schema.

## For an agent (e.g. work-claude) — start here

1. Read **`SCHEMA-MAP.md`** — the curated map: mental model, relationship graph, the cost/spend path
   (incl. the `$0`-spend bug in schema terms + backfill anchor), and a domain-grouped catalog of all 70 tables.
   It is self-contained; you do **not** need web access.
2. For exhaustive column/type/index detail of a specific table, grep **`_introspect-homelab-raw.txt`**
   (live ground truth) or the model block in **`_schema.prisma.v1.83.14-stable.patch.3`** (upstream intent +
   field comments).
3. To answer "does work's DB match this map," run `verify-parity.sql` (below).

## Files

| File | What |
|---|---|
| `SCHEMA-MAP.md` | The reference. Read this first. |
| `introspect.sql` | Read-only structural extractor. Regenerates the spine on any LiteLLM Postgres. |
| `verify-parity.sql` | Read-only fingerprint for work↔homelab schema diff. |
| `_introspect-homelab-raw.txt` | Full live column/PK/FK/index dump (build input). |
| `_schema.prisma.v1.83.14-stable.patch.3` | Upstream Prisma models + field comments (build input). |

## Regenerate / verify

```bash
# DB creds: DATABASE_USERNAME/PASSWORD from the litellm-secrets k8s secret; DB on the configured host.
# Homelab DB lives on docker-01 (litellm-postgres container, postgres:16).

# 1) Re-extract structure (e.g. after a version bump):
psql -U litellm -d litellm -F'|' -tA -f introspect.sql > _introspect-homelab-raw.txt

# 2) Confirm work RDS == homelab (same schema):
#    run on each, then diff — no output means identical structure.
psql "$WORK_DB_URL"    -F'|' -tA -f verify-parity.sql > parity-work.txt
psql "$HOMELAB_DB_URL" -F'|' -tA -f verify-parity.sql > parity-homelab.txt
diff parity-work.txt parity-homelab.txt
```

## Provenance

- Image `ghcr.io/berriai/litellm-database:v1.83.14-stable.patch.3`
  (digest `sha256:ec721a5e4b0decb3658c74b696e315dc3e1c664adbfbadded0564ee2d6cc03bc`).
- 70 tables (69 Prisma models + `_prisma_migrations`); migration head `20260418000000_add_adaptive_router_tables`.
- Snapshot 2026-05-31 from the homelab DB (version-identical to work RDS).
- Pin rationale & CVE/cost-bug posture: see `../docs/cost-tracking-incident-investigation-brief.md`.
