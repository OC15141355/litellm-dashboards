# Keycloak performance testing — dev-environment brief

Research brief for the Keycloak performance/load-testing ticket. Everything
needed to run the engagement without web search; every non-obvious claim carries
a source key resolving to §10, and those URLs are WebFetch-able if you need to
go deeper.

**Standing rule: this brief describes UPSTREAM Keycloak behaviour and the
upstream tooling. It is NOT a finding about our deployment.** Sizing formulas,
bottleneck rankings and throughput numbers are Red Hat/Keycloak published
figures from *their* hardware. Our job is to measure ours. Where evidence
contradicts this brief, trust the evidence and say so.

**Target environment: dev only.** Dev is AWS + RHEL 10 + Rancher RKE2, managed
with Terraform, and is understood to be equal to or proportionally smaller than
prod. Nothing in this brief runs against prod.

---

## 0. Scope, and what we deliberately don't know yet

### 0.1 The ticket's acceptance criteria, restated

| # | AC | Covered by |
|---|---|---|
| AC1 | Evaluate Keycloak performance | §1 analytical + §4 measured |
| AC2 | Measure issues under load | §4, §7 |
| AC3 | Measure various touch points under load | §3.2 scenario map, §5 |
| AC4 | Review resourcing, determine if appropriate | §1 — largely answerable from Terraform before any test runs |
| AC5 | Test: 100 users all login at 8am | §4.2 |
| AC6 | Test: session creation | §4.2, §4.3 |
| AC7 | Test: login flow | §4.2 |
| AC8 | *(optional)* Corp sync and its impact on login | §6 |
| AC9 | Keycloak under login load while making an admin change (add user to group; find users in a group) | §5 |

### 0.2 Three unknowns — resolve these in Phase 0, do not assume

These change the shape of the whole engagement. Find them before designing runs.

1. **Real scale.** How many users in the realm; realistic peak logins/sec.
   AC5's literal reading — 100 logins spread over 60s — is **~1.7 logins/sec,
   about 0.11 vCPU** by Keycloak's own formula [S1]. Even compressed into 10
   seconds it is under one vCPU. A correctly resourced Keycloak does not
   struggle with that. So either the real population is much larger than the
   ticket's shorthand, or the actual risk is not raw login throughput but one
   of: concurrent corp sync saturating the DB, admin operations degrading,
   group-membership queries, or a cold-cache thundering herd where 100
   simultaneous logins all miss cache at once. **Determine which before
   designing the matrix** — testing the wrong hypothesis thoroughly is the main
   failure mode available here.
2. **An SLO.** Is there a stated bar ("login p95 < 2s")? If not, one must be
   proposed — this is not optional, because the tooling *defines failure in
   terms of an SLA* (§3.4) and "breaking point" is meaningless without one.
   Keycloak publishes an SLI guide to base this on [S6].
3. **Dev↔prod parity.** Replica count, CPU/memory requests+limits, DB instance
   class, AZ count. This is a Terraform/Helm diff, not a test. It determines
   whether the report can claim prod capacity directly, or must extrapolate and
   say so.

### 0.3 What this engagement produces

Not "we ran 100 logins and it was fine" — that is a weak deliverable that
proves nothing about headroom. The deliverable is:

> It is fine to **N**. It degrades at **M**. It fails at **P**. The first thing
> that breaks is **X**, visible as **Y** in metrics. Current resourcing gives
> **Z%** headroom against observed peak. Recommendation: ...

---

## 1. Analytical sizing verdict — do this first, before any load

AC4 ("review resourcing, determine if appropriate") is **largely a code-reading
task**. Requests/limits, replica count, JVM heap, DB instance class and cache
sizes are all in Terraform/Helm. Extract them, apply the published formulas,
and write a verdict. The load tests then confirm or falsify it. This ordering
matters: it gives a defensible answer even if testing gets blocked, and it
tells you what load levels are worth running.

### 1.1 Published sizing formulas [S1]

CPU:
- **1 vCPU ≈ 15 logins/sec**
- **1 vCPU ≈ 120 token refreshes/sec**
- **1 vCPU ≈ 200 client-credential grants/sec** (validated to 2000/sec)
- Leave **150% extra CPU headroom** for spikes, fast node startup, and failover

Memory:
- **Base ~1250 MB RAM per pod** — includes realm caches and 10,000 cached sessions
- **+500 MB per pod per 100,000 active sessions** (three-node cluster, validated to 200,000)
- In containers Keycloak allocates **70% of the memory limit** as heap

Caches [S1]:
- Above **~2500 distinct clients used concurrently**, not all client data fits
  cache and the **database becomes the bottleneck**
- Mitigation: users cache ≈ **2×** concurrent client count; realms cache ≈ **4×**

### 1.2 What to extract from Terraform/Helm

