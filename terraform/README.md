# Terraform Prompts — External Access to Grafana Epic

Claude Code prompts for work infrastructure changes. Each prompt maps to a ticket in the epic and is designed to be pasted into Claude Code on the work device with access to the Terraform repo.

## Workflow

1. Copy the prompt from the relevant `.md` file
2. Open Claude Code in the work Terraform repo
3. Paste the prompt
4. Review Claude's output and iterate

## Prompts

| File | Ticket | Purpose |
|------|--------|---------|
| `01-gather-context.md` | Pre-work | Explore existing Terraform structure, understand patterns |
| `02-monitoring-to-iac.md` | Ticket 1 — Deploy k8s monitoring as code | Import existing Rancher Monitoring Helm release into Terraform |
| `03-expose-grafana.md` | Ticket 2 — Expose Grafana for external access | Add ingress config to the monitoring Helm values |
| `04-grafana-keycloak-sso.md` | Ticket 3 — Configure Grafana SSO | Add Keycloak OIDC auth to Grafana via Helm values |
| `05-litellm-datasource-dashboard.md` | Post-epic | Add LiteLLM PostgreSQL datasource + cost attribution dashboard |

## Recommended Order

1. `01` → `02` → `03` (tickets 1-2, codify + expose)
2. `05` (LiteLLM datasource + dashboard — validate data flows before adding SSO)
3. `04` (Keycloak SSO — lock down access last)

## Notes

- Tickets 2 and 3 are Helm value additions on top of ticket 1. They could be combined into one PR or done separately.
- Prompt 05 can be done anytime after ticket 2 — doesn't require SSO. Recommended before SSO so you can verify the dashboard works.
- The `grafana_reader` database role must be created manually on RDS before prompt 05 — see `docs/work-grafana-deployment.md` for bastion/DBeaver instructions.
- All prompts assume the Terraform repo follows a modules + environments pattern. Prompt 01 validates this assumption.
