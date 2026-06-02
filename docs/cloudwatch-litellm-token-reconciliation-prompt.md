# Work-Claude prompt — reconcile CloudWatch GenAI metrics vs LiteLLM SpendLogs

Copy the fenced block below straight into the work env. Prereqs for the agent: **read-only** CloudWatch
(`cloudwatch:GetMetricData`, `GetMetricStatistics`, `ListMetrics`) and **read-only** access to the LiteLLM DB.
It is a read-only investigation — it changes nothing.

Grounded in this session's verified facts (LiteLLM v1.83.14 source + AWS docs) so a less-capable agent doesn't
re-derive them wrong — most importantly: **LiteLLM inflates `prompt_tokens` to include cache, while CloudWatch
`InputTokenCount` excludes cache**, so the two only line up when you add CloudWatch's cache metrics back in.

```text
INVESTIGATION (read-only): Reconcile AWS Bedrock CloudWatch GenAI metrics vs the LiteLLM SpendLogs DB.

CONTEXT: A senior eng built a CloudWatch dashboard (InputTokenCount, OutputTokenCount,
CacheReadInputTokenCount, CacheWriteInputTokenCount, Invocations for sonnet-4-6/haiku-4-5/
opus-4-6/opus-4-8) and reports "significantly different token counts between AWS and LiteLLM,"
suspecting LiteLLM uses the wrong token-counting algorithm (docs.litellm.ai/docs/count_tokens).
Determine the REAL cause and whether LiteLLM's recorded counts are accurate.
DO NOT modify the dashboard, LiteLLM config, or the DB. Read-only only.

VERIFIED FACTS (LiteLLM v1.83.14 source + AWS docs — build on these, do NOT re-derive):
1. `count_tokens` / the linked doc = a CLIENT-SIDE PRE-CALL ESTIMATOR (tiktoken for Claude).
   It does NOT write SpendLogs or set spend. So it is NOT the source of the logged counts —
   the "wrong algorithm" suspicion points at the wrong component.
2. LiteLLM records the token counts Bedrock RETURNS in the response usage
   (litellm/llms/bedrock/chat/converse_transformation.py).
3. CACHE INFLATION: LiteLLM sets
   SpendLogs.prompt_tokens = Bedrock inputTokens + cacheReadInputTokens + cacheWriteInputTokens
   (source literally captures raw_input_tokens "before inflation"). So prompt_tokens INCLUDES cache.
4. CloudWatch InputTokenCount = NON-cache input ONLY; CacheRead/CacheWrite are SEPARATE additive
   metrics (AWS: TPM quota = Input + CacheWrite*1.25 + CacheRead*0.1 + Output).
5. CORRECT like-for-like:
     prompt_tokens     ~= InputTokenCount + CacheReadInputTokenCount + CacheWriteInputTokenCount
     completion_tokens ~= OutputTokenCount
   Comparing prompt_tokens vs InputTokenCount ALONE shows LiteLLM higher by the cache amount
   (definitional, not an error).
6. CloudWatch aggregates ALL Bedrock calls in the account, incl. callers NOT through LiteLLM
   (e.g. Sourcegraph) -> CloudWatch >= LiteLLM for any outside traffic.
7. SpendLogs has no cache columns; cache totals live in LiteLLM_Daily*Spend
   (cache_read_input_tokens, cache_creation_input_tokens).

METHOD:
A. CloudWatch (GetMetricData, read-only): namespace AWS/Bedrock, dimension ModelId, per day for the
   last 30d, SUM of the 5 metrics per model. ModelIds are au.anthropic inference profiles -> map to
   the model_name LiteLLM logs.
B. LiteLLM DB (read-only SELECT), same window:
     SELECT date_trunc('day',"startTime") d, model, count(*) reqs,
            sum(prompt_tokens) pt, sum(completion_tokens) ct
     FROM "LiteLLM_SpendLogs" WHERE "startTime" >= now()-interval '30 days' GROUP BY 1,2;
   Cache totals:
     SELECT date, model, sum(cache_read_input_tokens) cr, sum(cache_creation_input_tokens) cw
     FROM "LiteLLM_DailyTeamSpend" WHERE date >= to_char(now()-interval '30 days','YYYY-MM-DD')
     GROUP BY 1,2;
   (model names: SpendLogs.model is the public model_name; CloudWatch is the inference-profile ModelId
   -> align them before joining.)
C. RECONCILE per model/day:
   - prompt_tokens  vs  (InputTokenCount + CacheRead + CacheWrite)   [expect ~equal for LiteLLM traffic]
   - completion_tokens vs OutputTokenCount
   - reqs vs Invocations   [CloudWatch>=LiteLLM; delta = non-LiteLLM calls + unlogged requests]
   - LiteLLM cache (cr/cw) vs CloudWatch CacheRead/CacheWrite
D. ATTRIBUTE the gap to: (a) cache bundling (prompt_tokens incl cache vs InputTokenCount excl),
   (b) non-LiteLLM invocations, (c) logging gaps, (d) the estimator (only if his number came from
   count_tokens). Quantify each.
E. SPEND SANITY: prompt_tokens includes cache -> confirm cost calc isn't double-charging cache
   (cache should price at cheaper read / premium write rates, not the base input rate).

OUTPUT: a per-model table (CloudWatch components | LiteLLM | delta | attributed cause) + a plain-language
verdict: is LiteLLM's counting accurate (it records Bedrock's returned usage), and what fully explains the
difference. State only what the data shows; flag anything unresolved. Read-only throughout.
```
