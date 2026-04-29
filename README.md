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
3. When prompted, set the two `sync: false` env vars:
   - `ANTHROPIC_API_KEY` — your Claude API key
   - `RAILS_MASTER_KEY` — contents of `config/master.key` (gitignored)
4. Render runs `bin/render-build.sh` (bundle, precompile, db:prepare) and
   starts Puma on `$PORT`. Health check hits `/up`.

Notes:
- SQLite is used; the free plan filesystem is ephemeral, so the DB resets on
  each deploy. Fine for this POC since nothing is persisted. Add a Render
  Disk or switch to Postgres before storing data.
- `config/environments/production.rb` allows `*.onrender.com` hosts.

## Out of scope (deliberate)
Persistence, auth, taking the survey, response storage, sharing links.
