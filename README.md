# LiteLLM Grafana Dashboards

Pre-built Grafana dashboards for monitoring [LiteLLM](https://github.com/BerriAI/litellm) proxy deployments.

## Dashboards

| Dashboard | File | Audience | Purpose |
|-----------|------|----------|---------|
| **Operations & FinOps** | `grafana-dashboard.json` | Platform team | Overall system health, costs, budgets |
| **Team View** | `grafana-dashboard-team.json` | Team leads | Per-team spend, usage, performance |
| **Model Comparison** | `grafana-dashboard-models.json` | Developers | Compare models on cost, latency, reliability |

## Admin Scripts

See [`admin-scripts/`](./admin-scripts/) for CLI tools to manage teams, users, and API keys.

```bash
# List all teams
./admin-scripts/litellm-admin.sh team list

# Create team with budget
./admin-scripts/litellm-admin.sh team create "Engineering" 500

# Audit spend across all teams
./admin-scripts/litellm-admin.sh audit all-teams
```

## Screenshots

### Operations & FinOps
- Overview stats (requests, spend, tokens, error rate)
- Request rate and latency (p50/p95/p99) by model
- Time to First Token (TTFT)
- Success vs failure rates
- Spend by API key and model
- Budget tracking gauges
- Cache efficiency

### Team View
- Team selector dropdown
- Budget remaining vs max with reset timer
- Spend vs budget trend line
- Usage breakdown by model
- Per-team latency and error rates
- API key breakdown table

### Model Comparison
- Cost per 1K tokens (bar chart)
- Median latency comparison
- Success rate by model
- P95 latency over time
- Deployment health status
- Fallback and cooldown tracking
- Summary comparison table

## Prerequisites

1. **LiteLLM** with Prometheus callback enabled:
   ```yaml
   litellm_settings:
     callbacks:
       - prometheus
   ```

2. **Prometheus** scraping LiteLLM's `/metrics/` endpoint (note: trailing slash required)

3. **Grafana** with Prometheus configured as a data source

## Installation

### Step 1: Verify Prometheus is scraping LiteLLM

```bash
# Check metrics are available
curl -s "https://your-litellm-url/metrics/" | head -20

# In Prometheus UI, query:
litellm_requests_metric_total
```

### Step 2: Import dashboards into Grafana

1. Open Grafana → **Dashboards** → **Import**
2. Click **Upload JSON file** or paste the JSON contents
3. Select your **Prometheus data source** from the dropdown
4. Click **Import**
5. Repeat for each dashboard

### Step 3: Verify data is flowing

After import, panels should populate within the scrape interval (default: 30s). If panels show "No data":
- Check time range (top right) - try "Last 1 hour"
- Verify Prometheus data source is correct
- Check Prometheus is scraping: `up{job="litellm"}`

## Usage

| Dashboard | How to Use |
|-----------|------------|
| **Operations & FinOps** | Open and set time range. Shows global view of all teams, models, spend. Use for daily platform monitoring. |
| **Team View** | Select a team from the **Team** dropdown at top. All panels filter to that team. Share the URL with team leads. |
| **Model Comparison** | Open and view - shows all models side-by-side. No filters needed. Use when choosing which model to recommend. |

### Time Ranges

- Operations dashboard defaults to **24 hours**
- Team and Model dashboards default to **7 days**
- Adjust using the time picker (top right)

### Sharing with Team Leads

**Option 1: Direct link**
- Navigate to Team View dashboard
- Select their team from dropdown
- Copy URL (includes team parameter)
- Share the link

**Option 2: Grafana Viewer role**
- Create Grafana users with Viewer role
- They can view but not edit dashboards
- Set Team View as their home dashboard

**Option 3: Dashboard snapshots**
- Dashboard → Share → Snapshot
- Creates a point-in-time snapshot
- Can be shared without Grafana login

## Key Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `litellm_requests_metric_total` | Counter | Total LLM requests (by model, team, key) |
| `litellm_spend_metric_total` | Counter | Spend in USD (by model, team, key) |
| `litellm_total_tokens_metric_total` | Counter | Total tokens used |
| `litellm_request_total_latency_metric` | Histogram | End-to-end request latency |
| `litellm_llm_api_time_to_first_token_metric` | Histogram | Time to first token (TTFT) |
| `litellm_deployment_success_responses_total` | Counter | Successful model calls |
| `litellm_deployment_failure_responses_total` | Counter | Failed model calls |
| `litellm_remaining_team_budget_metric` | Gauge | Remaining budget per team |
| `litellm_remaining_api_key_budget_metric` | Gauge | Remaining budget per API key |
| `litellm_deployment_state` | Gauge | Health: 0=healthy, 1=partial, 2=outage |
| `litellm_cache_hits_metric_total` | Counter | Cache hits |
| `litellm_deployment_latency_per_output_token` | Gauge | Generation speed |

## Sample PromQL Queries

```promql
# Request rate by model
sum(rate(litellm_requests_metric_total[5m])) by (model)

# Error rate
sum(rate(litellm_deployment_failure_responses_total[5m]))
  / (sum(rate(litellm_deployment_success_responses_total[5m]))
     + sum(rate(litellm_deployment_failure_responses_total[5m])))

# P95 latency by model
histogram_quantile(0.95, sum(rate(litellm_request_total_latency_metric_bucket[5m])) by (le, model))

# Spend by team (last 24h)
sum(increase(litellm_spend_metric_total[24h])) by (team)

# Cost per 1K tokens by model
(sum(increase(litellm_spend_metric_total[24h])) by (model))
  / (sum(increase(litellm_total_tokens_metric_total[24h])) by (model)) * 1000
```

## Dashboard Details

### Operations & FinOps (`grafana-dashboard.json`)

**Sections:**
| Section | Panels |
|---------|--------|
| Overview | Total Requests, Spend, Tokens, Error Rate |
| Operations/SRE | Request rate, Latency (p50/p95/p99), TTFT, Success/Failure, Overhead |
| FinOps | Spend by API Key, Spend by Model, Token Usage, Spend Distribution |
| Budget Tracking | Remaining Team/Key Budgets, Budget Reset Timers |
| Cache & Efficiency | Cache Hit Rate, Cached Tokens |

### Team View (`grafana-dashboard-team.json`)

**Variables:**
- `team` - Dropdown populated from `label_values(litellm_spend_metric_total, team_alias)` (shows human-readable team names)

**Sections:**
| Section | Panels |
|---------|--------|
| Team Overview | Spend, Requests, Tokens, Budget Remaining, Max Budget, Reset Timer |
| Spend & Usage | Spend by Model, Requests by Model, Distribution Pie, Token Usage, Spend vs Budget |
| Performance | Latency (p50/p95), TTFT, Error Rate, Cache Hit Rate |
| API Keys | Table with Spend, Requests, Tokens per key |

### Model Comparison (`grafana-dashboard-models.json`)

**Sections:**
| Section | Panels |
|---------|--------|
| Overview | Cost/1K Tokens, Median Latency, Success Rate (bar charts) |
| Latency | P95 over time, TTFT, Latency per output token, p50 vs p99 |
| Cost & Usage | Spend over time, Request rate, Distribution pies |
| Reliability | Error rate, Deployment health, Fallbacks, Cooldowns |
| Summary | Comparison table with all metrics |

## Contributing

Issues and PRs welcome!

## License

MIT
