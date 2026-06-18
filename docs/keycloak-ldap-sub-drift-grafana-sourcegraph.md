# Keycloak LDAP `sub` Drift → Grafana "User sync failed" + Sourcegraph Duplicate Users — Investigation & Remediation Brief

> **Audience:** the work agent (Claude Code, Sonnet) that *can* touch the live Keycloak / Grafana / Sourcegraph systems but *cannot* web-search. This brief carries the research so you don't have to. Every hypothesis below is paired with the exact command / query that confirms or kills it on the real systems. Run the **forensic test in §3 first** — it discriminates between all root causes in one shot.
>
> **Researched & verified:** 2026-06-19, Opus 4.8 + web (multi-source, adversarially fact-checked). Confidence levels and primary sources are inline. DB-edit remediations are **unsupported and version-sensitive** — verify schema against the live DB before running anything.

---

## 0. TL;DR (READ FIRST)

**Symptom:** Someone changes the **Keycloak Terraform module** and runs `terraform apply`. Afterward, LDAP-federated users' OIDC `sub` claim has **changed**. Downstream:
- **Grafana** (generic OAuth, `allow_sign_up: true`) → `"Login failed. User sync failed."` / `"user already exists"` / `"Failed to create user"`.
- **Sourcegraph** (SAML/OIDC) → silently provisions a **duplicate** account, username suffixed `user-12345` / `<name>-1`.
- Currently most visible on the **`kc_work_admin`** group only — because that's the group actually being edited; the others are nearly empty, so blast radius (which scales per-member) hasn't shown yet.

**The load-bearing fact (this explains everything):**

