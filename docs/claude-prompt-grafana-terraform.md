# Claude Prompt — Grafana Terraform Module

Copy the prompt below and give it to Claude in the work Terraform repo.

---

## Prompt

I need you to create a Terraform module for deploying a standalone Grafana instance. Look at the existing modules in `terraform/modules/` (especially `litellm` and `sourcegraph`) for the structure and patterns we follow — match those conventions exactly.

### What to deploy

A standalone Grafana instance via the `grafana/grafana` Helm chart (`https://grafana.github.io/helm-charts`), deployed to the `work-devops-tools` namespace (same as LiteLLM).

### Module structure

Create `terraform/modules/grafana/` with:
- `main.tf` — Helm release + K8s secret + K8s ConfigMaps (datasource + dashboard)
- `variables.tf` — all input variables
- `outputs.tf` — Grafana URL

### Secrets pattern

Follow the same pattern as the LiteLLM module for pulling secrets from AWS Secrets Manager. The Grafana module needs these secrets:
- `grafana_admin_password` — Grafana admin password
- `grafana_keycloak_client_secret` — OIDC client secret from Keycloak
- `grafana_pg_password` — password for the `grafana_reader` PostgreSQL role

Create a `kubernetes_secret_v1` resource named `grafana-secrets` in the deployment namespace containing:
- `admin-user`: `admin`
- `admin-password`: from Secrets Manager
- `KEYCLOAK_CLIENT_SECRET`: from Secrets Manager
- `GRAFANA_PG_PASSWORD`: from Secrets Manager

### Helm values

Set these Helm values in the release:

**Ingress:**
- `ingress.enabled: true`
- `ingress.ingressClassName: nginx`
- Annotation: `nginx.ingress.kubernetes.io/proxy-read-timeout: "300"`
- TLS via cert-manager (match how litellm/sourcegraph do it)
- Host from variable

**Auth — Keycloak OIDC:**
```yaml
grafana.ini:
  server:
    root_url: https://<grafana_domain>
  auth.generic_oauth:
    enabled: true
    name: Keycloak
    allow_sign_up: true
    auto_login: false
    client_id: grafana
    client_secret: ${KEYCLOAK_CLIENT_SECRET}
    scopes: openid email profile groups
    auth_url: https://<keycloak_url>/realms/<realm>/protocol/openid-connect/auth
    token_url: https://<keycloak_url>/realms/<realm>/protocol/openid-connect/token
    api_url: https://<keycloak_url>/realms/<realm>/protocol/openid-connect/userinfo
    role_attribute_path: contains(groups[*], 'grafana-admins') && 'Admin' || 'Viewer'
  users:
    auto_assign_org_role: Viewer
    viewers_can_edit: false
```

The `${KEYCLOAK_CLIENT_SECRET}` is an env var injected via `envFromSecrets` referencing the `grafana-secrets` K8s secret.

**Secret injection:**
```yaml
admin:
  existingSecret: grafana-secrets
  userKey: admin-user
  passwordKey: admin-password
envFromSecrets:
  - name: grafana-secrets
```

**Persistence:**
```yaml
persistence:
  enabled: true
  size: 1Gi
```

**Sidecar:**
```yaml
sidecar:
  dashboards:
    enabled: true
    label: grafana_dashboard
    labelValue: "1"
  datasources:
    enabled: true
    label: grafana_datasource
    labelValue: "1"
```

### ConfigMaps (in Terraform)

Create two `kubernetes_config_map_v1` resources:

**1. PostgreSQL datasource** (`grafana-datasource-litellm-postgres`):
- Label: `grafana_datasource: "1"`
- Content:
```yaml
apiVersion: 1
datasources:
  - name: LiteLLM PostgreSQL
    type: postgres
    access: proxy
    url: <rds_endpoint>:5432
    database: <db_name>
    user: grafana_reader
    secureJsonData:
      password: $GRAFANA_PG_PASSWORD
    jsonData:
      sslmode: require
      postgresVersion: 1500
```
The `$GRAFANA_PG_PASSWORD` references the env var injected via `envFromSecrets`.

**2. Dashboard** (`grafana-dashboard-litellm-cost`):
- Label: `grafana_dashboard: "1"`
- Content: the dashboard JSON from `grafana/litellm-postgres-dashboard.json` in the litellm-dashboards repo

For the dashboard JSON, either:
- Use `file()` to load it from a local path if the JSON is copied into the Terraform repo
- Or inline it as a variable (less ideal given the size)

### Variables needed

```hcl
variable "grafana_chart_version" { type = string }
variable "grafana_domain" { type = string }
variable "namespace" { type = string, default = "work-devops-tools" }
variable "keycloak_url" { type = string }
variable "keycloak_realm" { type = string }
variable "keycloak_client_id" { type = string, default = "grafana" }
variable "litellm_rds_endpoint" { type = string }
variable "litellm_db_name" { type = string }
variable "secrets_manager_secret_id" { type = string }  # or however litellm module does it
```

### Wire it up

Add the module call in the appropriate environment file (e.g., `environments/dev/main.tf`) following the same pattern as the litellm module. Pass the variables from `terraform.tfvars`.

### Important notes

- Do NOT add a Prometheus datasource — this Grafana is only for PostgreSQL-backed cost dashboards
- The dashboard JSON has a `datasource` template variable that auto-selects any PostgreSQL datasource, so it will pick up "LiteLLM PostgreSQL" automatically
- Grafana version 12.x has a known issue where PostgreSQL variable queries must be plain SQL strings, not `{rawSql, format}` objects — the dashboard JSON already handles this correctly
- `role_attribute_path` in the OIDC config maps Keycloak groups to Grafana roles using JMESPath — `grafana-admins` group → Admin role, everyone else → Viewer
