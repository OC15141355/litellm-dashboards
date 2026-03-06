# Prompt 05 — Add LiteLLM PostgreSQL Datasource & Dashboard

**Epic:** External Access to Grafana
**Depends on:** Tickets 1-2 complete (monitoring in Terraform, Grafana externally accessible). Ticket 3 (SSO) is nice-to-have but not required.

---

## Prompt

Grafana is deployed via Terraform and accessible externally. I now need to add a PostgreSQL datasource pointing at our LiteLLM database and import a cost attribution dashboard.

### Context

- LiteLLM runs in this cluster and stores spend/usage data in an RDS PostgreSQL instance
- A read-only database user `grafana_reader` has already been created on the RDS instance
- The dashboard JSON is pre-built and tested — it's in this same repo at `grafana/litellm-postgres-dashboard.json`
- Grafana's sidecar should be watching for ConfigMaps with `grafana_datasource: "1"` and `grafana_dashboard: "1"` labels — but verify this first (see pre-check below)

### Pre-check: Verify sidecar is enabled

Before adding ConfigMaps, confirm the Grafana sidecar is enabled in the current Helm values:

```bash
helm get values rancher-monitoring -n cattle-monitoring-system -o yaml | grep -A 10 sidecar
```

If the sidecar isn't enabled for dashboards or datasources, you'll need to add these to the monitoring Helm values:

```yaml
grafana:
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

If it's already enabled (likely — Rancher Monitoring enables it by default), skip this and just add the ConfigMaps.

### What to add to the monitoring Terraform module

**1. K8s Secret for the database password:**

```hcl
resource "kubernetes_secret_v1" "grafana_postgres" {
  metadata {
    name      = "grafana-postgres-secret"
    namespace = var.namespace    # cattle-monitoring-system
  }
  data = {
    GRAFANA_PG_PASSWORD = <from-secrets-manager>
  }
}
```

Pull the password from AWS Secrets Manager following the same pattern as other secrets in this repo.

**2. Inject the secret as an env var in Grafana:**

Add to the monitoring Helm values:

```yaml
grafana:
  envFromSecrets:
    - name: grafana-postgres-secret
```

> If ticket 3 (Keycloak SSO) is already done, there may already be an `envFromSecrets` entry for the Keycloak secret. Merge them — don't overwrite:
> ```yaml
> grafana:
>   envFromSecrets:
>     - name: grafana-keycloak-secret
>     - name: grafana-postgres-secret
> ```

**3. PostgreSQL datasource ConfigMap:**

```hcl
resource "kubernetes_config_map_v1" "grafana_litellm_datasource" {
  metadata {
    name      = "grafana-datasource-litellm-postgres"
    namespace = var.namespace
    labels = {
      grafana_datasource = "1"
    }
  }
  data = {
    "litellm-postgres.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name   = "LiteLLM PostgreSQL"
        type   = "postgres"
        access = "proxy"
        url    = "${var.litellm_rds_endpoint}:5432"
        database = var.litellm_db_name
        user   = "grafana_reader"
        secureJsonData = {
          password = "$GRAFANA_PG_PASSWORD"
        }
        jsonData = {
          sslmode         = "require"
          postgresVersion = 1500
        }
      }]
    })
  }
}
```

The `$GRAFANA_PG_PASSWORD` is expanded by Grafana at startup from the env var injected via `envFromSecrets`.

**4. Dashboard ConfigMap:**

```hcl
resource "kubernetes_config_map_v1" "grafana_litellm_dashboard" {
  metadata {
    name      = "grafana-dashboard-litellm-cost"
    namespace = var.namespace
    labels = {
      grafana_dashboard = "1"
    }
  }
  data = {
    "litellm-cost-attribution.json" = file("${path.module}/dashboards/litellm-cost-attribution.json")
  }
}
```

Copy the dashboard JSON into the module directory:

```bash
mkdir -p modules/monitoring/dashboards
cp ~/Documents/dashboards/litellm-postgres-dashboard.json modules/monitoring/dashboards/litellm-cost-attribution.json
```

### Variables

```hcl
variable "litellm_rds_endpoint" {
  type        = string
  description = "RDS endpoint for LiteLLM database (without port)"
}

variable "litellm_db_name" {
  type        = string
  description = "LiteLLM database name"
}
```

### Network note

Grafana runs inside the cluster VPC. It connects to RDS directly — no SSH tunnel or bastion needed. The RDS endpoint is the same one LiteLLM uses. You can find it via:

```bash
aws rds describe-db-instances --query 'DBInstances[*].[DBInstanceIdentifier,Endpoint.Address]' --output table
```

Or extract the host from the `DATABASE_URL` in the LiteLLM Secrets Manager entry.

### Grafana 12 gotchas

The dashboard JSON is already built to handle these, but be aware:

- PostgreSQL plugin does NOT interpolate variables inside SQL string quotes — all queries use `column IN ($variable)` pattern
- Template variable queries must be plain SQL strings, NOT `{rawSql, format}` objects
- `${__user.email}` does NOT work in PostgreSQL queries — team filtering is done via bookmarked URLs (`?var-team=<team_id>`)

### What NOT to do

- Do NOT add a Prometheus datasource — that already exists from the monitoring stack
- Do NOT modify any existing monitoring values (Prometheus, Alertmanager, etc.)
- Do NOT create a separate Grafana deployment — this adds to the existing one

### Verification

After `terraform apply`:
1. Open Grafana → Configuration → Data Sources → "LiteLLM PostgreSQL" should show green checkmark
2. Dashboards → Browse → "LiteLLM Cost Attribution" should appear
3. Dashboard should show data (Total Spend, Requests, Tokens, etc.)
4. Test team filtering: append `?var-team=<team_id>` to the dashboard URL

### Output

Give me:
1. The new Terraform resources (secret, ConfigMaps)
2. Helm values diff (envFromSecrets addition)
3. New variables
4. The terraform plan output
5. Verification that the datasource connects successfully