| Value | Why |
|---|---|
| Keycloak replica count | Divides the per-pod formulas |
| CPU requests **and** limits | Requests drive scheduling; limits drive throttling. Throttled CPU looks exactly like a slow app |
| Memory requests/limits | 70% becomes heap; too small → GC thrash, too large → long pauses [S1] |
| JVM options (`JAVA_OPTS_APPEND`, heap flags) | May override the 70% default [S5] |
| DB instance class, max_connections | DB CPU is the **first** bottleneck under login load [S2] |
| Keycloak DB connection pool size | Pool exhaustion presents as latency, not errors |
| Cache sizes (users, realms, sessions) | §1.1 thresholds |
| AZ / topology spread | Inter-AZ latency is brutal — see §7.4 |
| Keycloak version — **known: 26.6.1** | Confirm dev matches prod. Drives tooling version choice (§3.1) and the §1.5 caveats |
| HPA present? min/max replicas? | An HPA makes throughput tests non-reproducible unless pinned |

### 1.3 Verdict template

> At *R* replicas × *C* vCPU = *T* total vCPU. Published formula gives a
> theoretical ceiling of *T×15* logins/sec, and *T×120* refreshes/sec, before
> the 150% headroom rule. Against an observed/expected peak of *P* logins/sec
> that is *N×* headroom. Memory: *R × M* MB against a base requirement of
> 1250 MB + 500 MB per 100k sessions = *X* MB. Verdict: over/under/appropriately
> resourced, pending measurement.

**Caveat to state explicitly in the report:** these formulas assume a
local-database user store. If users are federated from LDAP/AD (§6), login cost
includes an LDAP round trip that the formula does not model, and the real
per-vCPU login rate will be lower.

---

## 1.5 We are on Keycloak 26.6.1 — what that changes

Confirmed work version: **26.6.1** (26.6.0 and 26.6.1 both released April 2026
[S12]). Several things follow.

**The published benchmark baseline is two minors behind us.** Red Hat's headline
numbers [S2] were produced on **26.4**. Between 26.4 and 26.6 the release notes
list [S12]:

- **"Performance improvements for client session queries"**
- **Role caching is now realm-specific** (previously cross-realm contention)
- **Session idle/lifetime settings revisited**
- **Connection pooling** — improved timeout handling and acquisition configuration

All four touch exactly the paths this engagement measures. Treat the §1.1
formulas and §7 rankings as *priors from 26.4*, expect our measurements to
differ, and do not report a discrepancy as a defect without checking whether a
26.5/26.6 change explains it. The 20ms-RTT finding in §7.4 is explicitly
attributed to **26.3** [S2] and may well be improved in our version — worth
verifying rather than assuming.

**Graceful HTTP shutdown is new and its defaults are short.** 26.6 adds delayed
shutdown plus connection draining for HTTP/1.1 and HTTP/2, with **timeouts
defaulting to 1 second each** [S12]. Under real login load, one second may not
be enough to drain in-flight requests, which would surface as client-visible
errors during any rolling restart or scale event. Two implications:

- If an HPA scales during a run, or a pod restarts, errors may be shutdown
  artifacts rather than capacity findings. Pin replicas (§4.1) and check pod
  restart counts before attributing errors to load.
- This is worth testing on purpose — a rolling restart under load is a genuine
  production event, and 26.6 also ships **zero-downtime patch upgrades** [S12].
  Not in the ACs; flag it as a follow-up rather than scope creep.

**Startup/liveness probes now return UP during database migrations** and server
initialization can be asynchronous [S12]. A pod reporting ready is therefore
weaker evidence that it is actually serving than it used to be. Confirm real
readiness with a request, not a probe status, before starting a measurement run.

**JDK:** 26.6 supports OpenJDK 25, but the **container images still ship
OpenJDK 21** (FIPS compatibility) [S12]. Record which JVM our image actually
runs — GC behaviour (§7.3) is JVM-version-sensitive, and assuming 25 when it is
21 would misread the GC data.

## 2. Instrumentation prerequisites — land these before testing

Without server-side metrics you can only report "Gatling says it was slow",
which cannot distinguish a slow Keycloak from a slow load generator, a slow
network, or a slow database. Get these in place first.

### 2.1 Keycloak metrics are OFF by default and the flag is BUILD-TIME [S3]

This is the day-one blocker. `metrics-enabled` is a **build-time** option — it
requires a `kc.sh build` / augmented image and a pod restart, not a runtime
config flip. Plan for an image change in dev.

Recommended startup configuration [S3]:

```
--metrics-enabled=true
--http-metrics-histograms-enabled=true
--http-metrics-slos=250,500,1000,2500
--cache-metrics-histograms-enabled=true
--event-metrics-user-enabled=true
```

