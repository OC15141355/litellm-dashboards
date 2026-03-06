# Prompt 04 — Ticket 3: Configure Grafana SSO

**Epic:** External Access to Grafana
**Ticket:** Configure Grafana SSO
**Context:** Keycloak OIDC integration for Grafana authentication.

Paste this into Claude Code after ticket 2 is complete (Grafana is externally accessible via ingress).

---

## Prompt

Grafana is now externally accessible (ticket 2 done). I need to add Keycloak OIDC SSO so team leads authenticate with their existing work accounts instead of sharing the Grafana admin password.

### Current state

- Grafana is deployed as part of kube-prometheus-stack via our Terraform module
- It's accessible externally via ingress at `<grafana-domain>`
- Authentication is currently default admin/password
- We have Keycloak running with a realm that has our team members

### Prerequisites (manual steps before Terraform)

These need to be done in the Keycloak admin console first:

1. **Create OIDC client** in your Keycloak realm:
   - Client ID: `grafana`
   - Client Protocol: `openid-connect`
   - Access Type: `confidential`
   - Valid Redirect URIs: `https://<grafana-domain>/login/generic_oauth`
   - Web Origins: `https://<grafana-domain>`

2. **Create groups scope** (for role mapping):
   - Client Scopes → Create → Name: `groups`, Protocol: `openid-connect`
   - Add mapper: Type `Group Membership`, Token Claim Name `groups`, Full group path `OFF`
   - Assign the `groups` scope to the `grafana` client as a default scope

3. **Create Keycloak group** for admin access:
   - Group name: `grafana-admins`
   - Add platform team members to this group
   - Everyone else gets Viewer role by default

4. **Get client secret**:
   - Keycloak → Clients → `grafana` → Credentials tab → copy the Secret

5. **Store client secret** in AWS Secrets Manager (follow the same pattern as other secrets in this repo)

### Helm values to add

Add Keycloak OIDC configuration to the monitoring module's Grafana values:

```yaml
grafana:
  # Inject the Keycloak client secret as an env var
  envFromSecrets:
    - name: grafana-keycloak-secret    # K8s secret containing the client secret

  grafana.ini:
    server:
      root_url: https://<grafana-domain>
    auth.generic_oauth:
      enabled: true
      name: Keycloak
      allow_sign_up: true
      auto_login: false                 # set true to skip Grafana login page entirely
      client_id: grafana
      client_secret: $__env{KEYCLOAK_CLIENT_SECRET}    # references the env var
      scopes: openid email profile groups
      auth_url: https://<keycloak-url>/realms/<realm>/protocol/openid-connect/auth
      token_url: https://<keycloak-url>/realms/<realm>/protocol/openid-connect/token
      api_url: https://<keycloak-url>/realms/<realm>/protocol/openid-connect/userinfo
      role_attribute_path: contains(groups[*], 'grafana-admins') && 'Admin' || 'Viewer'
    users:
      auto_assign_org_role: Viewer
      viewers_can_edit: false
```

> **Note on client secret injection:** The `$__env{KEYCLOAK_CLIENT_SECRET}` syntax is Grafana's native env var expansion for `grafana.ini`. The env var is injected via `envFromSecrets`. Check how the other modules in this repo handle similar secret injection — if they use a different pattern (e.g., `existingSecret`, `envFrom`, `set_sensitive`), match that instead.

### Terraform resources

You'll likely need to create a K8s secret for the Keycloak client secret:

```hcl
resource "kubernetes_secret_v1" "grafana_keycloak" {
  metadata {
    name      = "grafana-keycloak-secret"
    namespace = var.namespace    # cattle-monitoring-system
  }
  data = {
    KEYCLOAK_CLIENT_SECRET = <from-secrets-manager>
  }
}
```

Follow the same secrets pattern as the other modules in this repo for pulling from AWS Secrets Manager.

### Variables

```hcl
variable "keycloak_url" {
  type        = string
  description = "Keycloak server URL"
}

variable "keycloak_realm" {
  type        = string
  description = "Keycloak realm name"
}

variable "keycloak_client_id" {
  type        = string
  default     = "grafana"
  description = "Keycloak OIDC client ID for Grafana"
}
```

### Role mapping

The `role_attribute_path` uses JMESPath to map Keycloak groups to Grafana roles:

| Keycloak Group | Grafana Role | Access |
|----------------|-------------|--------|
| `grafana-admins` | Admin | Full access — edit dashboards, manage datasources |
| (no group / any other group) | Viewer | View only — can see dashboards but not edit |

### What NOT to do

- Do NOT disable the admin account — keep it as a break-glass login
- Do NOT set `auto_login: true` initially — test SSO with both login options first
- Do NOT change any monitoring/Prometheus values — only add the auth block

### Verification

After `terraform apply`:
1. Open `https://<grafana-domain>` — should show login page with "Sign in with Keycloak" button
2. Click "Sign in with Keycloak" — should redirect to Keycloak login
3. Log in with a Keycloak user — should redirect back to Grafana with Viewer role
4. Log in with a `grafana-admins` group member — should get Admin role
5. Check user list in Grafana (Admin → Users) — SSO users should appear after first login
6. Admin account (admin/password) should still work as fallback

### Output

Give me:
1. The updated Helm values diff
2. New Terraform resources (K8s secret for Keycloak)
3. New variables
4. The terraform plan output
5. Any gotchas with Rancher's Grafana fork and OIDC (some Rancher versions override auth settings)
