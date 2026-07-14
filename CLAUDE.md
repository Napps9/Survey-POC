# Survey-POC (Playverto)

Rails 8 app (importmap, Stimulus/Turbo, Tailwind, sqlite in dev/test, Postgres in prod).
"Verto" = a survey; the public respondent player lives at `/play/:token`.

## Git workflow — push to Main

Work happens **directly on the `Main` branch** (note the capital M — it's the
default branch). Do NOT create or push `claude/*` session branches or open PRs
unless the owner asks for one — repo owner's standing instruction, 2026-06-11.

Before every push to Main, the full local suite must be green:

```
bin/rails test        # 65+ tests, ~5s
bin/rubocop
bin/brakeman --no-pager
bin/importmap audit
```

## Work log (Trello)

After a push to Main passes the local suite (i.e. you're actually pushing),
log a card summarizing what shipped:

```
bin/trello_log "Short title of what shipped" "1-3 sentence summary"
```

This posts to the `Done` list on the team's Trello board
(https://trello.com/b/ntNghZRN) via the REST API. Requires `TRELLO_API_KEY`
and `TRELLO_TOKEN` env vars (set at the environment level, never committed).
If they're not present in this session, skip logging rather than failing the
push — the code change is what matters, the log entry is best-effort.

## Deploys

Render deploys the `Main` branch automatically, gated on CI: `render.yaml`
sets `autoDeployTrigger: checksPass`, so a commit only deploys after all
GitHub checks (test, lint, scan_ruby, scan_js in `.github/workflows/ci.yml`)
pass on it. A red push to Main therefore doesn't deploy — but don't rely on
that: push green.

## Gotchas

- The test suite stubs all Anthropic clients, but service constructors do
  `ENV.fetch("ANTHROPIC_API_KEY")` — the var must exist (any value) to run
  tests. CI sets a stub value.
- GitHub Actions branch filters are case-sensitive: the branch is `Main`,
  not `main` (ci.yml watches both).
- Locale strings live in 19 files under `config/locales/` — new UI strings
  must be added to all of them (they mirror en.yml's structure).
- Dashboard/player styling is mostly inline `style` attributes plus classes
  in `app/assets/tailwind/application.css`; match the file you're editing.
