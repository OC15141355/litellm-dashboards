# Grafana Deployment — Work Environment

Standalone Grafana instance for LiteLLM cost attribution dashboards. Deployed via Terraform + Helm, authenticated with Keycloak SSO.

---

## Quick Test — Use Rancher's Existing Grafana

Before deploying a standalone Grafana, test the dashboard on the existing Rancher Monitoring Grafana (`cattle-monitoring-system`). This validates the datasource connection and dashboard without any Terraform.

### Step 1: Create the `grafana_reader` role on RDS

Open your SSH tunnel to the bastion:

```bash
ssh -L 5432:db1.dev.work.com:5432 rocky@lp-devops-bastion.dev.work.com -i ~/Documents/dev.pem
```

Connect via DBeaver (localhost:5432, admin user) and run:

```sql
CREATE ROLE grafana_reader WITH LOGIN PASSWORD '<generate-secure-password>';
GRANT CONNECT ON DATABASE <litellm_db> TO grafana_reader;
GRANT USAGE ON SCHEMA public TO grafana_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO grafana_reader;
```

Save the password — you'll need it in the next step.

### Step 2: Push PostgreSQL datasource ConfigMap

Create a file `litellm-postgres-datasource.yaml`:

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
        database: <litellm_db>
        user: grafana_reader
        secureJsonData:
          password: <grafana_reader-password>
        jsonData:
          sslmode: require
          postgresVersion: 1500
```

> **Note:** For this quick test, the password is inline in the ConfigMap. This is fine for testing — the standalone deployment (below) uses Secrets Manager + env var injection instead.

```bash
kubectl apply -f litellm-postgres-datasource.yaml
```

The Grafana sidecar watches for ConfigMaps with `grafana_datasource: "1"` and auto-loads them. No pod restart needed.

### Step 3: Push dashboard ConfigMap

```bash
kubectl create configmap litellm-cost-dashboard \
  --from-file=litellm-cost-attribution.json=grafana/litellm-postgres-dashboard.json \
  -n cattle-monitoring-system

kubectl label configmap litellm-cost-dashboard \
  grafana_dashboard="1" \
  -n cattle-monitoring-system
```

### Step 4: Verify

1. Open Rancher Grafana (Cluster Explorer → Monitoring → Grafana)
2. Go to Configuration → Data Sources — verify "LiteLLM PostgreSQL" shows a green checkmark
3. Go to Dashboards → Browse — find "LiteLLM Cost Attribution"
4. Check that panels show data (Total Spend, Requests, etc.)
5. Test a team-filtered URL: append `?var-team=<team_id>` to the dashboard URL

### Cleanup

When you're done testing (or after the standalone Grafana is deployed), remove the test ConfigMaps:

```bash
kubectl delete configmap litellm-postgres-datasource -n cattle-monitoring-system
kubectl delete configmap litellm-cost-dashboard -n cattle-monitoring-system
```

This immediately removes the datasource and dashboard from Rancher's Grafana. No restart needed — the sidecar handles it.

---

## Standalone Deployment (Terraform + Keycloak SSO)

Once you've validated the dashboard works with real data, follow the steps below to deploy a dedicated Grafana instance with Keycloak SSO and proper secrets management.

---

## Why a Separate Grafana?

Rancher Monitoring includes a Grafana (`cattle-monitoring-system`), but it's tightly coupled to Rancher's Prometheus stack and not ideal for team-facing dashboards. A standalone Grafana gives us:

- Keycloak SSO (team leads log in with their existing work accounts)
- Isolated from cluster monitoring (no accidental access to infra metrics)
- Controlled access — Viewer role only, no editing
- Team-scoped cost attribution dashboards via bookmarked URLs

---

## Architecture

```
Team Lead (browser)
  → grafana.dev.example.com (Ingress)
    → Grafana Pod (Helm chart, work-devops-tools namespace)
      → Keycloak OIDC (authentication)
      → RDS PostgreSQL (LiteLLM spend data, read-only)