`cache-metrics-histograms-enabled` (default false) adds histograms for the
embedded Infinispan caches [S3] — directly relevant to the §7.2 cache
bottleneck, which is the cheapest lever we have if the DB turns out to be the
constraint. Set `http-metrics-slos` buckets to straddle whatever SLO is agreed
in §0.2, not the values above, which are only a sensible default.

- Metrics are served on **`/metrics` on the management interface** (a separate
  port from the main HTTP listener — port-forward the management port, not 8080)
- Content type is `application/openmetrics-text`, natively Prometheus-scrapable
- `http-metrics-histograms-enabled` + `http-metrics-slos` give **server-side
  latency percentiles**. This is what turns "slow" into "slow *where*", and it
  lets you set SLO buckets that match the SLO you propose in §0.2

### 2.2 Everything else to have collecting

| Signal | How | Catches |
|---|---|---|
| Keycloak `/metrics` | Prometheus scrape / ServiceMonitor | Request rate, latency percentiles, error rate |
| JVM metrics (via same endpoint) | Micrometer JVM binders | GC pause time, heap pressure |
| Pod CPU throttling | `container_cpu_cfs_throttled_seconds_total` | Limits set too low — very common, looks like app slowness |
| DB CPU / connections / slow queries | RDS metrics or `pg_stat_statements` | The #1 bottleneck [S2] |
| Infinispan cache stats | Keycloak metrics + dataset cache endpoint (§3.3) | Cache misses, evictions [S2] |
| JFR profile | `kubectl exec … jcmd <pid> JFR.start` | Where JVM time actually goes, when metrics aren't enough |

**Note on profilers:** Keycloak is Java/Quarkus. Use **JFR** (built into the
JVM) or **async-profiler**. Python profilers such as `pyinstrument` are not
applicable to any part of this stack.

### 2.3 Baseline before load

Capture 15–30 minutes of idle-state metrics before the first run. Without a
baseline, every number is uninterpretable — you cannot tell a load-induced
regression from normal background behaviour.

---

## 3. Tooling — keycloak-benchmark

### 3.1 What it is and how to get it

The Keycloak project maintains **[keycloak-benchmark]**, a Gatling-based load
harness. It is the tool the Keycloak team uses to produce their own published
sizing numbers [S2], which means our results are directly comparable to theirs.

Three modules [S4]:
- **benchmark** — the Gatling load tests, run via `kcb.sh`
- **dataset** — a Keycloak server-side provider JAR that seeds realms/users/groups/clients/sessions
- **provisioning** — minikube/docker-compose setups (not needed; we have a real cluster)

GitHub releases carry prebuilt assets:

```
https://github.com/keycloak/keycloak-benchmark/releases/download/<TAG>/keycloak-benchmark-<TAG>.zip
https://github.com/keycloak/keycloak-benchmark/releases/download/<TAG>/keycloak-benchmark-dataset-<TAG>.jar
```

Runtime: **Java 17** (`maven.compiler.source/target = 17` [S4]). `kcb.sh`
defaults the generator JVM to `-Xmx1G` — raise it if the generator itself
becomes the bottleneck (see §4.1).

#### Version matching — we are on Keycloak 26.6.1 and there is no matching release

Published tags, checked 2026-08-18 [S4]: `999.0.0-SNAPSHOT` (2026-08-05),
`26.4.0-SNAPSHOT` (2025-11-17), `26.3.0-SNAPSHOT`, `26.2-SNAPSHOT`,
`26.1-SNAPSHOT`, `26.0-SNAPSHOT`. **There is no 26.5 or 26.6 release.** The
rolling `999.0.0-SNAPSHOT` is built from `main`, whose pom pins
`<keycloak.version>999.0.0-SNAPSHOT` — that is Keycloak *nightly*, which is
**ahead** of 26.6.1, not equal to it.

So no published artifact matches our server. The risk is **asymmetric between
the two modules**, and they should be handled differently:

| Module | Coupling | Risk | Do this |
|---|---|---|---|
| **benchmark** (Gatling) | Pure HTTP client against Keycloak's public OIDC + Admin REST endpoints | **Low** — those endpoints are stable across minors | Use `999.0.0-SNAPSHOT`. Falling back to `26.4.0-SNAPSHOT` is also fine |
| **dataset** (provider JAR) | Server-side SPI loaded *into* Keycloak, compiled against Keycloak internals | **High** — internal SPI changes between minors; skew fails at provider load or misbehaves silently | **Build from source pinned to our version** (below) |

**Preferred path — build the dataset JAR against 26.6.1.** The pom
parameterises the server version, so:

```
./mvnw clean package -Dkeycloak.version=26.6.1 -pl dataset -am
```

