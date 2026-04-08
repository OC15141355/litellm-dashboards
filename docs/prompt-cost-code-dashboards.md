# Prompt: Integrate Cost Code Mapping into Grafana Dashboards

## Context

We have a LiteLLM proxy deployment with cost attribution dashboards in Grafana (v12, OSS), backed by a PostgreSQL datasource that reads from LiteLLM's database.

We've built two scripts:
- `cost-mapping.sh` — pulls Charge Code data from Jira Assets (Data Center REST API, object type ID 19, cost code attribute ID 349) and interactively maps them to LiteLLM teams
- `spend-report.sh` — generates cost attribution reports per team/user with date filtering

The cost mapping script outputs a `cost-mapping.json` file. We now want to persist this mapping in the LiteLLM PostgreSQL database as a custom table and have Grafana use it to display cost codes alongside team spend data in dashboards.

LiteLLM only manages its own `LiteLLM_*` prefixed tables. A custom table in the same database will not interfere with LiteLLM's schema, migrations, or operations.

## Important

- **Do NOT modify existing dashboards.** The team lead and admin dashboards are already deployed and working. Only create the new finance dashboard and the database table.
- **Follow this sequence — one step at a time, wait for confirmation before proceeding:**

1. First, read and understand the `cost-mapping.sh` script (I will point you to it)
2. I will run the script and show you the output
3. Then design the `cost_code_mapping` table based on the actual script output
4. Update the script to upsert into PostgreSQL
5. Finally, build the Grafana finance dashboard

## What I Need

### 1. Create a `cost_code_mapping` table

Create a table in the LiteLLM PostgreSQL database:

```sql
CREATE TABLE cost_code_mapping (
  team_id TEXT PRIMARY KEY,
  team_alias TEXT,
  cost_code TEXT NOT NULL,
  cost_code_name TEXT,
  jira_asset_id TEXT,
  updated_at TIMESTAMP DEFAULT NOW()
);
```

- `team_id` — matches `LiteLLM_TeamTable.team_id`
- `cost_code` — the Jira Charge Code value (e.g. "CC-1234")
- `cost_code_name` — human-readable name for the cost code
- `jira_asset_id` — reference back to the Jira asset for traceability

### 2. Update `cost-mapping.sh` to write to PostgreSQL

Instead of (or in addition to) writing `cost-mapping.json`, the script should upsert into the `cost_code_mapping` table:

```sql
INSERT INTO cost_code_mapping (team_id, team_alias, cost_code, cost_code_name, jira_asset_id, updated_at)
VALUES ('...', '...', '...', '...', '...', NOW())
ON CONFLICT (team_id) DO UPDATE SET
  team_alias = EXCLUDED.team_alias,
  cost_code = EXCLUDED.cost_code,
  cost_code_name = EXCLUDED.cost_code_name,
  jira_asset_id = EXCLUDED.jira_asset_id,
  updated_at = NOW();
```

### 3. Integrate cost codes into existing Grafana dashboards

We have two dashboards:
- **Team lead dashboard** — scoped to a single team via hidden `$team` variable (set via URL param `?var-team=<id>`)
- **Admin dashboard** — has a team dropdown, shows all teams

For both dashboards, join against `cost_code_mapping` where relevant:

**In overview stat panels and row titles:**
- Show the cost code alongside the team name (e.g. row title: `${team_name} (${cost_code})`)
- Add a hidden `cost_code` variable that looks up the code for the selected team:

```sql
SELECT COALESCE(cost_code, 'UNMAPPED') FROM cost_code_mapping WHERE team_id IN ($team)
```

**In the admin dashboard specifically:**
- Add cost code as a column in any team-level tables
- Group-by or filter-by cost code where it adds value

### 4. Create a finance dashboard

Build a new dashboard for the finance team. This is an org-wide rollup view — no team scoping, all teams visible, emphasising cost attribution and chargeback.

**Panels to include:**

Row 1 — Cost Code Summary (top of dashboard, full width table):
- This is the first thing finance sees — a chargeback-ready summary table
- Columns: Team, Cost Code, Spend (period total)
- Sorted by spend descending
- UNMAPPED for teams without a cost code mapping
- Query:

