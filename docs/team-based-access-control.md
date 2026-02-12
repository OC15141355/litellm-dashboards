# Team-Based Access Control in LiteLLM

## Problem Statement

We need to restrict LiteLLM usage to specific teams, enforce per-team budgets, and provide visibility into who is spending what. This is critical for the Claude Code pilot - we can't give blanket access to all developers without cost controls and attribution.

---

## How It Works

### Core Model

```
Team (budget + model access)
  └── Virtual Key (tied to team, aliased per user)
        └── All spend attributed to team automatically
```

- **Teams** define the boundary: budget, allowed models, and membership
- **Virtual keys** are the enforcement mechanism: a key can only access its team's models and counts against the team's budget
- **Users** are optional - the virtual key is the identity for spend tracking

### What Happens When Limits Are Hit

| Scenario | Behaviour |
|----------|-----------|
| Team budget exceeded | Request blocked: "Budget has been exceeded! Current cost: $X, Max budget: $Y" |
| Key budget exceeded | Request blocked at key level (if per-key budget set) |
| Model not in team's allowed list | Request rejected |
| Key revoked/disabled | Request rejected immediately |

---

## Approach: Virtual Keys Per Person, Budget Per Team

This is the recommended approach for the pilot. No enterprise license required.

### Structure

```
Team: Platform-Engineering ($500/mo)
  ├── sk-plat-alice    (key_alias: alice,   max_budget: $100)
  ├── sk-plat-bob      (key_alias: bob,     max_budget: $100)
  └── sk-plat-charlie  (key_alias: charlie, max_budget: $100)

Team: Data-Science ($300/mo)
  ├── sk-ds-dave       (key_alias: dave,    max_budget: $75)
  └── sk-ds-eve        (key_alias: eve,     max_budget: $75)
```

### Budget Enforcement

Budgets work at two levels:

| Level | Controls | Reset |
|-------|----------|-------|
| **Team** | Total spend cap across all keys | Configurable: daily, monthly (`budget_duration: "30d"`) |
| **Key** | Individual spend cap per developer | Configurable independently |

A developer hitting their key budget is blocked, but the team can still operate. The team hitting its budget blocks everyone on the team.

### Model Access Control

Teams are created with a list of allowed models. Keys inherit the team's model access:

```bash
# Team can only use Claude Sonnet and Haiku - not Opus
./admin-cli.sh team create "Platform-Engineering" 500 "claude-3-sonnet,claude-3-haiku"
```

Any request through a team key for a model not in the allowed list is rejected.

---

## Pilot Onboarding Workflow

### Step 1: Create the Pilot Team

```bash
./admin-cli.sh team create "Pilot-Team" 200 "claude-3-sonnet,claude-3-haiku"
```

- Budget: $200/month (adjustable)
- Models: Sonnet + Haiku only (no Opus to control costs)
- Duration: 30d rolling reset

### Step 2: Generate Keys for Pilot Members

```bash
./admin-cli.sh key create Pilot-Team "pilot-alice" 50
./admin-cli.sh key create Pilot-Team "pilot-bob" 50
./admin-cli.sh key create Pilot-Team "pilot-charlie" 50
```

Each developer gets a personal key with a $50 individual cap within the $200 team budget.

### Step 3: Developer Setup

Each pilot member configures Claude Code:

```bash
export ANTHROPIC_BASE_URL="https://litellm.example.com"
export ANTHROPIC_API_KEY="sk-pilot-alice-key-here"
```

That's it. All requests route through LiteLLM, attributed to the Pilot-Team.

### Step 4: Monitor

- **Grafana Team Dashboard**: Shows real-time spend per team and per key
- **CLI audit**: `./admin-cli.sh audit team-spend Pilot-Team`
- **Prometheus alert**: Set alert on `litellm_remaining_team_budget_metric` when budget is low

### Step 5: Offboarding / Key Rotation

```bash
# Revoke a specific key
./admin-cli.sh key delete <key-hash>

# Rotate a key (if compromised)
# Generate new key, distribute to developer, delete old key
```

---

