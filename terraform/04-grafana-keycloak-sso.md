# Prompt 04 — Ticket 3: Configure Grafana SSO

**Epic:** External Access to Grafana
**Ticket:** Configure Grafana SSO
**Context:** Keycloak OIDC integration for standalone Grafana authentication.

Paste this into Claude Code — Keycloak client is already configured.

---

## Prompt

I need to add Keycloak OIDC SSO to our standalone Grafana deployment so team leads authenticate with their existing work accounts instead of sharing the admin password.

### Current state

- Grafana is deployed as a standalone Terraform module (NOT Rancher's kube-prometheus-stack Grafana)
- It's accessible externally via ingress
- Authentication is currently default admin + auto-generated K8s secret password
- Helm values are in `values.yaml.tftpl` (Terraform template file)
- Sidecar is configured and working

### Keycloak setup (already done)

These are already configured in Keycloak — do NOT recreate them:

1. **OIDC client `grafana`** exists with:
   - Client Protocol: `openid-connect`
   - Access Type: `confidential`
   - Valid Redirect URIs and Web Origins are set
   - Group Membership mapper configured (token claim `groups`, full path OFF, added to ID token + userinfo)

2. **Existing Keycloak groups** (use these, don't create new ones):
   - `kc_work_admin` → should map to Grafana **Admin**
   - `kc_work_corp_users` → Grafana **Viewer**
   - `kc_work_ext_users` → Grafana **Viewer**
   - `kc_work_read-only` → Grafana **Viewer**

3. **Client secret** needs to be stored in AWS Secrets Manager and injected into Grafana

### What to do

#### 1. Store the Keycloak client secret

- Add the Grafana client secret to AWS Secrets Manager (follow the same pattern as other secrets in this repo — check how the LiteLLM or other modules handle secrets)
- Create a Kubernetes secret that Grafana can reference via `envFromSecrets`

#### 2. Add SSO config to `values.yaml.tftpl`

Since this is standalone Grafana (not a sub-chart), values go at the **top level** — no `grafana:` wrapper:

```yaml
envFromSecrets:
  - name: grafana-keycloak-secret

grafana.ini:
  server:
    root_url: https://<grafana-domain>
  auth.generic_oauth:
    enabled: true
    name: Keycloak
    allow_sign_up: true
    auto_login: false
    client_id: grafana
    client_secret: $__env{KEYCLOAK_CLIENT_SECRET}
    scopes: openid email profile groups
    auth_url: https://<keycloak-url>/realms/<realm>/protocol/openid-connect/auth
    token_url: https://<keycloak-url>/realms/<realm>/protocol/openid-connect/token
    api_url: https://<keycloak-url>/realms/<realm>/protocol/openid-connect/userinfo
    role_attribute_path: contains(groups[*], 'kc_work_admin') && 'Admin' || 'Viewer'
  users:
    auto_assign_org_role: Viewer
    viewers_can_edit: false
```

> **Note:** `$__env{KEYCLOAK_CLIENT_SECRET}` is Grafana's native env var expansion for `grafana.ini` — NOT Terraform interpolation. The env var is injected via `envFromSecrets`. Check how other modules in this repo handle secret injection and match that pattern.

> **Note:** Since this is a `.tftpl` file, any `${...}` Terraform interpolation syntax must not conflict with Grafana's `$__env{...}` syntax. The `$__env` prefix is NOT Terraform interpolation — make sure it passes through as a literal string. You may need to escape it as `$$__env{...}` depending on how the template is processed.

#### 3. Add Terraform variables

```hcl
variable "keycloak_url" {
  type        = string
  description = "Keycloak server URL (e.g., https://keycloak.example.com)"
}

variable "keycloak_realm" {
  type        = string
  description = "Keycloak realm name"
}
```

Populate these in the environment tfvars file.

#### 4. Create K8s secret resource

```hcl
resource "kubernetes_secret_v1" "grafana_keycloak" {
  metadata {
    name      = "grafana-keycloak-secret"
    namespace = var.namespace
  }
  data = {
    KEYCLOAK_CLIENT_SECRET = <from-secrets-manager>
  }
}
```

Follow the same secrets pattern as the other modules.

### Role mapping

The `role_attribute_path` uses JMESPath to map Keycloak groups to Grafana roles:

| Keycloak Group | Grafana Role | Access |
|----------------|-------------|--------|
| `kc_work_admin` | Admin | Full access — edit dashboards, manage datasources |
| All others | Viewer | View only — can see dashboards but not edit |

### What NOT to do

- Do NOT disable the admin account — keep it as a break-glass login
- Do NOT set `auto_login: true` initially — test SSO with both login options first
- Do NOT modify existing Grafana values (sidecar, datasources, dashboards) — only add the auth block
- Do NOT recreate the Keycloak client or groups — they already exist

### Verification

After `terraform apply`:
1. Open Grafana — should show login page with "Sign in with Keycloak" button
2. Click "Sign in with Keycloak" — should redirect to Keycloak login
3. Log in with a regular user → should redirect back to Grafana with Viewer role
4. Log in with a `kc_work_admin` member → should get Admin role
5. Admin account (admin/password from K8s secret) should still work as fallback
6. Check Grafana → Administration → Users — SSO users should appear after first login

### Output

Give me:
1. The updated `values.yaml.tftpl` diff
2. New Terraform resources (K8s secret, variables)
3. Updated tfvars entries
4. The terraform plan output
5. Any escaping issues with `$__env` in the `.tftpl` template