Needs Maven (the repo bundles `./mvnw`) and JDK 17 in the work environment.
This is the only route that gives a version-matched provider, and it is worth
the extra step — a silently misbehaving seeder corrupts the dataset that every
subsequent measurement rests on.

**Fallback if a build isn't possible:** try the `999.0.0-SNAPSHOT` dataset JAR
against 26.6.1 and verify it loads *and* functions (create a small realm, check
`/status-completed`, confirm the entity counts are actually right — a provider
that loads is not necessarily a provider that works). If it fails, seed via the
**Admin REST API** instead: slower and it lacks the cache-control endpoints
(§3.3), but it has zero version coupling. Losing the cache endpoints costs us
the cold-cache test in §4.2, so note that in the report if it comes to it.

Record the exact tag or build coordinates used, in the report, either way.

### 3.2 Scenario → AC map

Scenarios verified by reading source at commit `414d701` (2026-08-05) [S4].
Pass with `--scenario=keycloak.scenario.<package>.<Class>`.

| AC | Scenario | Notes |
|---|---|---|
| AC5, AC7 login flow | `authentication.AuthorizationCode` | Full OIDC authorization-code grant, incl. code→token exchange |
| AC7 login only | `authentication.LoginUserPassword` | Browser login via authorization endpoint, no token exchange. Use to isolate login cost from token-exchange cost |
| — | `authentication.ClientSecret` | Client-credentials grant. `kcb.sh` default scenario |
| AC6 sessions | `AuthorizationCode` + `--logout-percentage` / `--refresh-token-count` | Session lifecycle is controlled by these params, not a separate scenario |
| AC6 session inspection | `admin.ListSessions` | Creates sessions then queries session stats. Needs admin credentials |
| **AC9 add user to group** | **`admin.JoinGroup`** | **Directly covers it.** Not listed in the published scenario-overview page — found by reading source |
| AC9 user search under load | `admin.UserCrawl` | Pages through all users. `--user-page-size`, `--user-number-of-pages` |
| Admin write load | `admin.CreateUsers`, `CreateDeleteUsers`, `CreateGroups`, `CreateDeleteGroups`, `CreateRoles`, `CreateClients`, `CreateClientScopes`, `CreateRealms` (+ `CreateDelete*` variants) | Most need a client secret; realm ops need admin credentials |
| Admin console | `admin.HomePage` | Also undocumented on the overview page |
| Sanity check | `basic.Get` | Repeated HTTP GET against a URL |

`JoinGroup` composition, from source [S4]:

```scala
.serviceAccountToken()      // POST token endpoint, client_credentials
.createUser()               // POST /admin/realms/{realm}/users        → 201, saves Location
.findGroup(groupName)       // GET  /admin/realms/{realm}/groups?search={name}&max=1 → saves id
.joinGroup()                // PUT  {userLocation}/groups/{group-id}   → 204
```

Configured via `-Djoin-group-group-name=<name>`.

**Gap — "find users in a group" (AC9, second half) is NOT covered.** The
builder's `findGroup` searches *groups by name*; it does not list *members of a
group*. `GET /admin/realms/{realm}/groups/{id}/members` appears nowhere in the
scenario DSL. That is the one thing we build ourselves — see §5.

### 3.3 The dataset provider — realistic data volume

Testing against an empty realm measures nothing useful; most of the interesting
bottlenecks (§7) only appear with realistic cardinality. The dataset provider
JAR exposes REST endpoints on the Keycloak server [S4]:

`/create-realms`, `/create-clients`, `/create-users`, `/create-groups`,
`/create-sessions`, `/create-offline-sessions`, `/create-events`,
`/remove-realms`, `/status`, `/status-completed`, `/last-realm`, `/last-user`,
`/last-client`

Parameters relevant to this engagement (query params, with defaults) [S4]:

| Param | Default | Use |
|---|---|---|
| `count` | *required* | How many of the entity |
| `realm-name` | *required* for user/group/client ops | Target realm |
| `users-per-realm` | 200 | Realm population |
| `groups-per-realm` | 20 | Group cardinality |
| **`groups-per-user`** | **4** | **Directly drives AC9 cost** — group membership per user |
| `groups-with-hierarchy` | false | Nested groups |
| `groups-hierarchy-depth` | 3 | Nesting depth — nested groups are materially more expensive to resolve |
| `groups-count-each-level` | 10 | Width of the hierarchy |
| `realm-roles-per-user` | 4 | Token size and resolution cost |
| `client-roles-per-user` | 4 | Same |
| `clients-per-realm` | 30 | Cross-check against the 2500-client cache threshold (§1.1) |
| `password-hash-iterations` | *(unset)* | **Login CPU cost is dominated by password hashing.** Must match prod's realm setting or login numbers are meaningless |
| `users-per-transaction` | 10 | Seeding throughput |
| `threads-count` | *(unset)* | Seeding parallelism |
| `task-timeout` | 3600 | Long seeds |

