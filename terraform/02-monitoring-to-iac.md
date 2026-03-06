# Prompt 02 — Ticket 1: Deploy Kubernetes Monitoring as Code

**Epic:** External Access to Grafana
**Ticket:** Deploy kubernetes monitoring helm as code
**Description:** Current chart is deployed via the Rancher UI. This ticket will move to a code-based approach so it follows existing helm deployment processes.

Paste this into Claude Code after you've run `01-gather-context.md` and understand the repo structure.

---

## Prompt

I need to move our existing Rancher Monitoring Helm deployment from the Rancher UI into Terraform, following the same patterns as our other modules (you should have already explored the repo structure — if not, explore it first before proceeding).

### Current state

- Rancher Monitoring is deployed via the Rancher UI (Cluster Explorer → Apps → Monitoring)
- It runs in the `cattle-monitoring-system` namespace
- It deploys `rancher-monitoring` which is Rancher's fork of `kube-prometheus-stack`
- Chart repo: Rancher's built-in chart repo (bundled with Rancher)
- Current Helm values were set through the Rancher UI — we need to capture them first
- This deployment includes Prometheus, Grafana, Alertmanager, and related components

### Step 1: Capture current Helm values

Before writing any Terraform, I need to know what's currently deployed. Run these commands and show me the full output:

```bash
# Get the current chart version and status
helm list -n cattle-monitoring-system

# Get the current user-configured values (critical — these are what the Rancher UI set)
helm get values rancher-monitoring -n cattle-monitoring-system -o yaml

# Get the chart metadata (tells us chart repo source)
helm get metadata rancher-monitoring -n cattle-monitoring-system
```

Show me the full output of all three commands. Do NOT proceed to write the module until I've reviewed these values — I may need to adjust them.

### Step 2: Create the Terraform module

Once I've confirmed the values, create the monitoring module following the same patterns as the other modules in this repo:

- `main.tf` — Helm release resource for `rancher-monitoring`
- `variables.tf` — Input variables (chart version, namespace, values overrides)
- `outputs.tf` — Useful outputs (namespace, release name)

**Important considerations:**

1. **Chart source**: Rancher bundles its monitoring chart. Check how Rancher exposes the chart repo — it may be an in-cluster chart repo URL like `https://charts.rancher.io` or an OCI reference. The `helm get metadata` output will tell us.

2. **Existing state**: We're importing an existing deployment, NOT creating a new one. The Terraform module must match the current state exactly so that `terraform plan` shows no changes on first run. After import, we iterate.

3. **Values preservation**: The `helm get values` output must be captured as the baseline. Put these as the default values in the module — either as a `values` YAML block or as individual `set` blocks, matching whichever pattern the other modules use.

4. **Namespace**: Keep `cattle-monitoring-system` — do NOT move it. Rancher expects monitoring in this namespace.

5. **CRDs**: `kube-prometheus-stack` includes CRDs (PrometheusRule, ServiceMonitor, etc.). The Rancher chart may handle CRD installation differently. Check if there's a `crds.enabled` or `prometheusOperator.admissionWebhooks` setting — these can cause issues during Terraform apply.

### Step 3: Import plan

After writing the module, give me the exact commands to:
1. Add the module call in the environment config
2. Run `terraform import` to import the existing Helm release into state
3. Run `terraform plan` to verify zero diff

### What NOT to do

- Do NOT change any values from what's currently deployed — this is a lift-and-shift only
- Do NOT add ingress, SSO, or any new features — those are separate tickets
- Do NOT remove anything from the Rancher UI deployment — we import first, then Terraform owns it
- Do NOT create a new Helm release — we are importing the existing one

### Output

Give me:
1. The current deployed values (from Step 1)
2. The module files (main.tf, variables.tf, outputs.tf)
3. The environment config addition (module call block)
4. The import commands
5. Any risks or gotchas specific to importing Rancher's monitoring chart
