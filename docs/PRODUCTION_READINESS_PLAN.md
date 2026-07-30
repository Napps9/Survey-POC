# Playverto — Production & Customer Readiness Plan

_Last reviewed: 2026-07-09. Based on a full-platform audit across security, data,
AI/external services, infrastructure/ops, and product/compliance._

## TL;DR

The platform has matured well past its "POC" README: it's a real multi-tenant
SaaS (auth, organisations, alliances, persistence, AI generation, exports, 19
locales). The **security and authorization model is genuinely solid** — the audit
found no IDOR or auth-bypass holes; multi-tenancy is consistently enforced.

The gaps are in **operational hardening, data durability, and commercial
plumbing**, not in the core app logic. A handful of them are true
launch-blockers because they cause **silent customer data loss** or can take the
whole app down at trivial concurrency.

### The five things that will hurt a real customer first

_Updated 2026-07-30. The original five were written in July; three have since
shipped and are struck through here rather than deleted, so the list stays
readable against the audit it came from._

1. ~~🔴 **Uploaded files vanish on every deploy**~~ — **fixed** (P0-1): a Render
   persistent disk is mounted at `/rails/storage`.
2. ~~🔴 **You are blind to failures**~~ — **fixed in code** (P0-2): Sentry plus a
   DB-verifying `/up`. An external uptime check is still an ops task.
3. ~~🔴 **~3 concurrent AI operations can 502 the whole app**~~ — **fixed**
   (P0-3 and P1-5): AI generation runs in Solid Queue jobs, flow translation
   batches one Claude call per locale instead of per card per locale, the public
   grade endpoint is bulkheaded, and `rack-timeout` bounds every request.
4. 🔴 **No enforced consent for the PII you collect** — respondents submit
   location + birth date, and the consent gate is still optional: a Verto can be
   published collecting both with no gate at all. The pages (`/privacy`,
   `/terms`) and the audit trail exist; the requirement doesn't (P0-6).
5. ~~🟠 **No spend guardrails on the editor**~~ — **fixed** (P0-4): per-user
   hourly limits on every Claude endpoint plus a per-organisation daily cap.
   The client-side "disable the button while it's in flight" polish remains.

What's left in P0 is entirely compliance: **P0-6 (consent is still optional on
Vertos that collect location and birth date)**, **P0-7 (GDPR data-subject
rights)** and **P0-8 (email verification + terms acceptance)**.

Plus, commercially: **there is no billing, subscription, or usage metering of any
kind** — a prerequisite for a paid "customer-ready" product.

---

## How to read this plan

Work is grouped into three phases by urgency, plus a separate **Commercial track**
(billing) that's gated on a business decision rather than engineering.

- **P0 — Launch blockers.** Data-loss, outages, or legal exposure. Do before any
  real customer touches it.
- **P1 — Reliability & hardening.** Won't lose data today, but will bite under
  load or over time.
- **P2 — Polish & scale.** Quality, docs, a11y, test depth, future scale.

Effort estimates are rough (S ≤ half-day, M ≈ 1–2 days, L ≈ 3–5 days).

---

## P0 — Launch blockers

