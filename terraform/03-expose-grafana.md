# Prompt 03 — Ticket 2: Expose Grafana for External Access

**Epic:** External Access to Grafana
**Ticket:** Expose Grafana for external access
**Description:** Configure external access to Grafana via the kube-prometheus-stack Helm chart. This eliminates the need to proxy access through the cluster and allows fine-grained permissions.

Paste this into Claude Code after ticket 1 is complete (monitoring Helm release is managed by Terraform).

---

## Prompt

We've codified our Rancher Monitoring deployment into Terraform (ticket 1 is done). Now I need to expose Grafana for external access via ingress so team leads can access dashboards without proxying through Rancher.

### Current state

- Monitoring is deployed via our Terraform module (kube-prometheus-stack / rancher-monitoring)
- Grafana is currently only accessible through Rancher's built-in proxy (Cluster Explorer → Monitoring → Grafana)
- No ingress exists for Grafana yet

### What to do

Add Grafana ingress configuration to the monitoring module's Helm values. This is a value change on the existing Helm release — NOT a new deployment.

Refer to the [kube-prometheus-stack Helm chart documentation](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) for the correct value paths. In the Rancher fork, Grafana values are typically under the `grafana:` key.

### Required Helm values

Add these to the monitoring module's values:

```yaml
grafana:
  ingress:
    enabled: true
    ingressClassName: nginx          # or whatever ingress class the cluster uses
    annotations:
      nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
      # Add cert-manager annotation if using cert-manager for TLS:
      # cert-manager.io/cluster-issuer: "<cluster-issuer>"
    hosts:
      - <grafana-domain>             # e.g., grafana.dev.example.com
    tls:
      - secretName: grafana-tls
        hosts:
          - <grafana-domain>
```

### Before applying

1. Check how other modules in this repo handle ingress (litellm, sourcegraph) — match the pattern for TLS, annotations, and ingress class
2. Check what ingress controller is running in the cluster: `kubectl get ingressclass`
3. Check if cert-manager is available: `kubectl get clusterissuer`
4. Verify the domain/DNS situation — will we need to create a DNS record?

### Variables

Add a variable for the Grafana domain so it can differ between dev and prod:

```hcl
variable "grafana_domain" {
  type        = string
  description = "Domain for external Grafana access"
}
```

### What NOT to do

- Do NOT deploy a separate/standalone Grafana — we're exposing the existing one
- Do NOT add authentication/SSO config yet — that's ticket 3
- Do NOT change any existing monitoring values — only add the ingress block

### Verification

After `terraform apply`:
1. `kubectl get ingress -n cattle-monitoring-system` — should show the new Grafana ingress
2. `curl -I https://<grafana-domain>` — should return 200 (or 302 redirect to login)
3. Open in browser — should show Grafana login page
4. Default admin credentials should still work (check `helm get values` for admin password config)

### Output

Give me:
1. The updated Helm values diff (what's being added)
2. Any new variables needed
3. The terraform plan output showing the change
4. DNS record details if needed
5. Verification steps with expected output