```

### Network Access — Why No SSH Tunnel?

You access RDS from your laptop via an SSH tunnel through the bastion (`lp-devops-bastion.dev.work.com`). That's because your laptop is **outside** the VPC.

Grafana doesn't need a tunnel. It runs as a pod **inside the same Kubernetes cluster** as LiteLLM, which already connects to RDS directly. The cluster has VPC-level network access to RDS — Grafana just uses the RDS endpoint as the datasource URL.

```
Your laptop (outside VPC)          K8s cluster (inside VPC)
  → SSH tunnel → bastion → RDS      Grafana pod → RDS (direct)
  (DBeaver, admin tasks)            (datasource, read-only)
```

The only time you use the bastion/SSH tunnel is for the one-time setup: creating the `grafana_reader` database role (step 3 below).

---

## Prerequisites

1. **Keycloak** — existing realm with user accounts
2. **RDS PostgreSQL** — LiteLLM database with spend data (accessible from cluster VPC)
3. **Terraform repo** — with existing module structure (litellm, sourcegraph as reference)
4. **DNS** — CNAME/A record for `grafana.dev.example.com` pointing to cluster ingress
5. **TLS** — cert-manager or ACM certificate for the Grafana domain
6. **Bastion access** — SSH tunnel to RDS for the one-time `grafana_reader` role creation

---

## 1. Keycloak OIDC Client Setup

Create an OIDC client in Keycloak for Grafana. This is a manual step in the Keycloak admin console (or Terraform if the Keycloak module supports it).

### Client Configuration

| Field | Value |
|-------|-------|
| Client ID | `grafana` |
| Client Protocol | `openid-connect` |
| Access Type | `confidential` |
| Root URL | `https://grafana.dev.example.com` |
| Valid Redirect URIs | `https://grafana.dev.example.com/login/generic_oauth` |
| Web Origins | `https://grafana.dev.example.com` |

### Client Scopes

Ensure the `groups` scope is included in the token (for role mapping):

1. Client Scopes → Create → Name: `groups`, Protocol: `openid-connect`
2. Add a mapper: Type `Group Membership`, Token Claim Name `groups`, Full group path `OFF`
3. Assign the `groups` scope to the `grafana` client as a default scope

### Keycloak Groups

| Keycloak Group | Grafana Role | Purpose |
|----------------|-------------|---------|
| `grafana-admins` | Admin | Platform team — can edit dashboards, manage datasources |
| (default / no group) | Viewer | Team leads — view only, filtered by bookmarked URL |

### Retrieve Client Secret

Keycloak → Clients → `grafana` → Credentials tab → copy the **Secret**. Store in AWS Secrets Manager.

---

## 2. AWS Secrets Manager

Add the Grafana secrets to Secrets Manager (new secret or extend existing `litellm-dev`):

```json
{
  "grafana_admin_password": "<generated>",
  "grafana_keycloak_client_secret": "<from-keycloak>",
  "grafana_pg_password": "<grafana_reader-password>"
}
```

The Terraform module will pull these via `data.aws_secretsmanager_secret_version` and inject into the Helm release.

---

## 3. RDS — Create Read-Only User

This is the only step that requires the bastion SSH tunnel. You need to connect to the LiteLLM RDS instance as admin and create a read-only role for Grafana.

### Open SSH tunnel

```bash
# Terminal 1 — open the tunnel (keep this running)
ssh -L 5432:db1.dev.work.com:5432 rocky@lp-devops-bastion.dev.work.com -i ~/Documents/dev.pem
```

### Create the role

Connect via DBeaver (or `psql` on `localhost:5432`) as the admin user, then run:

```sql
CREATE ROLE grafana_reader WITH LOGIN PASSWORD '<grafana_pg_password>';
GRANT CONNECT ON DATABASE <litellm_db> TO grafana_reader;
GRANT USAGE ON SCHEMA public TO grafana_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO grafana_reader;
```

This user can only SELECT — no writes, no schema changes.

### Verify (optional)

Still through DBeaver/tunnel, test the new role:

