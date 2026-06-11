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
