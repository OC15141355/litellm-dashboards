# Keycloak `sub` Drift — Work-Claude Kickoff

> Paste the prompt below to Claude Code in the work environment. It pairs with
> `docs/keycloak-ldap-sub-drift-grafana-sourcegraph.md` in this repo — pull latest
> `main` first so both files are present, and run it **from the repo that holds the
> Keycloak Terraform code** (or have that path handy).

## Kickoff prompt (paste verbatim)

Read `docs/keycloak-ldap-sub-drift-grafana-sourcegraph.md` in this repo in full before doing anything. **Important: that brief is a HYPOTHESIS SET derived from upstream Keycloak/Terraform/Grafana behavior — it is NOT yet a finding about our deployment. Your job is to prove which mechanism is actually firing, against our real code and systems, before proposing any fix. If the evidence contradicts the brief, trust the evidence and say so.**

Do this in order:

1. **Run the §0.5 INVESTIGATION MANDATE end to end** against the actual Terraform repo and live systems:
   - Phase 1 — find and dump the real `keycloak_ldap_user_federation` + mapper resources, pin the provider + version, record `realm_id` / `delete_default_mappers` / `uuid_ldap_attribute` / `import_enabled` / `edit_mode` and whether any `lifecycle{}` guard exists.
   - Phase 2 — `git log -p` / `git blame` the Keycloak module to find the commit/PR whose `apply` correlates with the first "User sync failed", and check for out-of-band `terraform state rm` / `import` / `moved`.
   - Phase 3 — `terraform plan` now (does it propose a replacement of the federation/mappers?) and compare the component `id` in state vs the live Keycloak component id.
   - Phase 4 — confirm Keycloak version (§2) and run the §3 forensic test (diff a stale `sub` in Grafana `user_auth.auth_id` vs the current Keycloak `sub` — prefix changed = A, suffix changed = B, plain-UUID flip = C).

2. **Report back in the §0.5 template**: evidence-for / evidence-against / verdict per hypothesis A/B/C/D, the named triggering commit + the exact attribute/diff, and blast-radius counts (Grafana rows with stale `auth_id`; Sourcegraph `user-NNNN` duplicates). Lead with a plain-English one-paragraph summary a non-expert can repeat — that summary is the actual deliverable.

3. **STOP and show me the verdict before any change.** Do not apply a Terraform/Keycloak change and do not run any DB write until I've seen the evidence and confirmed.

4. Once the mechanism is confirmed, propose the **two fixes in order** (the brief's "tap vs mop"): (a) the upstream cure that stops the drift (§4 — guard the ForceNew attrs / `prevent_destroy` / patch Keycloak ≥24.0.3 / pin `uuid_ldap_attribute`), then (b) the one-time non-destructive DB re-link to repair already-orphaned accounts (§6). Present each as a reviewable diff / SQL with a dry-run SELECT first; do not execute yet.

Treat anything that mutates Keycloak, Terraform state, or a production DB as requiring my explicit go-ahead.

## Prerequisites — have these ready or work-Claude will block

| Need | For |
|---|---|
| The repo/path holding the Keycloak Terraform code + `terraform`/`git` access | §0.5 Phase 1–3 |
| `terraform init` against the real backend (read-only `plan` is enough to start) | Phase 3 |
| Keycloak admin access (`kcadm.sh` or admin API) to read components + a user's current id | Phase 1/3/4, §2/§3 |
| Read access to the Grafana RDS PostgreSQL (`user_auth`, `"user"`) | §3 forensic test, §6 blast radius |
| Read access to the Sourcegraph PostgreSQL (`users`, `user_external_accounts`) | §3 / §6 dup count |
| Keycloak server version (`kcadm.sh get serverinfo` / pod image) | §2 — decides if #28248 is even possible |
| Which LDAP backend Keycloak federates (AD / OpenLDAP / 389-DS) — or let it detect via the federation component config | §1 detect step, §4 `uuid_ldap_attribute` |

## Hard constraints (restate — don't let work-Claude skip these)

- **Prove before fixing.** The brief is hypotheses, not a verdict. No Terraform apply, no state change, no DB write until the mechanism is confirmed and I've signed off.
- **Tap before mop.** The upstream fix (stop the drift) comes before the DB re-link (clean up orphans). A DB re-link alone will be undone by the next `apply`.
- **Non-destructive remediation only.** Repair the *link* (`user_auth.auth_id` / `user_external_accounts.account_id`); do **not** delete Keycloak/Grafana/Sourcegraph users to "force a fresh link" — that destroys local accounts, dashboards, and permissions.
- **No internet folklore.** `login_attribute_path: sub` is NOT a Grafana-recommended stabilization (refuted in the brief). `oauth_allow_insecure_email_lookup` is a scoped, temporary self-heal only (CVE-2023-3128).
- Every prod-touching change must be reviewable first (TF diff / dry-run SELECT before UPDATE) and the DB tables snapshotted before any write.
