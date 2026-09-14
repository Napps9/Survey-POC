#!/bin/bash
# SessionStart hook — make a container that was built five minutes ago able to
# run `bin/rails test`, `bin/rubocop` and `bin/gate` without anyone rediscovering
# the Gotchas section first. Idempotent; safe to run on every resume.
set -euo pipefail

# Local checkouts already have a working environment; this is for the web.
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
cd "${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

bundle check >/dev/null 2>&1 || bundle install --quiet

# Every Anthropic-backed service constructor does ENV.fetch("ANTHROPIC_API_KEY"),
# so the suite cannot LOAD without one — and it stubs every real client, so the
# value is irrelevant. On Claude Code for the web the key IS configured on the
# environment and is deliberately withheld from the shell (ANTHROPIC_BASE_URL
# arrives, the key does not), so every web session starts unable to run a test
# until it rediscovers this. Hence a stub.
#
# It goes in .env.test.local — gitignored, and dotenv-rails reads it for the
# TEST environment only — and deliberately NOT into the session environment: a
# session-wide stub would flip the ENV[...].present? branches in the app and
# disable the no-key fallbacks CLAUDE.md documents for bin/trello_week_summary
# and `rails i18n:translate`, both of which run in development. bin/gate scopes
# its own stub to the test commands for the same reason. Dotenv never overwrites
# a variable already in the process env, so a real key always wins over this.
if [ -z "${ANTHROPIC_API_KEY:-}" ] && ! grep -qs '^ANTHROPIC_API_KEY=' .env.test.local; then
  echo "ANTHROPIC_API_KEY=session-stub-no-real-calls" >> .env.test.local
fi

# db:prepare for a console, db:test:prepare for the suite — the parallel workers
# clone their per-worker SQLite files from the one it loads the schema into.
bin/rails db:prepare >/dev/null
bin/rails db:test:prepare >/dev/null

echo "session-start: bundle ok · databases prepared · test-env API key stubbed. Push gate: bin/gate --push" >&2
