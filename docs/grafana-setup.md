# Grafana Dashboard Setup — LiteLLM Cost Attribution

PostgreSQL-backed Grafana dashboard for accurate historical spend tracking. Reads directly from LiteLLM's database — no Prometheus counter resets, no data loss on pod restarts.

---

## Why PostgreSQL Instead of Prometheus?

| | Prometheus | PostgreSQL |
|---|---|---|
| Data source | `/metrics` endpoint (counters) | LiteLLM database tables |
| Survives pod restart | No — counters reset to zero | Yes — persistent |
| Historical accuracy | Gaps on restarts, scrape misses | Exact per-request data |
| Best for | Real-time alerting, instant metrics | Historical reporting, chargebacks |

The LiteLLM UI reads from PostgreSQL. This dashboard reads from the same tables, so the numbers always match.

---

## Dashboard Overview

**File:** `grafana/litellm-postgres-dashboard.json`

### Panels

| Section | Panels | Data Source Table |
|---------|--------|-------------------|
| **Overview** | Total Spend, vs Previous Period (%), Total Requests, Avg Cost/Request, Total Tokens, Success Rate, Budget Remaining | `LiteLLM_DailyTeamSpend` + `LiteLLM_TeamTable` |
| **Spend Over Time** | Daily Spend by Model (stacked bars), Spend by Model (donut) | `LiteLLM_DailyTeamSpend` |
| **Team Overview** | Daily Spend by User (stacked bars), User Spend & Budget (table with usage gauge) | `LiteLLM_DailyUserSpend` + `LiteLLM_UserTable` |
| **Request Analysis** | Daily Requests by Model, Daily Tokens by Model (collapsed) | `LiteLLM_DailyTeamSpend` |
| **Raw Logs** | Recent Requests drill-down (collapsed) | `LiteLLM_SpendLogs` |

The dashboard is designed for **team leads**, not admins. The default view shows per-user spend trends and budget tracking. Admin-level views (all teams, operations metrics) are covered by the Prometheus-based dashboards.

### Variables

| Variable | Type | Purpose |
|----------|------|---------|
| `datasource` | Datasource | PostgreSQL datasource selector (portability between environments) |
| `team` | Query | Team filter — dropdown populated from `LiteLLM_TeamTable`. "All" shows all teams. Single-select with `IN ($team)` for Grafana 12 compatibility. |

> **Grafana 12 note:** The PostgreSQL backend plugin does not interpolate dashboard variables inside SQL string literals (`'$var'`). All queries use `column IN ($team)` instead. Grafana handles the quoting automatically.

---

## Setup: PostgreSQL Datasource

### Prerequisites

- Grafana with PostgreSQL plugin (included by default)
- Network access from Grafana to the LiteLLM PostgreSQL instance
- A read-only database user (recommended)

### Create a Read-Only DB User (Recommended)

```sql
-- Connect to the LiteLLM database as admin
CREATE ROLE grafana_reader WITH LOGIN PASSWORD 'your-secure-password';
GRANT CONNECT ON DATABASE litellm TO grafana_reader;
GRANT USAGE ON SCHEMA public TO grafana_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO grafana_reader;
```

### Add Datasource in Grafana

1. **Configuration → Data Sources → Add data source → PostgreSQL**
2. Fill in:
   - **Name:** `LiteLLM PostgreSQL`
   - **Host:** `<db-host>:5432`
   - **Database:** `litellm`
   - **User:** `grafana_reader`
   - **Password:** (from above)
   - **TLS/SSL Mode:** `require` (for RDS) or `disable` (for homelab)
   - **Version:** 15 (or your Postgres version)
3. Click **Save & test**

### Environment-Specific Connection Details

| Environment | Host | Database | Notes |
|-------------|------|----------|-------|
| Homelab | `192.168.0.21:5432` | `litellm` | docker-01, direct access from cluster |
| Work Dev | `<rds-endpoint>:5432` | `<db-name>` | RDS, needs VPC access from Grafana |
| Work Prod | `<rds-endpoint>:5432` | `<db-name>` | RDS, needs VPC access from Grafana |