> A federated user's Keycloak internal id — which Keycloak emits **verbatim as the OIDC `sub`** — is **not** a free-standing UUID. It is structured:
>
> ```
> f:<FEDERATION-COMPONENT-UUID>:<EXTERNAL-ID>
> ```
>
> The **federation provider component's own UUID is embedded inside every federated user's `sub`.** (Confirmed in the wild: Grafana issue #74154 shows `auth_id=f:4187354b-...:blazepa1`.)

Two things therefore regenerate the `sub`, and **which one you have changes the fix**:

| # | Mechanism | Signature | Fix axis |
|---|-----------|-----------|----------|
| **A** | The **federation component is recreated** → new component UUID → the `f:<UUID>:` **prefix changes for ALL federated users at once** | "everyone drifted simultaneously on an apply" | Terraform (stop the recreate) |
| **B** | **`uuid_ldap_attribute` changed / objectGUID encoding flipped** → the **`<EXTERNAL-ID>` suffix changes**, prefix stays | mass re-import as "new" users / "already exists" | Terraform + LDAP mapper config |
| **C** | **Keycloak #28248** (24.0.0–24.0.2 regression): an admin-API `PUT` that sets `attributes` but omits `LDAP_ID` drops the federation link and **recreates that one user** with a fresh id | per-edited-user drift; **only on unpatched 24.0.x** | Upgrade Keycloak ≥ 24.0.3 |
| **D** | Keycloak **silently deletes + recreates** federated users on an LDAP timeout / `objectGUID` GUIDResolve failure during the sync the apply triggers | subs moved but `terraform plan` shows **no replacement** | Fix LDAP reliability / objectGUID binary handling |

**Your observation ("all the users' sub UUIDs drift") points hardest at A.** The `kc_work_admin`-only visibility and "change to the keycloak module" trigger are consistent with A or C. **§3's forensic test tells you which, definitively, from data you already have.**

**A plain group-membership join does NOT change a `sub`** (verified) — so the group correlation is incidental: editing the admin group is just *the change that runs Terraform*, and Terraform is what recreates the component / issues the lossy PUT.

> ### ⚠️ Tap vs mop — two changes, in this order
> There are **two** fixes and they are not interchangeable:
> 1. **Turn off the tap (upstream cure):** stop the `sub` from drifting — the Terraform/Keycloak config fix in §4. Until this lands, *every `apply` re-breaks everyone* and you mop forever.
> 2. **Mop the floor (downstream remediation):** the one-time **DB re-link** of already-orphaned accounts in §6 (Grafana `user_auth.auth_id`, Sourcegraph `user_external_accounts.account_id`). This repairs the *link*, keeping the existing local accounts + dashboards + permissions. Deleting users is a workaround, not this.
>
> Do **(1) then (2)**. Doing only (2) means you'll re-run it after the next `terraform apply`.

---

## 0.5 INVESTIGATION MANDATE — prove it against the real code before fixing anything

> **This brief is a hypothesis set derived from how Keycloak/Terraform/Grafana behave upstream — NOT a finding about this specific deployment.** Do not apply any fix until you have confirmed *which* mechanism (A/B/C/D from §0) is actually firing **in this repo's Terraform code, provider version, state, and git history**, and identified the specific change that triggered it. Replace every assumption below with evidence. If the evidence contradicts this brief, **trust the evidence and say so.**

### Phase 1 — read the actual Terraform (this is the part the user explicitly wants grounded)

```bash
# 1. Locate the federation + mapper resources and the module(s) they live in
grep -rn 'keycloak_ldap_user_federation\|keycloak_ldap_.*_mapper\|keycloak_user_federation' --include=*.tf .

# 2. Pin the PROVIDER and VERSION actually in use (ForceNew schema is version-specific)
grep -rn 'keycloak' .terraform.lock.hcl
grep -rn 'mrparkers/keycloak\|keycloak/keycloak\|required_providers' --include=*.tf .

# 3. Dump the federation resource config verbatim — capture every argument set
#    Specifically record: realm_id, delete_default_mappers, uuid_ldap_attribute,
#    import_enabled, edit_mode, vendor, and whether a lifecycle{} block exists.
```

For each argument, map it to a hypothesis:
- `uuid_ldap_attribute` present and = `objectGUID`/`entryUUID`/`nsuniqueid`? If it was **changed** in git history → **B**. If it's wrong/missing → latent B.
- Any `lifecycle { prevent_destroy / ignore_changes }` already on the resource? (If absent, A is unguarded.)
- Is the federation managed as a **single resource**, or could a module refactor have moved its address?

### Phase 2 — find the triggering change in git history (correlate to the drift event)

```bash
# When did the federation/module last change, and what changed?
git log --oneline -- <path/to/keycloak/module>
git log -p -- <path/to/federation.tf>          # read the actual diffs
git blame <path/to/federation.tf>               # who/what set realm_id, uuid_ldap_attribute, delete_default_mappers

# Did anyone do state surgery outside normal apply? (recreates the component → A)
git log --all --oneline | grep -iE 'state rm|moved|import|reimport|recreate|federation'
# also check CI/CD run logs / PR history for `terraform state rm` or a manual import
```
**Goal:** name the commit/PR whose `apply` correlates with the first wave of "User sync failed." Diff it. Does it touch `realm_id`, `delete_default_mappers`, `uuid_ldap_attribute`, or rename/move the resource? That diff is your smoking gun for A vs B.

### Phase 3 — what does Terraform think *right now*

```bash
terraform init -backend=true
terraform plan -no-color | tee /tmp/kc-plan.txt
grep -nE 'forces replacement|must be replaced|-/\+|keycloak_ldap_user_federation|keycloak_ldap_.*_mapper' /tmp/kc-plan.txt

# Is the component UUID in state the same one Keycloak is serving right now?
terraform state show '<addr of keycloak_ldap_user_federation>' | grep -E '^\s*id\s*='
# compare to the live component id:
#   kcadm.sh get components -r <realm> -q type=org.keycloak.storage.UserStorageProvider --fields id,name
```
- Plan proposes a replacement of the federation/mappers → **A is live and will recur on next apply.**
- State `id` ≠ live Keycloak component id → the component was recreated out-of-band (drift already happened, A).
- Plan clean, but subs still moved historically → suspect **C** (check version, §2) or **D** (Keycloak logs, §4).

### Phase 4 — confirm on the running systems

Run **§2** (Keycloak version → is C even possible) and **§3** (the stale-vs-current `sub` prefix/suffix diff → A vs B vs C). These two + the git diff from Phase 2 should converge on a single verdict.

### Report back in this shape (so it can be explained, not just trusted)

```
HYPOTHESIS A (component recreate): EVIDENCE FOR … | AGAINST … | VERDICT: confirmed/refuted
HYPOTHESIS B (uuid_ldap_attribute): EVIDENCE FOR … | AGAINST … | VERDICT: …
HYPOTHESIS C (#28248, KC 24.0.x):  KC version = … | VERDICT: possible/impossible
HYPOTHESIS D (silent LDAP delete): plan clean? … | KC logs? … | VERDICT: …

TRIGGERING CHANGE: <commit/PR + the exact attribute/diff that did it>
BLAST RADIUS: <# Grafana rows w/ stale auth_id> / <# Sourcegraph user-NNNN dups>
FIX (tap):  <specific TF/Keycloak change, §4>
REMEDIATION (mop): <SQL re-link count, §6>
```

Plain-English one-paragraph summary at the top, written so a non-expert can repeat it. **That summary is the actual deliverable** — the rest is the evidence trail behind it.

---

## 1. Architecture (ground truth, from this repo)

```
Active Directory / LDAP
        │  (Keycloak LDAP user federation; sub = f:<component-uuid>:<external-id>)
        ▼
   Keycloak realm  ── managed by Terraform (keycloak/keycloak provider) ──
        │  OIDC (groups claim: kc_work_admin / _corp_users / _ext_users / _read-only)
        ▼
   Grafana (standalone, auth.generic_oauth, allow_sign_up: true, RDS PostgreSQL)
   Sourcegraph (SAML/OIDC, keys on external account_id)
   + SonarQube / Artifactory / Bitbucket / Confluence / Jira (same exposure class)
```

Confirmed config (see `terraform/04-grafana-keycloak-sso.md`):
- Grafana `auth.generic_oauth`, **`allow_sign_up: true`**, `scopes: openid email profile groups`, role via `role_attribute_path` JMESPath on the `groups` claim.
- Grafana DB = **RDS PostgreSQL** → remediation SQL is Postgres.
- Keycloak OIDC client `grafana`, group-membership mapper → `groups` claim, full path OFF.
- Groups: `kc_work_admin` (→ Grafana Admin), `kc_work_corp_users`, `kc_work_ext_users`, `kc_work_read-only` (→ Viewer).

**Detect the LDAP backend (you said "not sure"):** the immutable-id attribute differs by vendor.

```bash
# via kcadm (adjust host/realm/creds); look at the federation component config
kcadm.sh config credentials --server https://<kc>/ --realm master --user <admin>
kcadm.sh get components -r <realm> -q type=org.keycloak.storage.UserStorageProvider \
  --fields 'id,name,providerId,config(vendor,uuidLDAPAttribute,editMode,importEnabled,connectionUrl)'
```
- `vendor: ad` → **Active Directory**, immutable id = **`objectGUID`** (binary octet string — see §4 gotcha)
- `vendor: other` + OpenLDAP → **`entryUUID`**
- 389-DS / FreeIPA → **`nsuniqueid`**

---

## 2. STEP 0 — Pin the Keycloak version (decides whether C is even possible)

```bash
# any of these
kcadm.sh get serverinfo --fields systemInfo.version
curl -s https://<kc>/admin/serverinfo | jq '.systemInfo.version'   # if reachable
kubectl -n <kc-ns> get pod -l app=keycloak -o jsonpath='{.items[*].spec.containers[*].image}'
```

- **24.0.0 / 24.0.1 / 24.0.2** → mechanism **C is live**. [keycloak#28248](https://github.com/keycloak/keycloak/issues/28248) (Blocker/regression, fixed [#28455](https://github.com/keycloak/keycloak/pull/28455) in **24.0.3 / 25.0.0**, Apr 2024). If you're here, **upgrading past 24.0.3 is likely the single highest-leverage fix** — but still run §3, because A can co-exist.
- **≥ 24.0.3** → C is patched; the cause is **A, B, or D**. Do not chase C.

---

## 3. THE FORENSIC TEST — run this first (discriminates A / B / C in one shot)

The `sub` is stored in Grafana's `user_auth.auth_id` and Sourcegraph's `user_external_accounts.account_id`. **Decode the structure of a stale value vs a fresh login.**

### 3a. Pull a stale `sub` from Grafana (the value from *before* the drift)

```sql
-- Grafana RDS Postgres. auth_module for generic oauth is 'oauth_generic_oauth'.
SELECT ua.user_id, u.login, u.email, ua.auth_module, ua.auth_id, ua.created
FROM   user_auth ua
JOIN   "user" u ON u.id = ua.user_id
WHERE  ua.auth_module = 'oauth_generic_oauth'
ORDER  BY ua.created
LIMIT 20;
```

Note the shape of `auth_id`. For LDAP-federated users it should look like `f:<component-uuid>:<external-id>`.

### 3b. Get the *current* `sub` for the same person

Log a known affected user in (or read the token), OR ask Keycloak for the user's current id:

```bash
# current Keycloak internal id (= the sub) for a username
kcadm.sh get users -r <realm> -q username=<known-user> --fields id,username,federationLink

# the live federation COMPONENT UUID (the f:<this>: prefix)
kcadm.sh get components -r <realm> -q type=org.keycloak.storage.UserStorageProvider --fields id,name
```

### 3c. Diff and read the verdict

| What changed between stale and current | Root cause | Confidence |
|---|---|---|
| The **`f:<UUID>:` prefix** changed (same suffix) → **component UUID differs** | **A — component recreated** | High |
| The **`<external-id>` suffix** changed (same `f:<UUID>:` prefix) | **B — `uuid_ldap_attribute` / objectGUID encoding changed** | High |
| Stale was `f:...:...`, current is a **plain UUID** (no `f:` prefix) or vice-versa | **C — #28248 user recreate** (or `import_enabled` flip) | High (if KC 24.0.x) |
| `sub` **didn't actually change** but login still fails | Not drift — see §7 "things that look like drift but aren't" | — |

> **This is the whole investigation in three queries.** Everything below is *what to do* once you know which letter you have.

---

## 4. ROOT CAUSE DETAIL + THE TERRAFORM FIX

### Mechanism A — federation component recreated (most likely)

`keycloak_ldap_user_federation` in the `keycloak/keycloak` provider has **only two `ForceNew` attributes**: `realm_id` and `delete_default_mappers`. *(Provider source: `provider/resource_keycloak_ldap_user_federation.go`.)* Changing either, **or** the component getting recreated outside ForceNew (a `terraform state rm` + re-create, a manual console delete, a rename without a `moved` block, a re-import), mints a **new component UUID** → new `f:<uuid>:` prefix → **every federated user's `sub` changes at once.**

Mapper resources (`keycloak_ldap_*_mapper`) have `realm_id` **and** `ldap_user_federation_id` as `ForceNew`, so if the parent is replaced, all mappers cascade-replace too.

**Catch it before it happens — read every plan against the Keycloak module:**
```bash
terraform plan -no-color | grep -nE 'forces replacement|must be replaced|-/\+|keycloak_ldap_user_federation'
```
A replacement shows as `-/+ resource "keycloak_ldap_user_federation" ... # forces replacement`.

**Prevent it:**
```hcl
resource "keycloak_ldap_user_federation" "this" {
  # ...
  lifecycle {
    prevent_destroy = true          # apply ERRORS instead of silently recreating — human must intervene
    ignore_changes  = [
      bind_credential,              # rotated out-of-band; don't let drift churn the resource
      # add fields that drift in console but shouldn't trigger updates
    ]
  }
}
```
- **Never** touch `realm_id` or `delete_default_mappers` on a live federation. Everything else (`connection_url`, `bind_dn`, `bind_credential`, `edit_mode`, `cache`, `sync_period`, `full_sync_period`, `vendor`) is **in-place / safe**.
- Refactoring addresses → use a [`moved` block](https://developer.hashicorp.com/terraform/language/modules/develop/refactoring) or `terraform state mv`, never let a rename become destroy+create.
- Component exists in Keycloak but missing from state → `terraform import`, **not** re-create (import preserves the component UUID).

### Mechanism B — `uuid_ldap_attribute` changed (the sneaky one)

`uuid_ldap_attribute` is **not** ForceNew — it updates in place and slips through `plan` as an innocuous change — but it redefines the `<external-id>` half of every user id. Changing it (e.g. someone "tidied" it, or AD `objectGUID` flipped between binary and text representation) → Keycloak computes a different `<external-id>` → mass re-import as new users / `"already exists"` / `"value too long"`.

**Correct immutable value by backend** (set once, then *never change*):
| Backend | `uuid_ldap_attribute` |
|---|---|
| Active Directory | `objectGUID` |
| OpenLDAP | `entryUUID` |
| 389-DS / Red Hat DS / FreeIPA | `nsuniqueid` |

**AD `objectGUID` binary gotcha:** `objectGUID` is a binary octet string. Keycloak/JNDI must treat it as binary (`GUIDResolve` path). If that LDAP call throws (timeout, bad filter), a known Keycloak bug ([#24669](https://github.com/keycloak/keycloak/issues/24669)) can **delete the user** → recreate → new id. So a flaky AD connection alone can manifest as drift (that's mechanism **D**).

### Mechanism C — Keycloak #28248 (only 24.0.0–24.0.2)

An admin-API `PUT /users/{id}` that includes `attributes` but omits `LDAP_ID` drops `federationLink` and recreates the user with a new id. The Terraform provider and any custom admin tooling issue such PUTs. **Fix = upgrade Keycloak ≥ 24.0.3.** Until then, avoid attribute-rewriting PUTs on federated users.

### Mechanism D — silent delete on LDAP failure (plan shows nothing)

If `terraform plan` is clean yet subs moved, check Keycloak logs around the apply for LDAP timeouts / `NamingException` / `GUIDResolve` / `KeyUtils` warnings ([#24669](https://github.com/keycloak/keycloak/issues/24669), [#9520](https://github.com/keycloak/keycloak/issues/9520)). Fix = LDAP reliability + correct binary `objectGUID` handling, not Terraform.

```bash
kubectl -n <kc-ns> logs deploy/keycloak --since=24h | grep -iE 'naming|guidresolve|ldap.*(timeout|connect)|keyutils|federation'
```

---

## 5. WHY GRAFANA THROWS "User sync failed" (so the fix makes sense)

Grafana keys an external OAuth user in **`user_auth`**: `user_id`, `auth_module` (`oauth_generic_oauth`), **`auth_id`** (= the `sub`), with a unique index on `(auth_module, auth_id)`. `"user".email` is UNIQUE.

When the `sub` changes:
- The post-auth **`user.sync.internal`** hook (runs *after* successful Keycloak auth) can't match the new `auth_id`.
- With `allow_sign_up: true` it tries to **create** a user → collides with the existing `email`/`login` → **`"user already exists"` / `"Failed to create user"` / `"UNIQUE constraint failed: user.email"`** → surfaced to the user as **`"Login failed. User sync failed."`**

Generic OAuth has a documented fragile path: it *"does not store authID, so we need to find the user first then check for the userAuth connection by module and userID"* (`pkg/services/authn/authnimpl/sync/user_sync.go`, quoted in [grafana#85232](https://github.com/grafana/grafana/issues/85232)). Corroborated: [#74154](https://github.com/grafana/grafana/issues/74154), [#67438](https://github.com/grafana/grafana/issues/67438), [#70203](https://github.com/grafana/grafana/issues/70203), [#111139](https://github.com/grafana/grafana/issues/111139) (11.6.0).

---

## 6. NON-DESTRUCTIVE REMEDIATION (repair drift WITHOUT deleting users)

> The old Keycloak component UUID / ids are **effectively unrecoverable** via API/UI (only a Keycloak DB restore of the old `COMPONENT` row id would bring them back — unsupported, high-risk). **Forward-fix downstream is the practical path.** Deleting the Grafana/Keycloak user is a *workaround, not a requirement.*

### 6a. Grafana — re-link `auth_id` to the new `sub` (map by email)

There is no `sub` history, so you match old user → new sub **by verified email**.

**Option 1 (preferred, self-healing, no manual SQL): `oauth_allow_insecure_email_lookup`.**
Setting `[auth] oauth_allow_insecure_email_lookup = true` makes Grafana fall back to matching the existing user **by verified email** when the `auth_id` lookup misses — it re-links and **re-stamps the new `sub` automatically**.
- ⚠️ Reintroduces the **CVE-2023-3128** auth-bypass class. You MUST scope `allowed_organizations` / `allowed_groups` / `allowed_domains` and ensure emails are verified. Treat as a **temporary unblock**, then turn back off.

**Option 2 (surgical DB re-link) — verify schema on the live DB first:**
```sql
-- DRY RUN: see who would be touched. Replace placeholders.
SELECT ua.user_id, u.login, u.email, ua.auth_id AS stale_sub
FROM   user_auth ua JOIN "user" u ON u.id = ua.user_id
WHERE  ua.auth_module = 'oauth_generic_oauth'
  AND  u.email = :affected_email;

-- FIX one user: point the existing row at the new sub. BACK UP user_auth first.
UPDATE user_auth
SET    auth_id = :new_sub
WHERE  auth_module = 'oauth_generic_oauth'
  AND  user_id = (SELECT id FROM "user" WHERE email = :affected_email);
```
Risks: editing `user_auth` is unsupported; target the correct row or you create a *second* collision; the `(auth_module, auth_id)` unique index will reject a `new_sub` that's already present (means a dup user was already created — resolve that first). **Always `SELECT` before `UPDATE`; snapshot the table.**

### 6b. Sourcegraph — fix the external-account row / merge dups

Schema (`internal/database/schema.md`): `user_external_accounts(user_id, service_type, service_id, client_id, account_id, ...)`, unique index on `(service_type, service_id, client_id, account_id) WHERE deleted_at IS NULL`. `account_id` = the external `sub`/NameID.

**Measure blast radius (the `user-12345` signature you noticed):**
```sql
-- Sourcegraph Postgres: suffixed dup usernames = drift footprint
SELECT id, username, created_at FROM users
WHERE username ~ '-[0-9]+$' OR username ~ '^user-[0-9]+$'
ORDER BY created_at DESC;

-- orphaned/duplicated external accounts
SELECT user_id, service_type, service_id, account_id, created_at
FROM user_external_accounts WHERE deleted_at IS NULL
ORDER BY user_id;
```
**Repair:** Sourcegraph auto-links accounts by **verified email**, so the cleanest fix is ensuring the canonical user's email is verified, then **update the surviving row's `account_id` to the new `sub`** and soft-delete (`deleted_at = now()`) the duplicate's external-account row, reassigning any content. Sourcegraph has **no built-in merge** — docs only document manual email update or remove+recreate. Validate procedure on a staging instance.

---

## 7. Things that look like drift but AREN'T (don't get fooled)

- A **pure group-membership join** does **not** change a `sub`. Verified. If you suspect "group changed the sub," check whether your group workflow actually issues an attribute-rewriting **user PUT** (mechanism C) rather than a plain group-join.
- **`login_attribute_path: sub` is NOT a Grafana-recommended stabilization** — that common internet advice was **refuted** (0-3). Do not add it expecting it to fix this.
- Re-login failing with empty userinfo (no sub change) is a *different* bug class ([#97333](https://github.com/grafana/grafana/issues/97333)) — refuted as the cause here.
- Grafana SAML's stable-key `assertion_attribute_external_uid` only works with **SCIM (Enterprise/Cloud only)** — unavailable to this OSS shop.

---

## 8. Cross-stack exposure — the SCIM-less lifecycle reality

Every app here does **JIT provisioning** (creates on first login) and **none auto-deprovision without SCIM** (Enterprise-only across the board). Each keys on a persistent external id, so each shares the "external-id changed → orphaned/duplicate" failure mode:

| App | Identity key | On `sub`/id change | Auto-deprovision? |
|---|---|---|---|
| **Grafana** (generic OAuth) | `user_auth.auth_id` = sub | Errors: "user already exists" | No (SCIM = Enterprise/Cloud) |
| **Sourcegraph** (SAML/OIDC) | `user_external_accounts.account_id` | Silent **duplicate** (`user-12345`); auto-links by verified email | No (SCIM planned) |
| **SonarQube** | external login | New user; memberships refresh each login | No (SCIM = Enterprise, Entra/Okta only) |
| **Bitbucket DC** | NameID → username | Fails: "user does not exist" if mapping breaks | No (manual delete) |
| **Confluence / Jira DC** | sub assumed persistent | Changed id → **new user provisioned** | **No** — "no way to delete the user from the internal directory"; manual cleanup |
| **Artifactory** | SAML username | JIT create | No (SCIM = paid) |

**Strategic implication:** stabilize the upstream id (fix the Keycloak federation per §4) and the whole downstream class stops drifting. Deprovisioning will need a deliberate plan — manual cleanup or a **Keycloak event-listener / admin-event-driven script**, since JIT never removes anyone.

---

## 9. Recommended order of operations

1. **§2** — pin Keycloak version. If 24.0.0–24.0.2, schedule upgrade ≥ 24.0.3 (kills C).
2. **§3** — run the forensic test; identify A / B / C / D from the stale-vs-current `sub` diff.
3. **§4** — apply the matching Terraform/LDAP fix; add `prevent_destroy` + `ignore_changes` and the `terraform plan | grep` pre-apply gate so this can't recur.
4. **§6** — repair the already-drifted users non-destructively (email-lookup self-heal or surgical re-link), measure Sourcegraph dup blast radius, merge dups.
5. **§8** — put a deprovisioning plan on the backlog (the real SCIM-less gap).

---

## 10. Sources (all primary unless noted)

- **Keycloak federated-id structure / drift:** [#28248](https://github.com/keycloak/keycloak/issues/28248) + fix [#28455](https://github.com/keycloak/keycloak/pull/28455), [#37992](https://github.com/keycloak/keycloak/issues/37992), [#46537](https://github.com/keycloak/keycloak/issues/46537), [#31670](https://github.com/keycloak/keycloak/issues/31670), [#24669](https://github.com/keycloak/keycloak/issues/24669), [#9520](https://github.com/keycloak/keycloak/issues/9520), [discussion #23933](https://github.com/keycloak/keycloak/discussions/23933), [Server Admin Guide](https://www.keycloak.org/docs/latest/server_admin/).
- **Terraform provider:** [keycloak/terraform-provider-keycloak](https://github.com/keycloak/terraform-provider-keycloak) (`resource_keycloak_ldap_user_federation.go`, `resource_keycloak_ldap_full_name_mapper.go`), [adoption note](https://www.keycloak.org/2024/12/terraform-provider-adoption), [Terraform lifecycle docs](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle).
- **Grafana:** [#85232](https://github.com/grafana/grafana/issues/85232), [#74154](https://github.com/grafana/grafana/issues/74154), [#67438](https://github.com/grafana/grafana/issues/67438), [#70203](https://github.com/grafana/grafana/issues/70203), [#111139](https://github.com/grafana/grafana/issues/111139), [generic-oauth docs](https://grafana.com/docs/grafana/latest/setup-grafana/configure-access/configure-authentication/generic-oauth/), [SAML docs](https://grafana.com/docs/grafana/latest/setup-grafana/configure-access/configure-authentication/saml/), CVE-2023-3128.
- **Sourcegraph:** `internal/database/schema.md` (`user_external_accounts`), [docs/admin/auth](https://sourcegraph.com/docs/admin/auth) + [SAML](https://sourcegraph.com/docs/admin/auth/saml).
- **Cross-stack:** [SonarQube auth overview](https://docs.sonarsource.com/sonarqube-server/instance-administration/authentication/overview), [Atlassian JIT](https://confluence.atlassian.com/enterprise/jit-user-provisioning-1005342579.html), [Bitbucket SAML KB](https://support.atlassian.com/bitbucket-data-center/kb/saml-authentication-fails-with-received-sso-request-for-user-but-the-user-does-not-exist-in-bitbucket-data-center/), [JFrog SAML](https://docs.jfrog.com/administration/docs/saml-sso).

> **Caveats:** Mechanism C is version-scoped (24.0.0–24.0.2 only). The DB re-link remediations (§6) are synthesized from the confirmed matching mechanism, not prescribed verbatim by any vendor — they are **unsupported, schema- and version-dependent**; verify against the live DB and snapshot before running. Several plausible-sounding theories were tested and **refuted** (see §7).