```sql
-- Connect as grafana_reader
SELECT COUNT(*) FROM "LiteLLM_DailyTeamSpend";   -- should return a number
INSERT INTO "LiteLLM_DailyTeamSpend" (team_id) VALUES ('test');  -- should FAIL (permission denied)
```

### Store the password

Add `grafana_pg_password` to AWS Secrets Manager (step 2 above). This is the same password you used in `CREATE ROLE`. After this, you won't need the bastion tunnel again — Grafana connects from inside the VPC.

---

## 4. Terraform Module

### Structure

Follow the existing module pattern (litellm/sourcegraph):

```
terraform/
└── modules/
    └── grafana/
        ├── main.tf          # Helm release + K8s secrets
        ├── variables.tf     # Input variables
        └── outputs.tf       # Dashboard URL, etc.
```

### Helm Chart

| Field | Value |
|-------|-------|
| Chart | `grafana/grafana` (Helm repo: `https://grafana.github.io/helm-charts`) |
| Version | Latest stable (check: `helm search repo grafana/grafana`) |
| Namespace | `work-devops-tools` (same as LiteLLM) |

### Key Helm Values

```yaml
replicas: 1

ingress:
  enabled: true
  ingressClassName: nginx
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
    cert-manager.io/cluster-issuer: "<cluster-issuer>"   # or use ACM
  hosts:
    - grafana.dev.example.com
  tls:
    - secretName: grafana-tls
      hosts:
        - grafana.dev.example.com

persistence:
  enabled: true
  size: 1Gi                    # Grafana DB (dashboards, preferences)

admin:
  existingSecret: grafana-secrets
  userKey: admin-user
  passwordKey: admin-password

# Keycloak OIDC
grafana.ini:
  server:
    root_url: https://grafana.dev.example.com
  auth.generic_oauth:
    enabled: true
    name: Keycloak
    allow_sign_up: true
    auto_login: false           # set true to skip Grafana login page
    client_id: grafana
    client_secret: ${KEYCLOAK_CLIENT_SECRET}
    scopes: openid email profile groups
    auth_url: https://<keycloak-url>/realms/<realm>/protocol/openid-connect/auth
    token_url: https://<keycloak-url>/realms/<realm>/protocol/openid-connect/token
    api_url: https://<keycloak-url>/realms/<realm>/protocol/openid-connect/userinfo
    role_attribute_path: contains(groups[*], 'grafana-admins') && 'Admin' || 'Viewer'
  users:
    auto_assign_org_role: Viewer
    viewers_can_edit: false

# Inject secrets as env vars (referenced in datasource provisioning)
envFromSecrets:
  - name: grafana-secrets

# Dashboard sidecar
sidecar:
  dashboards:
    enabled: true
    label: grafana_dashboard
    labelValue: "1"
    folderAnnotation: grafana_folder
  datasources:
    enabled: true
    label: grafana_datasource
    labelValue: "1"
```

### K8s Secret (created by Terraform)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: grafana-secrets
  namespace: work-devops-tools
type: Opaque
stringData:
  admin-user: admin
  admin-password: <from-secrets-manager>
  KEYCLOAK_CLIENT_SECRET: <from-secrets-manager>
  GRAFANA_PG_PASSWORD: <from-secrets-manager>
```

Created via `kubernetes_secret_v1` resource in Terraform, values sourced from `data.aws_secretsmanager_secret_version`.

---

## 5. PostgreSQL Datasource (Sidecar ConfigMap)

The datasource URL is the **RDS endpoint** — NOT `localhost` or a tunnel. Grafana runs inside the cluster VPC and connects to RDS directly. You can find the endpoint via:

```bash
aws rds describe-db-instances --query 'DBInstances[*].[DBInstanceIdentifier,Endpoint.Address]' --output table
```

Or grab the host portion from the `DATABASE_URL` in the LiteLLM Secrets Manager entry — it's the same RDS instance.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasource-litellm-postgres
  namespace: work-devops-tools
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
          password: $GRAFANA_PG_PASSWORD
        jsonData:
          sslmode: require
          postgresVersion: 1500
```

The `$GRAFANA_PG_PASSWORD` env var is injected via `envFromSecrets` in the Helm values (see step 4). Grafana substitutes it at startup.