Seeding is **asynchronous** — endpoints return a task handle; poll
`/status-completed`. Only one task runs at a time (a second request returns
400).

**`password-hash-iterations` deserves emphasis.** Argon2/PBKDF2 iteration count
is usually the single largest CPU cost in a login. Seeding users with default
iterations while prod uses a hardened realm setting will make dev look far
faster than prod, and the resourcing verdict will be wrong in the dangerous
direction. Read the real value off the prod realm and match it.

**Cache control endpoints** (same JAR) [S4]: `/sizes`, `/clear-sessions`,
`/{cache}/clear`, `/{cache}/size`, `/{cache}/contains/{id}`. `clear` immediately
before a run is how you test the **cold-cache thundering herd** hypothesis from
§0.2 — the most plausible mechanism by which a mere 100 simultaneous logins
could actually hurt.

**Hard constraint: the dataset provider must never be installed in prod.** It
creates and deletes entities **without authentication** [S7]. Dev only, and
removed or left disabled when the engagement ends.

### 3.4 Key `kcb.sh` parameters

All are JVM system properties; `kcb.sh` maps CLI flags onto them [S4].

**Load model** — pick one, they are mutually exclusive:
- `--users-per-sec=N` — **open model**: N new users arrive per second regardless
  of whether the system keeps up. Use this for "100 users login at 8am" and for
  any capacity question. Queues build if the server can't cope, which is what
  you want to observe.
- `--concurrent-users=N` — **closed model**: N users looping. Throughput is
  self-limiting, so the server can never fall behind. Use for steady-state
  soak, *not* for capacity.

Getting this choice wrong is the most common load-testing error: a closed model
will never show you a breaking point, because it throttles itself.

**Timing:** `--ramp-up=N` (default 5s), `--warm-up=N` (default 0),
`--measurement=N` (default 30s), `-Dfilter-results=true` (discard results
outside the measurement window), `-Duser-think-time=N`.

**Realm/user/client targeting:** `-Drealms`, `-Dusers-per-realm`,
`-Dclients-per-realm`, `-Drealm-name`, `-Drealm-prefix` (`realm-`),
`-Dusername-prefix` (`user-`), `-Duser-index-offset`, `-Duser-password-prefix`
(`user-`), `-Duser-password-suffix` (`-password`), `-Dclient-id`,
`-Dclient-secret`, `-Dclient-redirect-uri`, `-Dadmin-username`,
`-Dadmin-password`, `-Dscope`, `-Dserver-url` (comma-separated for multiple).

**Scenario-specific:** `-Dlogout-percentage` (default 100),
`-Drefresh-token-count`, `-Drefresh-token-period`, `-Dbad-login-count`,
`-Duser-page-size` (20), `-Duser-number-of-pages` (10),
`-Djoin-group-group-name`.

**SLA assertions — these define "failure":**
- `-Dsla-error-percentage` (default **0** — any error fails the run)
- `-Dsla-mean-response-time` (default **300** ms)

Set these deliberately from the SLO agreed in §0.2. Leaving the 300ms default
in place silently means "our SLO is 300ms mean", which is a claim nobody made.

### 3.5 Automated breaking-point search — `--increment=N`

`kcb.sh` has a built-in capacity search [S4]. With `--increment=N` it:

1. Runs a warm-up pass
2. Increases the workload by `N` each iteration
3. On the first run that **fails its SLA assertion**, backs off to the last
   successful level and **halves the increment**
4. Repeats, binary-searching until increment reaches 1
5. Symlinks `results/incremental-<timestamp>/last-successful` at the highest
   passing level

This is the §0.3 breaking-point deliverable for free, and it is why §0.2's SLO
is a prerequisite rather than a nicety — the SLA assertion *is* the failure
criterion driving the search.

Results land in `results/`; Gatling HTML reports include percentile
distributions. There is also a `CHAOS_MODE` env var — out of scope here.

### 3.6 Why not Locust

Locust would work, but the authorization-code flow would have to be
hand-implemented: cookie jar, redirect chase, scraping the hidden form action
out of the login page, code→token exchange, token refresh. That is a day of
work reproducing something keycloak-benchmark already does correctly, results
would not be comparable to Keycloak's published baselines, and any bug in the
hand-rolled flow becomes an invisible confound in the numbers. Only reach for
Locust if the work environment cannot run a JVM.

---

## 4. Test matrix — a decision tree, not fixed numbers

Do not run a fixed matrix. Phase 0 determines the numbers; the matrix branches
off what it finds.

### 4.1 Rules that apply to every run

- **Run the load generator in-cluster** (a k8s Job on the dev RKE2 cluster),
  never from a laptop over VPN. Otherwise you are measuring the VPN and the
  Wi-Fi, not Keycloak. This single mistake invalidates an entire engagement and
  it is not obvious from the results.
