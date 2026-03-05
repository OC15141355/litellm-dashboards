# Grafana Deployment — Work Environment

Standalone Grafana instance for LiteLLM cost attribution dashboards. Deployed via Terraform + Helm, authenticated with Keycloak SSO.

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
    → Grafana Pod (Helm chart)
      → Keycloak OIDC (authentication)
      → RDS PostgreSQL (LiteLLM spend data, read-only)
```

---

## Prerequisites

1. **Keycloak** — existing realm with user accounts
2. **RDS PostgreSQL** — LiteLLM database with spend data
3. **Terraform repo** — with existing module structure (litellm, sourcegraph as reference)
4. **DNS** — CNAME/A record for `grafana.dev.example.com` pointing to cluster ingress
5. **TLS** — cert-manager or ACM certificate for the Grafana domain

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

Connect to the LiteLLM RDS instance as admin and create a read-only role:

```sql
CREATE ROLE grafana_reader WITH LOGIN PASSWORD '<grafana_pg_password>';
GRANT CONNECT ON DATABASE <litellm_db> TO grafana_reader;
GRANT USAGE ON SCHEMA public TO grafana_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO grafana_reader;
```

This user can only SELECT — no writes, no schema changes.

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

The `$GRAFANA_PG_PASSWORD` env var is injected via `envFromSecrets` in the Helm values.

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