```sql
SELECT
  COALESCE(t.team_alias, d.team_id) AS "Team",
  COALESCE(c.cost_code, 'UNMAPPED') AS "Cost Code",
  SUM(d.spend) AS "Spend"
FROM "LiteLLM_DailyTeamSpend" d
LEFT JOIN "LiteLLM_TeamTable" t ON d.team_id = t.team_id
LEFT JOIN cost_code_mapping c ON d.team_id = c.team_id
WHERE d.date::timestamp >= $__timeFrom()
  AND d.date::timestamp <= $__timeTo()
GROUP BY t.team_alias, d.team_id, c.cost_code
ORDER BY "Spend" DESC
```

Row 2 — Overview stats:
- Total org spend (all teams, time range filtered)
- vs previous period (% change)
- Number of active teams
- Number of active users

Row 3 — Cost code breakdown:
- Stacked bar timeseries: daily spend grouped by cost code
- Pie chart: spend share by cost code
- Table: cost code, team, total spend, budget, % used — sorted by spend descending

Row 4 — Team comparison:
- Bar chart: spend by team (ranked)
- Timeseries: spend trend per team
- Table: team, cost code, spend, budget remaining, model mix (top model by spend)

Row 5 — Model economics:
- Spend by model (org-wide)
- Avg cost per 1K output tokens by model
- Model mix % over time

**Variables:**
- `datasource` — PostgreSQL datasource selector
- `cost_code` — optional filter (multi-select with "All" default), sourced from `cost_code_mapping`
- Time range picker (default last 30 days)

**Key tables and joins:**

| Table | Purpose |
|-------|---------|
| `LiteLLM_DailyTeamSpend` | Pre-aggregated daily team metrics (spend, tokens, requests) |
| `LiteLLM_DailyUserSpend` | Pre-aggregated daily user metrics |
| `LiteLLM_TeamTable` | Team metadata (team_alias, max_budget) |
| `LiteLLM_UserTable` | User metadata (user_email) |
| `LiteLLM_VerificationToken` | API keys — maps users to teams |
| `LiteLLM_SpendLogs` | Raw per-request logs (use sparingly, not pre-aggregated) |
| `cost_code_mapping` | Custom table mapping teams to Jira cost codes |

**Example join pattern:**

```sql
SELECT
  COALESCE(c.cost_code, 'UNMAPPED') AS cost_code,
  COALESCE(c.cost_code_name, t.team_alias, d.team_id) AS display_name,
  SUM(d.spend) AS spend
FROM "LiteLLM_DailyTeamSpend" d
LEFT JOIN "LiteLLM_TeamTable" t ON d.team_id = t.team_id
LEFT JOIN cost_code_mapping c ON d.team_id = c.team_id
WHERE d.date::timestamp >= $__timeFrom()
  AND d.date::timestamp <= $__timeTo()
GROUP BY c.cost_code, c.cost_code_name, t.team_alias, d.team_id
ORDER BY spend DESC
```

## Grafana 12 Gotchas

These are critical — follow these patterns exactly:

1. **Variable interpolation in PostgreSQL**: Use `column IN ($variable)`, NEVER `column = '$variable'`. The PostgreSQL backend plugin does NOT interpolate variables inside SQL string quotes.

2. **Variable query format**: Template variable queries must be plain SQL strings, NOT `{rawSql, format}` objects. Those are for panel targets only.

3. **`${var:text}` does not resolve from URL params**: If the team is set via `?var-team=<id>`, `${team:text}` won't work. Use a separate hidden lookup variable instead.

4. **`${__user.email}` does not work in PostgreSQL queries**: Cannot auto-filter by logged-in user. Use bookmarked URLs with `?var-team=<id>`.

5. **Datasource field format**: Must be `{"type": "grafana-postgresql-datasource", "uid": "${datasource}"}`, not a plain string.

6. **`includeAll: true`** with `IN ($var)` handles "All" selection automatically — Grafana expands to all values.

## Folder Structure

- **Cluster Monitoring** folder — admin only (internal dashboards)
- **LiteLLM** folder — team lead dashboard (scoped via URL), admin dashboard
- **Finance** folder — finance dashboard (new)

Finance folder should be accessible to the `finance` Grafana team + admins only.
