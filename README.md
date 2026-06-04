# Survey POC

A Rails app that generates surveys from a natural-language prompt using Claude.

## Stack
- Rails 7.2 + Tailwind + Hotwire (Turbo)
- `anthropic` Ruby SDK, model `claude-sonnet-4-6`
- Structured output via Anthropic tool use (forced `emit_survey` tool)

## Setup
```bash
bundle install
cp .env.example .env   # then add your ANTHROPIC_API_KEY
bin/rails db:prepare
bin/dev                # Rails + Tailwind watcher
```

Open <http://localhost:3000>, describe a survey ("Survey for new SaaS users
about onboarding experience"), and click **Generate survey**. The result
swaps into the page via a Turbo Frame.

## Layout
- `app/services/survey_generator.rb` — Anthropic client + tool schema
- `app/controllers/surveys_controller.rb` — `new` / `generate`
- `app/views/surveys/new.html.erb` — prompt form
- `app/views/surveys/_survey.html.erb` — rendered survey preview

## Deploy to Render
This repo includes a `render.yaml` Blueprint.

1. Push the branch to GitHub.
2. In Render, **New → Blueprint**, point at this repo, pick the branch.
3. When prompted, set `ANTHROPIC_API_KEY` (your Claude API key).
   `SECRET_KEY_BASE` is generated automatically by Render.
4. Render runs `bin/render-build.sh` (bundle, precompile, db:prepare) and
   starts Puma on `$PORT`. Health check hits `/up`.

Notes:
- SQLite is used; the free plan filesystem is ephemeral, so the DB resets on
  each deploy. Fine for this POC since nothing is persisted. Add a Render
  Disk or switch to Postgres before storing data.
- `config/environments/production.rb` allows `*.onrender.com` hosts.

## Staging environment

A parallel staging environment runs from the `staging` branch via
`render.staging.yaml`. Same code, separate Render service + Postgres DB,
separate secrets. Cost: $0 (free Starter tier on both services).

**One-time setup**

1. Push `render.staging.yaml` and these seed changes to `main`, then branch:
   ```bash
   git checkout -b staging && git push -u origin staging
   ```
2. In Render: **New → Blueprint**, point at this repo, choose branch
   `staging` and blueprint file `render.staging.yaml`.
3. When Render prompts for secrets, set:
   - `ANTHROPIC_API_KEY` — same value as prod (shares rate limit)
   - `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` — same as prod
   - `APP_HOST` — e.g. `survey-poc-staging.onrender.com` (visible after
     first deploy; redeploy after setting)
   - `MAIL_FROM`, `MAIL_REPLY_TO` — anything; mail is sandboxed
   - `SMTP_ADDRESS` / `SMTP_USERNAME` / `SMTP_PASSWORD` — from a Mailtrap
     sandbox inbox (mailtrap.io, free tier: 100 emails/mo)
   - **Do not set** `SECRET_KEY_BASE` or `ACTIVE_RECORD_ENCRYPTION_*` —
     Render generates fresh values per env; reusing prod's would defeat
     isolation.
4. In Google Cloud Console, add this redirect URI to the existing OAuth
   client: `https://<staging-host>/google/callback`. Same client ID/secret
   keep working; users will need to reconnect Google in staging (encrypted
   refresh tokens are env-scoped).

**Day-to-day**

```bash
git checkout staging
git merge --ff-only feature/my-change   # or rebase a feature branch in
git push origin staging                 # auto-deploys to staging
# ...QA the staging URL...
git checkout main && git merge staging  # promote to prod
git push origin main
```

Staging is seeded with `SEED_DEMO=1` on every deploy:

- Demo org: `Demo Co`
- Demo login: `demo@playverto.com` / `demopass123456` (admin)
- One published demo Verto with a clickable `/play/<token>` link

**Caveats**

- Both services cold-start after 15 min idle (~30 s first request).
- Mailtrap free tier caps at 100 emails/mo — exceed it and mail silently
  fails.
- Anthropic + Google OAuth quotas are shared with prod; fine for QA, not
  for sustained automated load.

## Out of scope (deliberate)
Persistence, auth, taking the survey, response storage, sharing links.