---

## Deployment: Homelab (ArgoCD)

The dashboard JSON can be loaded via a Grafana ConfigMap with the sidecar label.

### Create ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: litellm-cost-attribution-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  litellm-cost-attribution.json: |
    <paste dashboard JSON here>
```

Or reference the file directly in kustomize.

### Grafana Sidecar

Grafana's sidecar (deployed with kube-prometheus-stack) watches for ConfigMaps with `grafana_dashboard: "1"` and auto-loads them. No restart needed.

---

## Deployment: Work (Rancher Monitoring)

Rancher's built-in Grafana uses the same sidecar pattern.

### Step 1: Create ConfigMap

```bash
kubectl create configmap litellm-cost-dashboard \
  --from-file=litellm-cost-attribution.json=grafana/litellm-postgres-dashboard.json \
  -n cattle-monitoring-system

kubectl label configmap litellm-cost-dashboard \
  grafana_dashboard="1" \
  -n cattle-monitoring-system
```

### Step 2: Add PostgreSQL Datasource

Either via Grafana UI (Configuration → Data Sources) or via a datasource ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: litellm-postgres-datasource
  namespace: cattle-monitoring-system
  labels:
    grafana_datasource: "1"
data:
  litellm-postgres.yaml: |
    apiVersion: 1
    datasources:
      - name: LiteLLM PostgreSQL
        type: postgres
        access: proxy
        url: <rds-endpoint>:5432
        database: <db-name>
        user: grafana_reader
        secureJsonData:
          password: <password>
        jsonData:
          sslmode: require
          postgresVersion: 1500
```

### Step 3: Verify

Dashboard should appear in Grafana under **Dashboards → Browse → LiteLLM Cost Attribution**.

---

## Team-Scoped Access (Without LiteLLM Enterprise)

LiteLLM SSO/RBAC requires an enterprise license. Instead, control access at the **Grafana layer**.

> **Note on `${__user.email}`:** Grafana 12's PostgreSQL backend plugin does **not** interpolate built-in `${__user.*}` variables in SQL queries. Auto-filtering the `$team` dropdown based on the logged-in user's identity is not possible with the PostgreSQL datasource. The options below work around this limitation.

### Option A: Bookmarked Team URLs (Recommended)

Best for: quick setup, low maintenance, trust-based isolation.

**How it works:** Each team lead gets a pre-filtered dashboard URL with their team_id baked in. They land directly on their team's view.

**Setup:**

1. **Get each team's ID** from LiteLLM:
   ```bash
   curl -s "$LITELLM_URL/team/list" -H "Authorization: Bearer $MASTER_KEY" | \
     jq -r '.[] | "\(.team_id)\t\(.team_alias)"'
   ```

2. **Generate team-specific URLs:**
   ```
   https://grafana.example.com/d/litellm-cost-attribution?var-team=<team_id>
   ```

3. **Distribute URLs** — include in onboarding, pin in team Slack channels, or add to internal wiki.

4. **Optional: Create Grafana users** with Viewer role for team leads. This prevents anonymous access and gives basic audit trail.

**Pros:** Zero Grafana config beyond user accounts. Works with any auth method.
**Cons:** Team leads can change the URL to see other teams (soft isolation). Acceptable when there's no competitive reason to snoop.

**Integration with onboarding script:**

Add to your onboard script output:
```bash
echo "Dashboard URL: https://grafana.example.com/d/litellm-cost-attribution?var-team=${TEAM_ID}"
```

### Option B: Grafana Folders + Hidden Variable

Best for: hard isolation, team leads cannot see other teams.

**Setup:**

1. **Create Grafana folders** — one per team:
   - `LiteLLM — Platform Engineering`
   - `LiteLLM — Backend`

2. **Import the dashboard into each folder** with a locked team filter:
   - Edit dashboard → Settings → Variables → `team`
   - Set **Default** to the team's `team_id`
   - Set **Hide** to "Variable" (hides the dropdown entirely)
   - Save as a new dashboard in the team's folder

