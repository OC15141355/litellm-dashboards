# Cost Attribution Dashboard — Work Deployment Guide

Assumes Grafana is running with Keycloak SSO and teams already exist in LiteLLM.

---

## 1. Create Read-Only DB User on RDS

```sql
-- Connect to LiteLLM database as admin
CREATE ROLE grafana_reader WITH LOGIN PASSWORD '<generate-secure-password>';
GRANT CONNECT ON DATABASE <litellm_db> TO grafana_reader;
GRANT USAGE ON SCHEMA public TO grafana_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO grafana_reader;
```

## 2. Add PostgreSQL Datasource to Grafana

### Option A: Via Grafana UI

Configuration → Data Sources → Add → PostgreSQL:

| Field | Value |
|-------|-------|
| Name | `LiteLLM PostgreSQL` |
| Host | `<rds-endpoint>:5432` |
| Database | `<litellm_db>` |
| User | `grafana_reader` |
| Password | (from step 1) |
| TLS/SSL | `require` |
| Version | 15+ |

Click **Save & test** — should show green.

### Option B: Via ConfigMap (sidecar)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: litellm-postgres-datasource
  namespace: <grafana-namespace>
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
        database: <litellm_db>
        user: grafana_reader
        secureJsonData:
          password: <password>
        jsonData:
          sslmode: require
          postgresVersion: 1500
```

## 3. Import Dashboard

### Option A: Grafana UI

Dashboards → Import → Upload `grafana/litellm-postgres-dashboard.json` → Select the PostgreSQL datasource → Import.

### Option B: ConfigMap (sidecar)

```bash
kubectl create configmap litellm-cost-dashboard \
  --from-file=litellm-cost-attribution.json=grafana/litellm-postgres-dashboard.json \
  -n <grafana-namespace>

kubectl label configmap litellm-cost-dashboard grafana_dashboard="1" \
  -n <grafana-namespace>
```

## 4. Set User Budgets

The dashboard shows per-user budget tracking. Set budgets via API:

```bash
# Set budget for a user
curl -X POST "$LITELLM_URL/user/update" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"user_id": "user-alice", "max_budget": 100}'
```

Or add `max_budget` during key creation in the onboard script.

## 5. Ensure team_alias Matches Org Structure

The dashboard dropdown shows `team_alias` values. Make sure they match what finance/charge codes expect:

```bash
# Check current teams
curl -s "$LITELLM_URL/team/list" -H "Authorization: Bearer $MASTER_KEY" | \
  jq '.[] | {team_id, team_alias, max_budget}'

# Update a team alias if needed
curl -X POST "$LITELLM_URL/team/update" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"team_id": "<id>", "team_alias": "Platform Engineering"}'
```

## 6. Generate Team-Specific URLs

Each team lead gets a bookmarked URL pre-filtered to their team:

```
https://grafana.example.com/d/litellm-cost-attribution?var-team=<team_id>
```

Add this to the onboard script output so every new team automatically gets their dashboard link.

## 7. Keycloak → Grafana User Access

With Keycloak SSO on Grafana, team leads already have Grafana accounts. Assign Viewer role:

| Keycloak Group | Grafana Role | Dashboard Access |
|----------------|-------------|------------------|
| `grafana-admins` | Admin | All teams, can edit |
| `grafana-viewers` (or default) | Viewer | Via bookmarked team URL |

No per-team Grafana config needed — the URL handles team filtering.

---

## Verification Checklist

- [ ] `grafana_reader` can connect and query: `SELECT COUNT(*) FROM "LiteLLM_DailyTeamSpend"`
- [ ] Datasource shows green in Grafana
- [ ] Dashboard loads with "All" selected — overview stats show data
- [ ] Select a specific team — panels filter correctly
- [ ] User Spend & Budget table shows budget/remaining/usage gauge
- [ ] Team lead's bookmarked URL lands on their team's view

## Gotchas

- **Grafana 12 variable interpolation**: All queries use `column IN ($team)`, not `'$team'`. Single-quoted variables are not interpolated by the PostgreSQL backend plugin.
- **`${__user.email}` does NOT work**: Cannot auto-filter by logged-in user in PostgreSQL queries. Use bookmarked URLs instead.
- **Daily tables lag**: `LiteLLM_DailyTeamSpend` is aggregated by LiteLLM periodically. Brand new requests may not appear for a few minutes.
- **Budget resets**: `max_budget` in LiteLLM is lifetime by default. Set `budget_duration: "30d"` on teams/keys for monthly resets.