- **Verify the generator isn't the bottleneck.** If generator pod CPU is
  saturated, or `kcb.sh`'s default `-Xmx1G` is being hit, the numbers are the
  generator's limits, not Keycloak's. Check generator CPU on every run; scale
  out to multiple generator pods before concluding Keycloak is the limit.
- **Pin replica count.** If an HPA is present, pin it for the duration or
  throughput results are not reproducible.
- **One variable per run.** Changing load and cache size together tells you
  nothing about either.
- **Match prod's `password-hash-iterations`** (§3.3).
- **Baseline, then warm up, then measure.** Use `--warm-up` and
  `-Dfilter-results=true` so JIT warmup and cache fill don't pollute results.

### 4.2 Phase 1 — AC5/AC6/AC7, the stated scenario

Establish the literal ticket scenario as a floor. Expect it to pass easily; the
value is the baseline, not the result.

- `AuthorizationCode`, open model, `--users-per-sec` set to the real 8am arrival
  rate from Phase 0 (if genuinely 100 users over 60s, that is ~1.7/s)
- Then a **compressed burst**: the same 100 logins over 10s and over 5s, to
  model an actual simultaneous arrival rather than a smooth rate
- Then repeat the burst **with caches cleared immediately beforehand** (§3.3) —
  this is the cold-cache thundering-herd test and is the run most likely to show
  something interesting
- Vary `--logout-percentage` and `--refresh-token-count` for AC6 session
  behaviour; refreshes are ~8× cheaper than logins per the formulas [S1], so a
  refresh-heavy profile stresses different resources

### 4.3 Phase 2 — capacity envelope (AC1/AC2)

- `kcb.sh --scenario=…AuthorizationCode --increment=N` with SLA flags set from
  the agreed SLO (§3.5). Choose `N` so the search converges in a reasonable
  number of iterations given the analytical ceiling from §1.3
- Repeat for `ClientSecret` if service-account traffic is significant
- Record: max sustained logins/sec at SLO, and **what resource saturated first**
  — this is the actual finding, per §7

### 4.4 Phase 3 — AC9, admin operations under login load

The point is *interaction*, not either workload alone. Run concurrently:

- **Background:** `AuthorizationCode` at a level Phase 2 showed to be
  comfortable (say 60–70% of the SLO-passing max) — a realistic busy system,
  not an already-failing one
- **Foreground A:** `admin.JoinGroup` — measures add-user-to-group under load
- **Foreground B:** the group-members probe from §5 — measures find-users-in-a-group
- **Control:** run both foregrounds again with **no** background load

The deliverable is the **delta**: admin operation p50/p95 loaded vs unloaded.
"Adding a user to a group takes 120ms idle and 4.2s while under login load" is
a far more useful finding than either number alone, and it is the finding the
ticket is actually reaching for.

Vary `groups-per-user` and `groups-with-hierarchy` (§3.3) across seeds — group
resolution cost scales with membership count and nesting depth, and a flat
20-group realm will hide a problem that a deep hierarchy exposes.

### 4.5 Phase 4 — corp sync (AC8, optional)

See §6.

### 4.6 Phase 5 — break it

Dev exists to be broken. Push past the SLO limit until something actually
fails, and record the failure *mode*: 5xx, timeouts, pod OOMKill, DB connection
exhaustion, or silent latency collapse. Knowing how it fails is what makes the
capacity number actionable — a system that degrades gracefully at 2× and one
that falls over at 1.1× need different responses even with the same SLO limit.

---

## 5. The one thing we build — group-members probe

**Why custom:** `GET /admin/realms/{realm}/groups/{id}/members` is absent from
the keycloak-benchmark DSL (§3.2). It is also a classic slow path — member
listing scales with group size and, in federated realms, may hit LDAP.

**Why not a custom Gatling scenario:** writing Scala and building the benchmark
module adds tooling burden for one endpoint. A small script gives the same
measurement.

**Shape:**

- A short script (bash + `curl`, or Python + `requests`) running as a k8s Job
  alongside the load generator
- Obtains a service-account or admin token, refreshing before expiry
- Loops: `GET /admin/realms/{realm}/groups/{id}/members?first=0&max=N`, records
  wall-clock latency per call, sleeps a realistic admin-ish interval
- Emits p50/p95/p99 and error count at the end; also log raw samples so
  distribution shape is recoverable
- Parameterise `max` (page size) and target groups of **varying membership
  size** — the interesting result is how latency scales with group size, not a
  single number

Pair it with `admin.JoinGroup` (write path) for both halves of AC9. Run both
loaded and unloaded per §4.4.

