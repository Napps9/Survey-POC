---
name: verify
description: Build, seed, launch and drive Survey-POC (Playverto) to verify a change end-to-end — editor Rules of the Game panel, dashboard, and the /play player — using the seeded demo account and headless Chromium.
---

# Verify a change in Survey-POC

## Build + seed + launch

```bash
export ANTHROPIC_API_KEY=stub          # any value; services fetch it at init
bundle install
bin/rails db:prepare
DEMO_PASSWORD='<pick-a-passphrase>' bin/rails demo:seed   # 4 demo Vertos + responses
bin/rails server -p 3117 &             # dev sqlite, no other env needed
```

`demo:seed` is idempotent (destroys + rebuilds only the demo org). It creates
`demo@vertonow.com` / your DEMO_PASSWORD with three live Vertos and one draft
("Community Safety & Belonging") that is editable in the editor.

## Drive it (Playwright + pre-installed Chromium)

```js
const browser = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium" })
// Log in: fill email + password on /session/new, then press Enter in the
// password field — a generic submit selector hits the language switcher.
```

- **Editor**: `/surveys/:id`. The Rules of the Game breakdown is behind the
  right-column "Verto score" tab — `page.click(".right-tab.verto-score")` —
  and reads from `.score-board`. Live Vertos are locked; use the draft, or
  create a throwaway survey via `bin/rails runner` in the demo org to stage
  rule-breaking cards.
- **Player**: `/play/<publish_token>` (`Survey#publish_token` of a live demo
  Verto). Cards are `[data-card-type]`; the NPS slider exposes
  `data-nps-slider-steps-value` / `aria-valuemax`; tap statements are
  `[data-tap-stack-target='card']`.

## Gotchas

- Rating cards render only min/max caption fields in the editor, so
  DOM-derived option counts for rating are always 2 — verto_rules.js
  deliberately scores rating as its fixed 5 points.
- The demo decks double as rules-compliance fixtures
  (test/lib/demo_seeder_rules_test.rb) — keep them green against
  app/javascript/lib/verto_rules.js when editing either.
