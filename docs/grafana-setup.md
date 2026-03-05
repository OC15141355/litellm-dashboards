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
| **Overview** | Total Spend, Requests, Tokens, Success Rate | `LiteLLM_DailyTeamSpend` |
| **Spend Over Time** | Daily Spend by Model (stacked bars), Spend by Model (donut) | `LiteLLM_DailyTeamSpend` |
| **Team Breakdown** | Spend by Team (bar), Budget vs Actual (table with gauge) | `LiteLLM_DailyTeamSpend` + `LiteLLM_TeamTable` |
| **User Breakdown** | Daily Spend by User (stacked bars), User Activity (table) | `LiteLLM_DailyUserSpend` + `LiteLLM_UserTable` |
| **Request Analysis** | Daily Requests by Model, Daily Tokens by Model | `LiteLLM_DailyTeamSpend` |
| **Raw Logs** | Recent Requests drill-down (collapsed) | `LiteLLM_SpendLogs` |

### Variables

| Variable | Purpose |
|----------|---------|
| `datasource` | PostgreSQL datasource selector (portability between environments) |
| `team` | Team filter — dropdown populated from `LiteLLM_TeamTable`. "All Teams" shows everything. |

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

### Option A: Grafana Folders + Local Users (Recommended)

Best for: controlled access, team leads see only their team.

**Setup:**

1. **Create Grafana folders** — one per team:
   - `LiteLLM — Engineering`
   - `LiteLLM — Data Science`
   - etc.

2. **Deploy team-specific dashboards** — import the same dashboard JSON into each folder, but set the `team` variable default to that team's `team_id` and hide the variable:
   - Edit dashboard → Settings → Variables → `team`
   - Set **Default** to the team's UUID
   - Set **Hide** to "Variable" (hides the dropdown)
   - Save

3. **Create Grafana users** for team leads:
   - Admin → Users → New user
   - Username: their email
   - Role: Viewer

4. **Set folder permissions**:
   - Folder → Permissions → remove default permissions
   - Add the team lead as Viewer on their folder only
   - Admin retains access to all folders

**Result:** Team lead logs into Grafana, sees only their folder with their team's spend dashboard. No team variable to change, no access to other teams.

### Option B: Public Dashboard Links

Best for: simplest setup, internal network only.

1. Open the dashboard filtered to a specific team
2. Dashboard → Share → Public Dashboard → Enable
3. Copy the public link
4. Send to the team lead

**Pros:** No Grafana accounts needed, just a URL.
**Cons:** Anyone with the link can view. Only use on internal/VPN networks.

### Option C: Postgres Row-Level Security

Best for: maximum security, larger deployments.

1. Create a Postgres role per team
2. Enable RLS on the daily spend tables
3. Create policies: `CREATE POLICY team_isolation ON "LiteLLM_DailyTeamSpend" FOR SELECT USING (team_id = current_setting('app.team_id'))`
4. Create a Grafana datasource per team, each connecting as their role

**Pros:** Database-level isolation, impossible to bypass.
**Cons:** Highest setup/maintenance overhead.

### Comparison

| Approach | Setup Effort | Security | Maintenance |
|----------|-------------|----------|-------------|
| Folders + Local Users | Low | Good — Grafana RBAC | Add user per team lead |
| Public Links | Minimal | Low — link-based | Regenerate if compromised |
| Postgres RLS | High | Strongest | DB role per team |

**Recommendation:** Start with **Option A** (Folders + Local Users). It's the right balance of security and simplicity for a team of 3-10 leads.

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
