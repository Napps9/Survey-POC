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
bin/trello_log "Short title of what shipped" "1-3 sentence summary" \
  --frontend "What changed in views/Stimulus/Tailwind, if anything." \
  --backend "What changed in models/controllers/services, if anything." \
  --test "rails test:pass" --test "rubocop:pass" \
  --test "brakeman:pass" --test "importmap audit:pass" \
  --screenshot tmp/screenshots/whatever.png \
  --points 5
```

This posts to the current week's list on the team's Trello board
(https://trello.com/b/ntNghZRN) via the REST API — `Done - Week of 10th
August 2026`-style, weeks running Monday–Sunday, named for the Monday. The
list is found-or-created automatically, with the newest week kept leftmost of
the weekly block; setting `TRELLO_LIST_NAME` still targets that list verbatim
instead. (`bin/trello_backfill_done_weeks` regroups an old flat `Done` list
into weekly lists, should one reappear.) `--frontend`/`--backend` are
rendered as `## Frontend`/`## Backend` sections in the card description —
omit whichever side didn't change. `--test NAME:STATUS` (repeatable) adds a
"Tests" checklist item per suite, checked iff STATUS is `pass` — use the
actual result of the four commands above, not a guess. `--screenshot PATH`
(repeatable) attaches a mockup/screenshot file to the card; only pass this
when the change is user-visible and a screenshot was actually taken (e.g. via
the `/verify` skill) — don't invent one. `--points N` sets a Fibonacci story
point value (1, 2, 3, 5, 8, 13) as a card label, colored by the board's
default label colors (green → blue as complexity rises) — estimate it
yourself based on the size/risk of the change, the same way you judge test
results, don't skip it out of laziness. All flags are optional; a bare
`bin/trello_log "title" "summary"` still works exactly as before.

Requires `TRELLO_API_KEY` and `TRELLO_TOKEN` env vars (set at the environment
level, never committed). If they're not present in this session, skip logging
rather than failing the push — the code change is what matters, the log
entry is best-effort.

## Deploys

Render deploys the `Main` branch automatically, gated on CI: `render.yaml`
sets `autoDeployTrigger: checksPass`, so a commit only deploys after all
GitHub checks (test, lint, scan_ruby, scan_js in `.github/workflows/ci.yml`)
pass on it. A red push to Main therefore doesn't deploy — but don't rely on
that: push green.

## Gotchas

- Importing a partner's survey export means writing a **deck**
  (`app/lib/verto_decks/`), not editing `VertoCsvImporter` — the importer is the
  machinery, a deck is the questions and the account. Spec ORDER is card order
  is the positional key every answer is stored under, so reordering a deck after
  an import re-points every stored answer. `IMPORT_DECK=<key>` selects one;
  `VertoDecks.available` lists them.
- Some exports carry a data column their header doesn't name, and the two halves
  of one export can be shifted **differently** — WLL's paper file is +1 to the
  end, its digital file is +1 for six preamble columns and then aligned again.
  `VertoExportLayout` measures the preamble and the questions separately and
  refuses an ambiguous file. Don't replace it with a fixed offset: the importer
  reads every column by name, so a wrong offset produces a clean-looking import
  of comprehensively wrong answers.
- The partner export CSVs **are** committed, gzipped, under
  `db/seeds/exports/` (~18MB — deliberate, so any checkout can run the
  runbook's import; see `docs/DEPLOYMENT_RUNBOOK.md` §2). Anything not
  already in that directory is handed over out of band.
- The test suite stubs all Anthropic clients, but service constructors do
  `ENV.fetch("ANTHROPIC_API_KEY")` — the var must exist (any value) to run
  tests. CI sets a stub value.
- GitHub Actions branch filters are case-sensitive: the branch is `Main`,
  not `main` (ci.yml watches both).
- Locale strings live in 19 files under `config/locales/` — new UI strings
  must be added to all of them (they mirror en.yml's structure).
  `test/lib/locale_structure_parity_test.rb` enforces this for the
  browser-facing namespaces (`js`, `defaults`, `card`, `templates`,
  `demographics`, `ask`); JS reads strings via
  `window.I18N`, which carries `js:` plus the curated slice in
  `app/views/layouts/_i18n_js.html.erb` — a JS-facing string anywhere else
  renders as a raw dotted key.
- Dev/test run SQLite; production runs Postgres, and they disagree on real
  things — `LOWER()` on a `json` column and `DISTINCT` over rows containing
  one both pass SQLite and 500 on Postgres (this took Ask Verto down in prod,
  2026-08-12). Raw SQL must run on both engines (`LOWER(CAST(col AS TEXT))`,
  dedupe via id-subquery instead of `.distinct` on full rows). CI's
  `test_postgres` job runs the whole suite on Postgres to catch this class;
  keep it green, don't delete it to get a deploy out.
- Dashboard/player styling is mostly inline `style` attributes plus classes
  in `app/assets/tailwind/application.css`; match the file you're editing.
- `/play/:token` is served through a Service Worker (`app/views/pwa/service-worker.js`)
  with **network-first (3.5s timeout) + offline cache fallback** for the
  player HTML. Content/markup/CSS fixes therefore reach respondents on their
  next ordinary online visit with **no** `CACHE_VERSION` bump. A bump is
  still required when the **worker's own behaviour** changes (caching
  strategies, the submit queue, cache layout) — and the `controllerchange`
  reload in `app/javascript/sw_register.js` delivers such worker changes
  same-visit. History: the HTML used to be stale-while-revalidate, which
  pinned respondents on stale copies (one deploy shipped invisibly until a
  v2→v3 bump) — that's why it's network-first now; don't quietly revert it.