| # | Item | Why | Effort | Evidence |
|---|------|-----|--------|----------|
| ~~P0-1~~ | ~~**Move Active Storage off ephemeral disk**~~ **Done** — a 1GB Render persistent disk is mounted at `/rails/storage`, which is where `:local` writes (WORKDIR is `/rails`); `bin/docker-entrypoint` also handles the root-owned-mount case. Trade-off taken knowingly: a disk pins the service to one instance and swaps zero-downtime deploys for a brief stop/start. | Prevented silent, customer-visible data loss on every deploy. | S–M | `render.yaml:36-39`, `bin/docker-entrypoint:14-20` |
| ~~P0-2~~ | ~~**Add error tracking + uptime monitoring**~~ **Done in code** — `sentry-rails` with `config/initializers/sentry.rb` and a `SENTRY_DSN` env var, plus `healthCheckPath: /up` pointing at a DB-verifying action. The external uptime check is an ops task, not a repo change. | Without it you won't know when prod breaks. | S | `config/initializers/sentry.rb`, `render.yaml:99` |
| ~~P0-3~~ | ~~**Get AI work off request threads**~~ **Done** — Solid Queue in-process (`solid_queue_mode :async`) with `BuildVertoJob`, `FinishVertoSetupJob`, `GenerateFlowJob` and `RenderReportPdfJob`. The streaming endpoints still hold a thread by design; they are bounded by the slot pool and exempted from `rack-timeout`. | Removed the 3-concurrent-call → app-wide 502 failure mode. | L | `app/jobs/`, `config/puma.rb` |
| ~~P0-4~~ | ~~**Rate-limit + quota all AI endpoints**~~ **Done (server side)** — `ThrottlesAiSpend` adds per-user hourly limits on every Claude endpoint (deck generation and the imports at 20/h, per-card generate/optimise/moderate at 120/h, chat at 60/h, summaries and the report stream at 30/h, Pexels at 60/h) plus a per-organisation daily ceiling, `AI_DAILY_GENERATION_CAP`, default 300. The summaries and report stream are rate-limited but deliberately **not** counted against the daily cap — both replay a cache when the response count hasn't moved, so most requests there spend nothing. **Still open:** disabling the editor's submit buttons client-side while a request is in flight. | Runaway Anthropic spend; a signed-in user or a stuck retry loop could queue unbounded paid generations. | M | `concerns/throttles_ai_spend.rb`, `surveys_controller.rb` |
| ~~P0-5~~ | ~~**Configure a durable, shared cache store**~~ **Done** — Solid Cache on the primary database (no separate `cache` database; the generator's template default would have pointed at one that doesn't exist), 64MB cap. **Correction to the original note:** only Rails' own `rate_limit` counters and `NominatimClient`'s geocode cache used `Rails.cache` — `TranslationCache` and the results-report markdown are database columns and were never affected. | Made every `rate_limit` in the app a real throttle instead of a per-process counter reset by each deploy. | S | `config/cache.yml`, `production.rb`, `CreateSolidCacheTables` |
| P0-6 | **Enforce the consent baseline** — the *pages* shipped (`/privacy`, `/terms`, `/cookie_policy`, footer links, cookie-consent banner) and the consent gate exists in two forms (survey-level `consent_text` and the `consent_gate` card). What is still missing is the **enforcement**: `consent_gated?` is advisory, so a Verto collecting location or birth date can still be published with no gate at all. | Compliance blocker for collecting respondent PII. The consent *audit trail* is well-built — it just isn't required. | S | `survey.rb:1012-1019` (`consent_required?` optional), `legal_controller.rb` |
| P0-7 | **GDPR data-subject rights** — respondent data export + per-respondent deletion/anonymization (by token/email); a documented retention policy. | Legal requirement; today PII can only be removed by destroying the whole Verto. | M | `verto_csv_importer.rb:155` |
| P0-8 | **Email verification + Terms acceptance at signup** — Rails `generates_token_for :email_confirmation` + mailer; a required "I agree to Terms & Privacy" checkbox persisted on the user. | Prevents signup with unowned emails; records consent to terms. | M | `registrations_controller.rb`, `registrations/new.html.erb` |

---

## P1 — Reliability & hardening

### Infrastructure & ops
| # | Item | Effort | Evidence |
|---|------|--------|----------|
| ~~P1-1~~ | ~~**Fix ActionCable backend**~~ **Done** — `cable.yml` production is `solid_cable` on the primary database, polling at 0.5s rather than the generated 0.1s. | S | `config/cable.yml`, `CreateSolidCableTables` |
| P1-2 | **Verify & document DB + storage backups** — confirm Render Postgres backup retention, add a `pg_dump`-to-bucket job if needed, offsite the storage bucket; write down RPO/RTO and a rollback runbook. | M | `render.yaml:101`; no backup config in repo |
| ~~P1-3~~ | ~~**DB-verifying health check**~~ **Done** — `/up` routes to `HealthController#show`, which runs `verify!` on a checked-out connection and returns 503 on failure. | S | `health_controller.rb`, `routes.rb:53` |
| P1-4 | **Gate migrations on deploy — step 2 of 2** — `preDeployCommand: bundle exec rails db:prepare` is in `render.yaml` (step 1). `bin/docker-entrypoint` still runs `db:prepare` on every container start, so a bad migration takes the running instance down on its next restart instead of blocking the deploy. Remove it from the entrypoint once the pre-deploy step is confirmed in a Render deploy log. Statement timeouts still to add. | S | `bin/docker-entrypoint:22-27`, `render.yaml:27` |
| ~~P1-5~~ | ~~**Add `rack-timeout`** to bound all thread occupancy (reinforces P0-3).~~ **Done** — three tiers keyed off named routes: streams exempt, Claude/import/export endpoints at 240s, everything else at 45s. | S | `lib/request_timeout.rb`, `config/initializers/rack_timeout.rb` |
| P1-6 | **Back up AR encryption keys** — the three `ACTIVE_RECORD_ENCRYPTION_*` keys are Render-generated and live nowhere the owner controls; if the service is recreated, all stored Google tokens become permanently undecryptable. Record them in a secret store; add `previous_keys` before any rotation. | S | `render.yaml:67-73` |

