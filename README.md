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

## Out of scope (deliberate)
Persistence, auth, taking the survey, response storage, sharing links.
