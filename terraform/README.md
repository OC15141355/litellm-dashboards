# Terraform Prompts

Claude Code prompts for work infrastructure changes. Each prompt is designed to be pasted into Claude Code on the work device with access to the Terraform repo.

## Workflow

1. Copy the prompt from the relevant `.md` file
2. Open Claude Code in the work Terraform repo
3. Paste the prompt
4. Review Claude's output and iterate

## Prompts

| File | Ticket | Purpose |
|------|--------|---------|
| `01-gather-context.md` | Pre-work | Explore existing Terraform structure, understand patterns |
| `02-rancher-monitoring-to-iac.md` | Deploy k8s monitoring as code | Move Rancher Monitoring Helm chart to Terraform |
| `03-grafana-standalone.md` | Deploy standalone Grafana | New Grafana instance with Keycloak SSO + LiteLLM datasource |
