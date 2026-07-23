# Deployment Runbook

Manual procedures the deployment pipeline can't do for you — rolling back a
bad deploy, backing up keys that live only in Render, and two one-time setup
steps (branch protection, Sentry). Companion to `PRODUCTION_READINESS_PLAN.md`
(P1-2, P1-6) and `PRODUCTION_READINESS_CHECKLIST.md`; check the corresponding
item off there once you've done the matching section here.

## 1. Rolling back a bad deploy

Render dashboard → the `survey-poc` service → **Deploys** tab → find the last
known-good deploy → **Rollback to this deploy**.

Two things that make this different from a typical Rails app's rollback:

- **App code and schema roll back independently — code does not roll back the
  schema.** If the bad deploy's pre-deploy migration already ran (see
  `render.yaml`'s `preDeployCommand`), the database is on the new schema.
  Rolling back to the older code only works if that older code still runs
  correctly against the new schema. This is why migrations should stay
  backward-compatible (tracked separately, not yet built — see
  `PRODUCTION_READINESS_PLAN.md` P1-4).
- **If the pre-deploy command itself failed, Render should never have swapped
  traffic to the new instance** — confirm which deploy is actually live in
  the dashboard rather than assuming the bad one made it live. The persistent
  disk (`render.yaml`) pins this service to a single instance, so every
  rollback is a hard cutover, not a gradual one — there's no second instance
  serving traffic during the switch.

If you need to run a migration or one-off command without a full deploy, use
Render's **Shell** tab, not a manual restart — a restart no longer re-runs
`db:prepare` (moved to `preDeployCommand`).

## 2. Backing up the Active Record encryption keys

Render dashboard → the `survey-poc` service → **Environment** tab → reveal
and copy each of:

- `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`
- `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`
- `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`

Store all three in a password manager. **Never commit them to this repo**
(including this file) — they're `generateValue: true` in `render.yaml`
specifically so Render, not the repo, holds the live values.

**Why this matters:** these three keys encrypt every stored Google OAuth
token at rest. If the Render service is ever deleted and recreated, or a
value is regenerated without a backup, every encrypted token becomes
**permanently undecryptable** — there is no recovery path. Every connected
user would need to reconnect Google.

**Rotating a key later:** don't hard-swap. Active Record Encryption supports
`previous_keys` — add the old key there before setting a new primary key, so
already-encrypted data keeps decrypting during the transition. See the [Active
Record Encryption guide](https://guides.rubyonrails.org/active_record_encryption.html#key-rotation)
for the exact config shape.

## 3. GitHub branch protection on `Main`

`CLAUDE.md` stands by pushing straight to `Main` with no PR. The textbook
branch-protection setup ("require a pull request before merging," "require
status checks to pass before merging") only gates **PR merges** — it does
nothing for direct pushes, and turning on "require a PR" would break the
current workflow outright. Two options, not one:

**Option A — recommended, keeps the current workflow.** GitHub repo →
Settings → Branches → Add branch protection rule → branch name pattern
`Main`:
- ✅ Do not allow force pushes
- ✅ Do not allow deletions
- Optionally: restrict who can push, to your own account explicitly

This closes the "anyone/anything with write access can force-push over
history or delete the branch outright" gap without changing how work ships.

**Option B — a bigger, separate decision.** Moving to a PR-based workflow
(feature branches, "require a PR," "require status checks before merging")
is what would make branch protection's full feature set meaningful — but
that's a workflow change, not a settings change, and isn't decided here.
Revisit if the direct-to-`Main` convention ever stops fitting how this repo
is worked on.

## 4. Sentry setup (one-time)

Do this **before** setting `SENTRY_DSN` anywhere — the region choice below
can't be changed after the fact.

1. Create a Sentry account/organisation at sentry.io. On the **New
   Organization** screen, set **Data Storage Location: EU**. This is chosen
   once, at the organisation level, and is irreversible — every project and
   every DSN created under this org afterward automatically routes through
   the Frankfurt region. There's no equivalent setting in the SDK
   (`config/initializers/sentry.rb`) or in Render — it only exists here.
2. Create a Rails project inside that org; copy its DSN.
3. Render dashboard → the `survey-poc` service → **Environment** → set
   `SENTRY_DSN` to that value.
4. Deploy (or wait for the next one) and confirm: trigger a harmless error
   and check it lands in the Sentry project, tagged with a `component` (see
   `app/lib/error_reporting.rb`) and with `request.data` empty (the
   `before_send` hook in `config/initializers/sentry.rb` strips it —
   confirm this, since respondent birth date/location must never appear in
   a captured event).