## Visibility & Reporting

### Who Can See What

| Role | Access | How |
|------|--------|-----|
| **Platform team** | Everything - all teams, all keys, all spend | LiteLLM Admin UI (master key) + Grafana Operations dashboard |
| **Team lead** | Their team's spend, per-developer breakdown | Grafana Team View dashboard (filtered by team variable) |
| **Developer** | Their own spend | Grafana Team View (filtered by key alias) or CLI |

Team leads get **read-only visibility** via Grafana. They never touch LiteLLM or see the master key.

### Grafana Dashboard Variables

The Team View dashboard supports filtering by:
- `team_alias` - show one team's data
- `api_key_alias` - drill into individual developer spend

### Prometheus Metrics Available

| Metric | Labels | Use |
|--------|--------|-----|
| `litellm_spend_metric_total` | model, team, key | Cost attribution |
| `litellm_requests_metric_total` | model, team, key | Usage volume |
| `litellm_remaining_team_budget_metric` | team | Budget monitoring |
| `litellm_total_tokens_metric_total` | model, team, key | Token consumption |

---

## Scaling Beyond Pilot

### Phase 1: Pilot (Current - Free Tier)

- 1 team, 3-5 developers
- Manual key management via CLI
- Platform team handles onboarding/offboarding
- Grafana for visibility

### Phase 2: Multi-Team Rollout (Free Tier)

- Multiple teams, each with own budget and model access
- Team leads get Grafana access for their team
- Key management still manual (platform team)
- Consider per-team Slack channels for key requests

### Phase 3: Enterprise (If Licensed)

| Feature | What Changes |
|---------|-------------|
| **SCIM** | Keycloak groups auto-sync to LiteLLM teams. Add user to Keycloak group → they get team access. Remove from group → keys revoked |
| **JWT Auth** | API calls authenticated via Keycloak JWT. Team membership derived from `groups` claim. No virtual keys needed for team attribution |
| **RBAC** | Team leads can manage their own team's keys without master key |
| **Audit logs** | Built-in retention and compliance reporting |

Enterprise eliminates the manual key management bottleneck and gives team leads self-service.

---

## Comparison of Approaches

| Approach | License | Team Attribution | Key Management | Keycloak Integration |
|----------|---------|-----------------|----------------|---------------------|
| **Virtual keys per person** | Free | Via key alias | Manual (platform team) | None - keys distributed out of band |
| **JWT Auth** | Enterprise | Via JWT `groups` claim | Not needed - JWT is the key | Full - groups map to teams |
| **SCIM** | Enterprise | Via synced groups | Auto-provisioned | Full - lifecycle managed by Keycloak |

### Recommendation

Start with **virtual keys per person** for the pilot. This requires no enterprise license, gives full cost attribution, and validates the workflow. If the pilot succeeds and we scale to more teams, enterprise (SCIM) eliminates the manual overhead.

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Key shared between developers | Spend attributed to wrong person | Naming convention, periodic audit, key rotation |
| Team budget too low | Developers blocked mid-work | Monitor remaining budget metric, set alerts at 80% |
| Team budget too high | Unexpected cloud costs | Start conservative, increase based on actual usage |
| Master key exposure | Full admin access compromised | Restrict to platform team, rotate quarterly, audit via CloudTrail |
| Developer leaves, key not revoked | Continued spend on departed user | Offboarding checklist, periodic key audit |
| No enterprise license available | Manual key management doesn't scale | Acceptable for pilot (3-5 devs). Revisit at 15+ developers |

---

## Quick Reference

```bash
# Create team with $500 budget, monthly reset, Claude Sonnet + Haiku access
./admin-cli.sh team create "Engineering" 500 "claude-3-sonnet,claude-3-haiku"

# Create key for developer (team budget: $500, individual cap: $100)
./admin-cli.sh key create Engineering "eng-alice" 100

# Check team spend
./admin-cli.sh audit team-spend Engineering

# List all keys for a team
./admin-cli.sh key list Engineering

# Full audit across all teams
./admin-cli.sh audit all-teams
```