**Measure honestly:** the probe's own latency includes network from probe pod to
Keycloak. Keep it in-cluster, and record an idle baseline so the loaded delta is
attributable.

---

## 6. Corp sync and login impact (AC8)

"Sync back with corp" is LDAP/AD user federation. **We already have a related
brief in this repo: `docs/keycloak-ldap-sub-drift-grafana-sourcegraph.md`** —
read it for how our federation is configured, which LDAP backend is involved,
and the known `sub`-drift failure mode. It will save discovery time and it
documents the federation component layout.

What to establish:

1. **Federation config** — `edit_mode`, `import_enabled`, sync period, full vs
   changed-user sync schedule, LDAP backend type. Terraform holds these.
2. **Is the login path federated?** If `import_enabled` is true, logins hit
   local storage after first import and LDAP cost is amortised. If not, every
   login round-trips LDAP and the §1.1 formulas understate login cost
   significantly.
3. **Sync-under-load test.** The real question: trigger a full sync
   *while* `AuthorizationCode` load is running, and measure login latency
   before/during/after. Full syncs are DB-write-heavy and DB CPU is already the
   first bottleneck (§7.1) — this is the most plausible mechanism for an 8am
   login problem that raw throughput numbers won't explain.

   The trigger is
   `POST /admin/realms/{realm}/user-storage/{provider-id}/sync?action=triggerFullSync`
   (`triggerChangedUsersSync` for the incremental variant) [S11]. **Verify this
   path against our Keycloak version before relying on it** — there are reports
   of it changing or dropping out of the docs around the 18→19 boundary [S11].
   `kcadm.sh` or the admin console's "Sync all users" button are equivalent
   routes if the REST path has moved.
4. **Control:** same login load with no sync running.

**Constraint:** do not point dev Keycloak at the production LDAP/AD in a way
that generates write load or lockouts against corp directory. Confirm the dev
federation target before triggering any sync. If dev federates prod AD
read-only, a full sync is still real load on a corporate system — get
agreement first.

---

## 7. Bottleneck playbook — what breaks, in what order

Ranked by Keycloak's own 26.4 benchmark findings [S2]. When something degrades,
check in this order. **Caveat: we run 26.6.1 and these rankings come from 26.4 —
see §1.5 for the changes in between that may shift them.**

### 7.1 Database CPU — the usual first constraint
In the 26.4 runs, DB CPU peaked at **77%**, dropping to **63%** when cache sizes
were raised from 10,000 to 200,000 entries [S2]. Symptoms: login latency rises
with concurrency while Keycloak pod CPU stays moderate. Check RDS CPU,
connection count, and slow queries. Fix: cache sizing (§1.1) before instance
sizing.

### 7.2 Cache sizing and eviction
Above ~2500 concurrent clients, cache misses push load to the DB [S1]. Check
Infinispan cache entry counts and eviction rate via metrics; the dataset
provider's `/sizes` endpoint (§3.3) gives a direct read. Fix: users cache 2×,
realms cache 4× concurrent client count.

### 7.3 Garbage collection
Larger caches raised mean GC pause from **3.99ms to 4.91ms** in the 26.4 runs —
a real but modest cost [S2]. GC becomes a problem at the extremes: too-small
heap causes frequent collections and inflated CPU; too-large heap causes long
pauses [S1]. Check JVM GC metrics; confirm the container 70%-of-limit heap
allocation is what you think it is.

### 7.4 Network latency — disproportionately severe
The most striking 26.4 finding: a **20ms round-trip delay took response times
from 130ms to ~1076ms** on version 26.3 [S2]. Latency does not add linearly; it
multiplies through the flow's several round trips. Relevant to us via AZ
topology (§1.2): if dev is single-AZ and prod spans AZs, **dev will look
dramatically better than prod and the extrapolation will be wrong**. Check pod
topology spread and Keycloak↔DB AZ placement in both, and call this out
explicitly in the report if they differ.

### 7.5 CPU throttling — not on the upstream list, but common
Kubernetes CPU limits set close to requests cause CFS throttling that presents
as application slowness with no obvious cause. Check
`container_cpu_cfs_throttled_seconds_total`. Worth ruling out early because it
is cheap to check and embarrassing to miss.

### 7.6 Connection pool exhaustion
Keycloak's DB pool smaller than its concurrency ceiling produces latency (queueing)
rather than errors, which makes it easy to misread as slow queries. Compare pool
size against observed concurrency. **26.6 changed connection-pool timeout handling
and acquisition configuration** [S12] — check the current options rather than
carrying over settings or assumptions from an older version.

---

## 8. Report structure

1. **One-paragraph plain-English summary** a non-expert can repeat. This is the
   actual deliverable — everything else is evidence.