Deploy this ConfigMap via Terraform (`kubernetes_config_map_v1`) or include in the Helm values under `datasources`.

---

## 6. Dashboard Provisioning

### Option A: ConfigMap Sidecar (Recommended)

```bash
kubectl create configmap grafana-dashboard-litellm-cost \
  --from-file=litellm-cost-attribution.json=grafana/litellm-postgres-dashboard.json \
  -n work-devops-tools

kubectl label configmap grafana-dashboard-litellm-cost \
  grafana_dashboard="1" \
  -n work-devops-tools
```

Or create via Terraform `kubernetes_config_map_v1` resource with the dashboard JSON.

### Option B: Grafana UI Import

Dashboards → Import → upload `grafana/litellm-postgres-dashboard.json` → select "LiteLLM PostgreSQL" datasource.

---

## 7. Team-Scoped Access

The dashboard has no visible team dropdown (hidden variable). Team leads access their team's view via bookmarked URLs:

```
https://grafana.dev.example.com/d/litellm-cost-attribution?var-team=<team_id>
```

### Getting Team IDs

```bash
curl -s "$LITELLM_URL/team/list" -H "Authorization: Bearer $MASTER_KEY" | \
  jq -r '.[] | "\(.team_id)\t\(.team_alias)"'
```

### Distributing URLs

Include in the onboard script output:
```bash
echo "Dashboard: https://grafana.dev.example.com/d/litellm-cost-attribution?var-team=${TEAM_ID}"
```

Pin team-specific URLs in each team's Slack channel.

### Access Model

| Who | What They See | How |
|-----|---------------|-----|
| Platform team | All teams (no `var-team` param) | Direct URL, Grafana Admin role via Keycloak |
| Team lead | Their team only | Bookmarked URL with `var-team=<id>` |
| Developer | Their team's view | Same bookmarked URL from team lead |

Team leads can't switch teams because the dropdown is hidden. If they manually edit the URL, they'd need another team's UUID — soft isolation, acceptable for internal use.

---

## Grafana 12 Gotchas

These apply if deploying Grafana 12.x (current latest):

| Gotcha | Detail |
|--------|--------|
| **Variable interpolation in SQL strings** | PostgreSQL plugin does NOT interpolate `'$var'` inside quotes. All queries must use `column IN ($team)`, never `column = '$team'`. Grafana handles quoting automatically. |
| **`${__user.email}` broken** | Built-in user variables are NOT interpolated in PostgreSQL queries. Cannot auto-filter by logged-in user. Use bookmarked URLs instead. |
| **Variable query format** | Template variable queries must be plain SQL strings, NOT `{rawSql, format}` objects (that format is for panel targets only). |
| **`${var:text}` with URL params** | `${team:text}` does not resolve display names when the variable is set via URL parameter. Use a separate hidden lookup variable (`team_name`) that queries the alias. |

---

## Verification Checklist

- [ ] Grafana pod is running in `work-devops-tools`
- [ ] Ingress resolves — `https://grafana.dev.example.com` loads login page
- [ ] Keycloak SSO login works — redirects to Keycloak, returns to Grafana
- [ ] `grafana-admins` group members get Admin role
- [ ] Default users get Viewer role
- [ ] "LiteLLM PostgreSQL" datasource shows green checkmark
- [ ] Dashboard appears under Dashboards → Browse
- [ ] `?var-team=<team_id>` filters correctly, row headers show team alias
- [ ] Team leads cannot see the team dropdown (hidden)
- [ ] Spend numbers match LiteLLM UI

---

## Terraform Variables (for `terraform.tfvars`)

```hcl
# Grafana
grafana_chart_version    = "8.x.x"           # check latest
grafana_domain           = "grafana.dev.example.com"
grafana_namespace        = "work-devops-tools"
keycloak_url             = "https://keycloak.example.com"
keycloak_realm           = "your-realm"
grafana_keycloak_client  = "grafana"
litellm_rds_endpoint     = "<rds-endpoint>"
litellm_db_name          = "<db-name>"
```
