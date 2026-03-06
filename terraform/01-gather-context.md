# Prompt 01 — Gather Terraform Context

Paste this into Claude Code when you're in the work Terraform repo. This is a research-only prompt — no changes will be made.

---

## Prompt

I need you to explore this Terraform repo and give me a full understanding of how it's structured. Do NOT make any changes — just read and report back.

### What to look for

**1. Repo structure**
- How are modules organized? (`modules/`, `environments/`, etc.)
- What modules exist? (e.g., litellm, sourcegraph, keycloak)
- Is there a shared/common module or are they all independent?

**2. Module anatomy**
Pick the most complete module (probably `litellm` or `sourcegraph`) and document:
- What resources does `main.tf` create? (Helm release, K8s secrets, ConfigMaps, etc.)
- How are variables structured in `variables.tf`?
- How are secrets handled? (AWS Secrets Manager? K8s secrets? Sealed secrets?)
- Is there a `pre-install.sh` or bootstrap script?
- How is the Helm chart sourced? (OCI registry, Helm repo URL, local chart?)

**3. Environment config**
- How do `dev` vs `prod` differ? (separate tfvars? separate state? workspaces?)
- What's the backend config? (S3 + DynamoDB?)
- How are environment-specific values passed? (tfvars files, variable defaults?)

**4. Helm release pattern**
For any existing `helm_release` resources, document:
- How are values passed? (inline `set` blocks, `values` YAML, templatefile?)
- How are chart versions managed? (pinned in tfvars? hardcoded?)
- How are secrets injected into Helm values? (envFrom, existingSecret, inline?)

**5. Provider config**
- What providers are used? (kubernetes, helm, aws, keycloak?)
- How is the K8s/Helm provider authenticated? (kubeconfig, in-cluster, exec?)
- What AWS region?

**6. Existing monitoring setup**
- Is there anything related to monitoring/Prometheus/Grafana already in Terraform?
- Or is it purely deployed via Rancher UI?
- Any references to `cattle-monitoring-system` namespace?

### Output format

Give me:
1. A directory tree of the repo (2-3 levels deep)
2. A summary table of all modules with: name, resources created, Helm chart (if any), namespace
3. The exact pattern for: Helm release, secrets, variables — with code snippets from the most representative module
4. Any gotchas or inconsistencies you notice (e.g., hardcoded values that should be variables, modules that don't follow the common pattern)
5. Recommendations for how a new `monitoring` module should be structured to match existing conventions