### Data layer
| # | Item | Effort | Evidence |
|---|------|--------|----------|
| ~~P1-7~~ | ~~**Move base64 images out of DB columns**~~ **Done** — `Survey::CardImageStore`/`CardImageBackfill` and `rake card_images:backfill` already converted existing decks, but nothing stopped *new* base64 arriving: `sanitize_image_url` still accepts data-URLs on every write path. `Survey` now externalises on `before_save` (plus `after_create`, since there's no id to attach a blob to on the first save), covering `cards[].image`, `cards[].option_images[]`, `background_image` and `consent_image` — the last of which the backfill was also missing. A failed conversion leaves the data-URL in place: a fat image beats a broken one. | L | `survey.rb`, `survey/card_image_store.rb`, `survey/card_image_backfill.rb` |
| ~~P1-8~~ | ~~**Optimize cross-survey aggregation**~~ **Done** — the aggregator now streams `select(:id, :answers).find_each` and counts contributors in the same pass; the Common Questions index counts responses with one SQL `COUNT` instead of eager-loading every row; all three call sites load surveys `without_report_text`. Measured on 3,200 responses across 8 Vertos: ~50% fewer allocations, ~46% faster. **Correction to the original note:** the `.any?` calls were mostly NOT an N+1 — `responses.to_a` caches the association, so the extra `EXISTS` only fired for surveys the pass skipped. The real cost was memory: every response loaded whole to read one JSON column. | M | `common_question_aggregator.rb`, `common_question_sets_controller.rb`, `portfolios_controller.rb` |
| P1-9 | **Add missing FK + indexes** — `add_foreign_key :identities, :users`; index `responses` on `[survey_id, region_country, region_label]` (public regions/segmentation path). | S | `create_identities.rb`, `player_controller.rb:253` |
| P1-10 | **Normalize email on read** — password-reset/invite/oauth lookups pass raw params, so `Foo@Bar.com` misses stored `foo@bar.com`. Downcase in the query. | S | `passwords_controller.rb:12`, `invites_controller.rb:23,71,179` |
| P1-11 | **Shared Nominatim throttle** — respondent search has no throttle; the geocode client's throttle is a non-thread-safe class variable. Add a cache-based token bucket in front of both to respect Nominatim's 1 req/s app-wide cap (avoids IP ban). | M | `nominatim_client.rb`, `nominatim_geocode_client.rb:86` |

### Security hardening (no open holes — these are defense-in-depth)
| # | Item | Effort | Evidence |
|---|------|--------|----------|
| P1-12 | **Strengthen auth throttling** — with the shared cache store (P0-5), add a per-`email_address` login/reset rate-limit key and lower the generous IP-only limit. | S | `sessions_controller.rb:5` |
| P1-13 | **Blazer on a read-only DB role** — it currently runs against the read-write `DATABASE_URL` over the whole multi-tenant DB. Provision a dedicated read-only role via `BLAZER_DATABASE_URL`. | S | `blazer.yml:3` |
| P1-14 | **Small-cell suppression on public comparison/scores** — `#regions` enforces a min sample size but `#results` and `#scores` don't, so a 1–2 responder comparison Verto can reveal an individual's answers. | S | `player_controller.rb:203,236,258` |
| P1-15 | **Delimit untrusted content in AI prompts** — respondent free-text is interpolated raw into chat/summary/report prompts (prompt-injection of the *analysis* the creator reads; no tool/exfil path). Wrap in delimited "treat as data" blocks. | S | `results_chat.rb:96` |
| P1-16 | **Generic client-facing errors** — signup surfaces "email already taken" (enumeration); a few endpoints return raw `e.message`. Return generic messages, log details server-side; add `reset_session` on login. | S | `registrations_controller.rb:27`, `surveys_controller.rb:246,529` |

---

## P2 — Polish & scale

| # | Item | Effort | Evidence |
|---|------|--------|----------|
| P2-1 | **Rewrite the README** — still says "Survey POC / Rails 7.2 / nothing is persisted / auth & response storage out of scope"; every one of those is now shipped. | S | `README.md` |
| P2-2 | **Close i18n leaks** — controller flash strings and a few view placeholders are hardcoded English despite 19 fully-localized locales (500 keys each, parity-tested). Non-English creators see English flashes. | M | `registrations_controller.rb`, `alliances_/invites_/passwords_` controllers, `_media_modal.html.erb:66` |
| P2-3 | **Branded, localized error pages** — replace stock Rails `public/404/422/500.html`. | S | `public/*.html` |
| P2-4 | **Accessibility audit of the player** — JS-rendered answer controls have thin ARIA/keyboard support; respondents may use assistive tech. Label inputs, add roles, manage focus between cards, check contrast. | M | `player/show.html.erb` |
| P2-5 | **Add browser/system tests** — 74 test files, integration-heavy and good on auth/authz/player submission, but **zero Capybara/system tests** for the JS-heavy player and editor. | M | `test/system/` empty |
| P2-6 | **Onboarding polish** — welcome email after signup; a one-click "create a sample Verto" for new orgs (the `DemoSeeder` is excellent but manual). Ensure prod SMTP + `default_url_options` are set and fail loudly if not. | M | `app/mailers/`, `demo_seeder.rb` |
| P2-7 | **Migrate `json` → `jsonb`** on Postgres for storage/indexability (table-rewrite; off-peak). | M | `schema.rb` |
| P2-8 | **DB CHECK constraints** on status/role/kind enum columns; mirror `dependent:` with FK `on_delete:` as a safety net against raw/bulk deletes. | M | `schema.rb:326-346` |
| P2-9 | **Staging environment + documented rollback**; tighten CSP (`script-src` off `'unsafe-inline'` via nonces/Stimulus); set `Disallow: /play/` in `robots.txt` if public surveys shouldn't be indexed. | M | `render.yaml`, `content_security_policy.rb:33`, `public/robots.txt` |

---

## Commercial track (business decision, then build)

**There is no billing, subscription, plan/tier, or usage-metering code anywhere.**
For a paid product this is a prerequisite, but it's gated on business decisions
(pricing model, per-seat vs per-response vs per-generation, free tier limits)
rather than engineering readiness — so it sits outside the P0/P1/P2 technical
sequence.

- **CT-1** Decide the pricing/packaging model (this drives the metering design).
- **CT-2** Add a billing integration (e.g. Stripe) + `Plan`/`Subscription` models.
- **CT-3** Per-org **usage metering** on AI actions — ties directly into P0-4's
  quota work, so build the metering primitive once and use it for both
  enforcement and billing.

---

## What's already solid (don't re-litigate)

The audit explicitly verified these as **safe / well-built** — worth knowing so
effort goes to the real gaps:

- **Multi-tenancy & authorization.** Every survey/results/export/report/chat
  action resolves through `Current.organisation.surveys.find(...)`; alliance
  controllers verify ownership/active membership; cross-org question-splicing is
  blocked. **No IDOR/auth-bypass found.**
- **Public player security.** Capability-token based; drafts unreachable;
  server-authoritative quiz grading; all writes rate-limited + CSRF-protected.
- **Invite acceptance** guards against account takeover (requires password or
  active session).
- **Secrets & encryption.** Google tokens `encrypts`-at-rest; AR encryption
  fails-closed in prod; param logging filtered; OAuth `state` validated.
- **XSS/SSRF/open-redirect/mass-assignment/CSRF** — all checked, no gaps; AI
  report HTML is sanitized; external clients hit fixed hosts only.
- **AI output robustness.** Forced `tool_choice`, defensive normalization, a
  120s/1-retry client bound, graceful degradation on Pexels/Google failures.
- **i18n depth.** 19 locales, 500 keys each, parity-enforced by a test; player is
  RTL-aware. (Leaks are only in creator-side flashes — P2-2.)
- **Memory strategy.** One Ruby process for everything (single-mode Puma with
  Solid Queue running as threads via `solid_queue_mode :async`) + jemalloc +
  `MALLOC_ARENA_MAX` + GC tuning + a cgroup memory watchdog that restarts Puma
  gracefully before the kernel OOM-kills the container — a coherent 512MB plan.

---

## Suggested sequencing

1. **Week 1 — stop the bleeding:** P0-1 (storage), P0-2 (Sentry+uptime), P0-5
   (Solid Cache), P1-3 (health check). Small, high-leverage, unblock the rest.
2. **Week 1–2 — durability & spend:** P0-3 (Solid Queue + background jobs) and
   P0-4 (rate-limit/quota) together; they share the metering primitive with CT-3.
3. **Week 2–3 — compliance:** P0-6, P0-7, P0-8 (legal, consent, GDPR, email
   verification) — needed before collecting real respondent PII.
4. **Week 3+ — P1 hardening**, then P2 polish and the Commercial track in
   parallel once pricing is decided.
