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

## 2. Running a data import against production

The exports live in the image (`db/seeds/exports/`, ~18MB gzipped), so the
Render **Shell** can run these commands directly. **Prefer not to.** That Shell
runs inside the live web container, which is a 512MB starter instance whose
whole configuration in `render.yaml` — the memory watchdog, `WEB_CONCURRENCY=0`,
capped malloc arenas, hand-tuned GC — exists because it was OOM crash-looping.
Replaying a 126,895-row export next to the serving process is the most likely
way to take the site down.

Run it from a workstation instead, pointed at the production database. Then only
the `INSERT`s cross the network and the parsing happens somewhere with room.

### The minimum environment

A data-only rake task boots in `production` with **throwaway values for
everything except the database**:

```bash
export RAILS_ENV=production
export DATABASE_URL='…'                       # the real one, from the Render dashboard
export SECRET_KEY_BASE=$(openssl rand -hex 32) # throwaway: nothing here signs a cookie
export APP_HOST=example.invalid                # throwaway: satisfies MailConfigCheck
export SMTP_ADDRESS=smtp.invalid
export MAIL_FROM=noreply@example.invalid
export ANTHROPIC_API_KEY='…'                   # only needed for verto:enrol_corpus
```

**Do not copy the `ACTIVE_RECORD_ENCRYPTION_*` keys.** An import neither reads
nor writes an encrypted attribute, so it does not need them — and those three
are the one secret in this app with no recovery path (see section 3). Copying
them onto a laptop to run a task that never uses them is pure downside.

### The order

```bash
bin/rails verto:preflight        # read-only; exits non-zero if anything should stop you
```

Preflight reports the schema version, what each deck's account already holds —
flagging any response that was collected through the player rather than
imported — the database size, and whether the Anthropic key actually answers.
Fix whatever it flags before going on.

Then, per dataset, **smallest first** so a mistake is cheap:

```bash
IMPORT_DECK=<deck> IMPORT_PASSWORD='…' bin/rails "verto:import_csv[db/seeds/exports/<file>.csv.gz]"
IMPORT_DECK=<deck>                      bin/rails "verto:reconcile[db/seeds/exports/<file>.csv.gz]"
IMPORT_DECK=<deck>                      bin/rails verto:enrol_corpus
```

| Order | `IMPORT_DECK` | Export | Rows |
|---|---|---|---|
| 1 | `unyo_sport` (plus `IMPORT_ORG_SLUG=unyo`) | `unyouth_sport_raw_data` | 1,376 |
| 2 | `you_are_nature` — still collecting; re-run the import when a fresher export lands | `you_are_nature_raw_data` | 2,952 |
| 3 | `aaf_valparaiso` | `aaf_valparaiso_final_raw_data__raw_data_general` | 3,477 |
| 4 | `walls_happiness_adult` — **`verto:build_deck` then `verto:append_csv`**, not import | `walls_the_happiness_project_raw_data_adults__master` | 10,754 |
| 5 | `walls_happiness_child` — **`verto:build_deck` then `verto:append_csv`**, not import | `walls_the_happiness_project_raw_data_children__master` | 17,932 |
| 6 | `wll_education_digital` | `wll_transforming_education_raw_data_digital` | 50,835 |
| 7 | `wll_education_paper` — **`verto:append_csv`**, not import | `wll_transforming_education_raw_data_paper` | 3,483 |
| 8 | `big_green_legacy` | `the_big_green_legacy_moe_raw_data` | 126,895 |

Step 7 appends because both WLL halves are one Verto; importing it would rebuild
the account and take the digital half with it.

Steps 4–5 must never use `verto:import_csv` for a different reason: the two
Happiness Project flows are **sibling Vertos sharing one org**, and a full
import destroys the whole org — including the other flow. `verto:build_deck`
replaces only its own Verto, and `verto:append_csv` upserts the responses, so
neither touches the sibling. Re-running a pair is idempotent, and each combined
export can be regenerated and re-appended as more country files arrive (the
CSV keeps every row's provenance in its Country column).

`verto:reconcile` must report **zero unaccounted answers**. It is the whole
claim — every answer in the export is either stored or listed as a deliberate
omission — and a production import that does not reconcile should be rolled
back, not investigated in place.

### What is safe about this

Each import is a single transaction (`VertoCsvImporter#call` wraps
destroy → create → insert), so a dropped connection or a killed terminal rolls
back to the previous state. There is no partial-import case to clean up.

Each import also **destroys and rebuilds its own account first** — that is what
makes it repeatable. `IMPORT_DECK=<deck> bin/rails verto:destroy_import` removes
one imported account outright. Both are scoped to the deck's own org slug and
touch nothing else.

### What it costs

`verto:enrol_corpus` is the only step that spends money: it themes every
open-text column in batches through Claude Haiku. Big Green's freeform alone is
59,620 answers, capped at 40 calls by `ASK_VERTO_MAX_THEME_BATCHES`. Across all
the datasets, expect 150–200 calls. Lower that variable for a cheaper first pass;
re-running enrolment later fills the themes in.

One more thing it needs: a **present** `ANTHROPIC_API_KEY`, not just a working
one. Preflight fails a key that answers wrongly but only *warns* when the key
is absent — enrolment then still succeeds, indexing every closed question,
and silently produces **no themes and no quotes** for any open-text question.
That is recoverable (re-run enrolment with a key later), but nothing in the
task's output says the quotes are missing, so don't discover it from the
product.

### The consent path (customer-offered Vertos)

The import above is the VertoNow half — data held under an agreement, where
`verto:enrol_corpus` legitimately turns both consent keys itself. Everything
else enters Ask Verto through two people:

1. **The creator offers.** The "Ask Verto" block in the editor's publish
   panel (admins of the owning org only; visible once the Verto has any
   answered responses) posts the offer, which lands in the review queue as
   `pending`.
2. **Staff approve or decline** at `/ask/review`. The route is gated by the
   same `BLAZER_STAFF_EMAILS` allowlist as `/blazer`, and it is
   **deny-by-default: while that variable is unset in Render, the queue 404s
   for everyone and no offered Verto can ever be approved** — the corpus can
   then only grow through the rake task. Set it (Render dashboard →
   Environment) to the staff sign-in email(s) before expecting the queue to
   exist.

Approval enqueues the indexing job; declining records a reason the creator
reads verbatim. A Verto the automated checks BLOCK (sample floor, no citable
questions) is left `pending` in this queue even by `verto:enrol_corpus` —
blocked Vertos are a human's decision — so the allowlist matters for the
import path too.

## 3. Backing up the Active Record encryption keys

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

## 4. GitHub branch protection on `Main`

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

## 5. Sentry setup (one-time)

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