3. **Set folder permissions**:
   - Folder → Permissions → remove default org-level access
   - Add the team lead as Viewer on their folder only

**Pros:** True isolation — team leads cannot see other teams' data.
**Cons:** One dashboard copy per team. When updating the dashboard, you must re-import to each folder (or script it).

### Option C: Postgres Row-Level Security

Best for: maximum security, regulated environments.

1. Create a Postgres role per team
2. Enable RLS on the daily spend tables:
   ```sql
   ALTER TABLE "LiteLLM_DailyTeamSpend" ENABLE ROW LEVEL SECURITY;
   CREATE POLICY team_isolation ON "LiteLLM_DailyTeamSpend"
     FOR SELECT USING (team_id = current_setting('app.team_id'));
   ```
3. Create a Grafana datasource per team, each connecting as their role with `SET app.team_id` in the connection init

**Pros:** Database-level isolation, impossible to bypass.
**Cons:** Highest setup/maintenance overhead. One datasource per team in Grafana.

### Comparison

| Approach | Setup Effort | Isolation | Maintenance | Best For |
|----------|-------------|-----------|-------------|----------|
| **Bookmarked URLs** | Minimal | Soft (trust-based) | None | Most teams, pilot phase |
| Folders + Hidden Var | Medium | Hard (Grafana RBAC) | Re-import on updates | Strict access control |
| Postgres RLS | High | Strongest (DB-level) | DB role per team | Regulated environments |

**Recommendation:** Start with **Option A** (Bookmarked URLs). It's zero-maintenance and works immediately. Move to Option B if teams request hard isolation.

---

## Database Tables Used

| Table | Purpose | Key Columns |
|-------|---------|-------------|
| `LiteLLM_DailyTeamSpend` | Pre-aggregated daily team metrics | `team_id`, `date`, `model`, `spend`, `api_requests`, `prompt_tokens`, `completion_tokens` |
| `LiteLLM_DailyUserSpend` | Pre-aggregated daily user metrics | `user_id`, `date`, `api_key`, `model`, `spend`, `api_requests` |
| `LiteLLM_TeamTable` | Team metadata | `team_id`, `team_alias`, `max_budget`, `spend` |
| `LiteLLM_UserTable` | User metadata | `user_id`, `user_email`, `user_role` |
| `LiteLLM_SpendLogs` | Raw per-request logs | `request_id`, `startTime`, `user`, `team_id`, `model`, `spend`, `prompt_tokens`, `completion_tokens` |
| `LiteLLM_VerificationToken` | API keys (for user↔team join) | `token`, `user_id`, `team_id`, `key_alias` |

The daily aggregation tables (`LiteLLM_Daily*Spend`) are populated automatically by LiteLLM. They're much more efficient for dashboard queries than scanning `LiteLLM_SpendLogs` directly.

---

## Troubleshooting

### Dashboard shows no data

1. **Check datasource** — click the datasource dropdown, verify it's connected (green checkmark)
2. **Check time range** — default is 30 days. If LiteLLM was just deployed, try "Last 7 days"
3. **Check daily tables** — run in Grafana's Explore tab:
   ```sql
   SELECT COUNT(*) FROM "LiteLLM_DailyTeamSpend";
   ```
   If zero, LiteLLM hasn't aggregated yet (happens after first requests)
4. **Check team variable** — if filtered to a specific team, verify the team_id exists

### Numbers don't match LiteLLM UI

- **Time zone** — Grafana may use browser timezone, LiteLLM stores UTC. Set dashboard timezone to UTC.
- **Date boundaries** — daily tables use date strings (YYYY-MM-DD). Grafana time picker is timestamp-based. Minor discrepancies at day boundaries are normal.

### Dashboard loads slowly

- The **Raw Request Logs** panel queries `LiteLLM_SpendLogs` which can be large. It's collapsed by default — only opens on click.
- If slow, reduce the time range or add an index: `CREATE INDEX idx_spend_logs_time ON "LiteLLM_SpendLogs" ("startTime" DESC);`