2. **Analytical resourcing verdict** (§1.3) — answers AC4
3. **Method** — tool + exact release tag, scenarios, load model (open/closed),
   where generators ran, dataset seed parameters, SLO used for SLA assertions
4. **Results per AC** with the numbers
5. **Capacity envelope** — fine to N, degrades at M, fails at P, first thing to
   break is X
6. **Admin-under-load deltas** (§4.4) — loaded vs unloaded, side by side
7. **Threats to validity** — dev↔prod deltas, especially AZ topology (§7.4),
   password hash iterations, federation differences, generator limits
8. **Recommendations**, separated into *resourcing* and *configuration*, each
   with the evidence that supports it
9. **Reproduction instructions** — exact commands, so results can be re-run
   after any change

---

## 9. What we deliberately don't do

- **No prod testing.** Dev only, entire engagement.
- **No dataset provider in prod, ever** — it mutates without authentication [S7].
- **No hand-rolled Locust OIDC flow** (§3.6).
- **No load generation from a laptop over VPN** (§4.1).
- **No capacity claim about prod that isn't explicitly labelled as extrapolated**
  from dev, with the parity deltas stated.
- **No treating this brief's numbers as our findings.** The §1.1 formulas and
  §7 rankings are upstream figures from Red Hat's hardware. They are priors to
  test, not results to report.
- **No tuning changes applied as part of the investigation.** Measure first,
  recommend second. A config change mid-engagement invalidates the runs before it.
- **No corp LDAP/AD sync triggered without confirming the dev federation target**
  (§6).

---

## 10. Sources

WebFetch-able. Per-claim keys used throughout.

| Key | Source | Used for |
|---|---|---|
| S1 | https://www.keycloak.org/high-availability/multi-cluster/concepts-memory-and-cpu-sizing | vCPU/RAM formulas, cache sizing thresholds, headroom rule, GC guidance |
| S2 | https://www.keycloak.org/2025/10/keycloak-benchmark — "Keycloak Performance Benchmarks: A Deep Dive into Scaling and Sizing (26.4)" | Bottleneck ranking, DB CPU 77%→63%, GC 3.99→4.91ms, 20ms RTT → 1076ms |
| S3 | https://www.keycloak.org/observability/configuration-metrics | Metrics off by default, build-time option, `/metrics` on management interface, `http-metrics-histograms-enabled`, `cache-metrics-histograms-enabled`, `http-metrics-slos`. Re-verified against current docs 2026-08-18 |
| S4 | https://github.com/keycloak/keycloak-benchmark — **verified by reading source at commit `414d701de677c49432bd16f28dd9b1fff60bf92b` (2026-08-05)** | Scenario list incl. undocumented `JoinGroup`/`HomePage`, full `Config` property list, `kcb.sh` incremental mode, dataset endpoints and query params, Java 17 |
| S5 | https://www.keycloak.org/keycloak-benchmark/kubernetes-guide/latest/running/jvm/jvm_options | Keycloak JVM options |
| S6 | https://www.keycloak.org/observability/keycloak-service-level-indicators | Basis for proposing an SLO |
| S7 | https://www.keycloak.org/keycloak-benchmark/dataset-guide/latest/using-provider | Dataset provider usage; never install in production |
| S8 | https://www.keycloak.org/keycloak-benchmark/benchmark-guide/latest/ | Benchmark guide index — build/download, CLI, Ansible/EC2 |
| S9 | https://www.keycloak.org/keycloak-benchmark/kubernetes-guide/latest/util/prometheus | Collecting Prometheus metrics in the Kubernetes guide |
| S10 | `docs/keycloak-ldap-sub-drift-grafana-sourcegraph.md` (this repo) | Our LDAP federation layout and known `sub`-drift failure mode |
| S11 | https://www.keycloak.org/docs-api/latest/rest-api/index.html — Admin REST API reference. Version caveat discussed at https://github.com/keycloak/keycloak/discussions/21977 | `user-storage/{id}/sync` trigger path; verify against our version |
| S12 | https://www.keycloak.org/2026/04/keycloak-2660-released and https://www.keycloak.org/2026/04/keycloak-2661-released | 26.6 changes: client-session query performance, realm-specific role caching, session idle/lifetime, connection pooling, graceful shutdown + 1s drain defaults, async init, probes UP during migration, OpenJDK 25 support / images on 21 |

**Note on Red Hat docs:** `docs.redhat.com` returns **HTTP 403 to WebFetch**.
Use the equivalent pages on `keycloak.org` (S1, S3, S6 are all keycloak.org and
fetch fine). Red Hat's 26.6 release notes exist but are not machine-fetchable
from here.

Upstream docs omit `JoinGroup` and `HomePage` from the published scenario
overview; the S4 source read is authoritative over the docs page where they
disagree.

[keycloak-benchmark]: https://github.com/keycloak/keycloak-benchmark
