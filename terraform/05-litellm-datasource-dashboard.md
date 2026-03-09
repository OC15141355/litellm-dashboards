# Prompt 05 — Add LiteLLM PostgreSQL Datasource & Dashboard

**Epic:** External Access to Grafana
**Depends on:** Tickets 1-2 complete (monitoring in Terraform, Grafana externally accessible).

---

## Prompt

I need to connect Grafana to our LiteLLM PostgreSQL database and add a cost attribution dashboard. This is two parts — first the datasource, then the dashboard. Do them in order.

### Before you start

Audit the current state:
1. How are existing Grafana dashboards deployed? Check for ConfigMaps in `cattle-monitoring-system` or any other dashboard-related namespace (e.g., `cattle-dashboards`). How are they labelled?
2. Is the Grafana sidecar enabled? Check `helm get values rancher-monitoring -n cattle-monitoring-system -o yaml` for sidecar config.
3. How does this cluster's Grafana currently pick up dashboards and datasources?

Based on what you find, recommend the best approach for adding our PostgreSQL datasource and dashboard — following whatever pattern is already established, not inventing a new one.

### Part 1: PostgreSQL Datasource

Add a datasource in Terraform pointing at our LiteLLM RDS PostgreSQL instance.

**Credentials:**
- Database user: `grafana_reader` (read-only, already created on RDS)
- Password: stored in `litellm-dev` AWS Secrets Manager entry under the key `grafana_pg_secret`
- Pull it following the same pattern as other secrets in this repo

**Datasource config:**
- Name: `LiteLLM PostgreSQL`
- Type: `postgres`
- Host: the LiteLLM RDS endpoint (same one the LiteLLM module uses — check how it references it)
- SSL mode: `require`
- The password needs to be injected into the Grafana pod as an env var via `envFromSecrets`, then referenced as `$GRAFANA_PG_PASSWORD` in the datasource config

**Stop here** — show me the plan and let me verify the datasource connects before adding the dashboard.

### Part 2: Dashboard (after datasource is confirmed working)

The dashboard JSON is at `~/Documents/dashboards/litellm-postgres-dashboard.json`.

Deploy it as a ConfigMap following the same pattern as the other dashboards you found in the audit above. Put it wherever the existing dashboards live (likely `cattle-dashboards` namespace or `cattle-monitoring-system` with sidecar labels).

### Network note

Grafana connects to RDS directly — no tunnel needed. It's inside the same VPC as LiteLLM.

### What NOT to do

- Do NOT modify existing monitoring values (Prometheus, Alertmanager, etc.)
- Do NOT add a Prometheus datasource — that already exists
- Do NOT create a separate Grafana deployment
